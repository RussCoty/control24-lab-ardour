import copy
import ipaddress
import json
import math
import pathlib
import socket
import threading
import time
from collections import deque

from . import osc, protocol

ROOT = pathlib.Path(__file__).resolve().parents[1]


def defaults():
    profiles = []
    for id, name, adapter, port in [
        ('pt-local', 'Pro Tools · local', 'hui', 0),
        ('pt-remote', 'Pro Tools · network', 'hui', 0),
        ('ardour', 'Ardour', 'osc', 3819),
        ('mixbus', 'Mixbus', 'osc', 3819),
        ('resolve', 'DaVinci Resolve', 'mcu', 0),
        ('lighting', 'Lighting · OSC', 'osc', 9000),
    ]:
        mappings = {}
        if id in ('ardour', 'mixbus'):
            for ch in range(24):
                mappings[f'fader:{ch}'] = {'path': '/strip/fader', 'args': [ch+1, '$value']}
                for note, path in [(7, 'solo'), (8, 'mute'), (0, 'recenable')]:
                    mappings[f'button:{ch}:{note}'] = {'path': '/strip/'+path, 'args': [ch+1, '$toggle']}
            for note, path in [(16, '/transport_play'), (15, '/transport_stop'), (17, '/rec_enable_toggle')]:
                mappings[f'button:28:{note}'] = {'path': path, 'args': []}
        profiles.append(dict(id=id, name=name, adapter=adapter, host='127.0.0.1', port=port,
                             mappings=mappings, status='OSC implemented; target untested' if id in ('ardour', 'mixbus')
                             else 'Needs venue command map' if id == 'lighting' else 'Adapter planned'))
    return profiles


class Engine:
    def __init__(self, runtime=None):
        self.lock = threading.RLock()
        self.runtime = pathlib.Path(runtime or ROOT/'runtime')
        self.runtime.mkdir(parents=True, exist_ok=True)
        self.catalog = json.loads((ROOT/'data/catalog.json').read_text())
        self.controls = {c['id']: c for c in self.catalog['controls']}
        self.decoder = protocol.Decoder()
        self.profiles = defaults()
        self.active = 'ardour'
        self.sequence = 0
        self.generation = 0
        self.armed = False
        self.values, self.leds, self.pressed, self.touched, self.pending = {}, {}, {}, {}, {}
        self.commanded = {}
        self.events = deque(maxlen=3000)
        self.capture = 'Simulation / offline replay'
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.feedback_port = None
        if (self.runtime/'profiles.json').exists():
            saved = json.loads((self.runtime/'profiles.json').read_text())
            for p in saved['profiles']:
                self.validate_profile(p)
            self.profiles = saved['profiles']
            if saved['active'] in {p['id'] for p in self.profiles}:
                self.active = saved['active']

    def profile(self):
        return next(p for p in self.profiles if p['id'] == self.active)

    def record(self, event):
        self.sequence += 1
        event = dict(event, seq=self.sequence, time=time.time(), profile=self.active,
                     generation=self.generation, target=f"{self.profile()['host']}:{self.profile()['port']}")
        self.events.append(event)
        with (self.runtime/'events.ndjson').open('a') as out:
            out.write(json.dumps(event, allow_nan=False)+'\n')
        return event

    def snapshot(self, after=0):
        with self.lock:
            return copy.deepcopy(dict(active=self.active, profiles=self.profiles, armed=self.armed,
                generation=self.generation, sequence=self.sequence, values=self.values, leds=self.leds,
                pressed=self.pressed, touched=self.touched, capture=self.capture,
                feedback_port=self.feedback_port, events=[e for e in self.events if e['seq'] > after]))

    @staticmethod
    def validate_profile(p):
        if p.get('adapter') not in ('osc', 'hui', 'mcu'):
            raise ValueError('Unsupported adapter')
        ipaddress.IPv4Address(p['host'])  # explicit, reviewable IP; no DNS during control events
        if type(p.get('port')) is not int or not 0 <= p['port'] <= 65535:
            raise ValueError('Port must be 0..65535')
        if not isinstance(p.get('name'), str) or not 1 <= len(p['name']) <= 80:
            raise ValueError('Name must contain 1..80 characters')
        if not isinstance(p.get('mappings'), dict) or len(p['mappings']) > 1500:
            raise ValueError('Invalid mappings')
        for id, mapping in p['mappings'].items():
            if not isinstance(id, str) or not isinstance(mapping.get('args'), list):
                raise ValueError('Invalid mapping')
            if len(mapping['args']) > 16:
                raise ValueError('Too many OSC arguments')
            osc.encode(mapping['path'], [0.0 if v in ('$value', '$toggle') else v for v in mapping['args']])

    def persist(self):
        path = self.runtime/'profiles.json'
        temp = path.with_suffix('.tmp')
        temp.write_text(json.dumps(dict(profiles=self.profiles, active=self.active), indent=2))
        temp.replace(path)

    def save_profile(self, updated):
        with self.lock:
            self.validate_profile(updated)
            existing = next((p for p in self.profiles if p['id'] == updated['id']), None)
            if existing is None:
                raise ValueError('Unknown profile')
            if set(updated['mappings']) - self.controls.keys():
                raise ValueError('Mapping contains unknown controls')
            self.armed = False
            existing.update(copy.deepcopy(updated))
            self.generation += 1
            self.persist()
            self.record(dict(kind='profile-saved', source='app'))

    def switch(self, id):
        with self.lock:
            if id not in {p['id'] for p in self.profiles}:
                raise ValueError('Unknown profile')
            if id == self.active:
                return
            self.armed = False
            self.active = id
            self.generation += 1
            self.values.clear()
            self.leds.clear()
            self.pending.clear()
            self.commanded.clear()
            self.persist()
            self.record(dict(kind='profile-changed', source='app', value=id))

    def arm(self, enabled):
        with self.lock:
            p = self.profile()
            if enabled and (p['adapter'] != 'osc' or not p['port'] or not p['mappings']):
                raise ValueError('Configure an OSC destination and mappings before enabling output')
            self.armed = bool(enabled)
            self.record(dict(kind='output-enabled' if enabled else 'output-disabled', source='app'))

    def event(self, control, value, source='simulator', feedback=False):
        with self.lock:
            if control not in self.controls:
                self.record(dict(kind='unknown', control=control, value=value, source=source))
                return
            c = self.controls[control]
            kind = c['kind']
            if kind in ('button', 'touch', 'led'):
                if value not in (0, 1, False, True):
                    raise ValueError('Button/LED value must be 0 or 1')
                value = bool(value)
            elif kind in ('fader', 'encoder', 'ring', 'meter'):
                if type(value) not in (int, float) or not math.isfinite(value):
                    raise ValueError('Expected finite number')
                limit = 16383 if kind == 'fader' else 14 if kind == 'ring' else 127
                if not (-64 if kind == 'encoder' else 0) <= value <= limit:
                    raise ValueError('Control value out of range')
            elif kind in ('counter', 'scribble'):
                if not isinstance(value, str) or len(value) > (8 if kind == 'counter' else 4):
                    raise ValueError('Display text is too long')
            else:
                raise ValueError('This catalog entry has no implemented event handler')
            if feedback:
                if kind in ('button', 'led'):
                    self.leds[control] = value
                elif kind == 'fader' and self.touched.get(control.split(':')[1]):
                    self.pending[control] = value
                else:
                    self.values[control] = value
                self.record(dict(kind='feedback', control=control, value=value, source=source))
                return  # target feedback never re-enters command routing
            repeated = kind in ('button', 'touch') and self.pressed.get(control, False) == value
            if kind in ('button', 'touch'):
                self.pressed[control] = value
            elif kind == 'fader':
                self.values[control] = int(value)
            elif kind == 'encoder':
                self.values[control] = max(0, min(1, self.values.get(control, .5) + value/100))
            self.record(dict(kind=kind, control=control, value=value, source=source, repeated=repeated))
            if kind == 'touch':
                ch = str(c['channel']-1)
                self.touched[ch] = value
                if not value:
                    fader = f'fader:{ch}'
                    if fader in self.pending:
                        self.values[fader] = self.pending.pop(fader)
                return
            # F1..F6 select named profiles locally; repeated key-down cannot double-switch.
            keys = [0, 2, 4, 6, 8, 50]
            if c.get('section') == 24 and c.get('note') in keys and value and not repeated and self.pressed.get('button:24:35') and self.pressed.get('button:24:36'):
                self.switch(self.profiles[keys.index(c['note'])]['id'])
                return
            if repeated or kind == 'button' and not value and self.profile()['mappings'].get(control,{}).get('trigger')!='both':
                return
            self.route(control, value, source)

    def route(self, control, value, source):
        p = self.profile()
        mapping = p['mappings'].get(control)
        if not mapping:
            return
        toggle = 1 - self.commanded.get(control, int(bool(self.leds.get(control))))
        self.commanded[control] = toggle
        normal = value/16383 if control.startswith('fader:') else value
        args = [normal if a == '$value' else toggle if a == '$toggle' else self.values.get(control,.5) if a == '$position' else value if a == '$delta' else a for a in mapping['args']]
        packet = osc.encode(mapping['path'], args)
        send = self.armed and source in ('hardware', 'simulator') and p['adapter'] == 'osc'
        event = dict(kind='route', control=control, source=source, path=mapping['path'], args=args,
                     sent=False, mode='preview', raw=packet.hex(' '))
        if send:
            try:
                self.sock.sendto(packet, (p['host'], p['port']))
                event.update(sent=True, mode='UDP sent; delivery unconfirmed')
            except OSError as exc:
                self.armed = False
                event.update(mode='error; output disabled', error=str(exc))
        self.record(event)

    def raw(self, payload, source='replay'):
        with self.lock:
            decoded = self.decoder.decode(payload)
            self.record(dict(kind='frame', raw=payload.hex(' '), source=source))
            for event in decoded:
                if 'control' in event:
                    self.event(event['control'], event['value'], source)
                else:
                    self.record(dict(event, source=source))
            return decoded

    def receive_osc(self, packet, host):
        with self.lock:
            p = self.profile()
            if p['adapter'] != 'osc' or host != p['host']:
                return
            path, args = osc.decode(packet)
            routes = {'/strip/fader': 'fader', '/strip/mute': 'button', '/strip/solo': 'button',
                      '/strip/recenable': 'button', '/strip/name': 'scribble', '/strip/meter': 'meter'}
            if path not in routes or len(args) != 2 or type(args[0]) is not int or not 1 <= args[0] <= 24:
                self.record(dict(kind='osc-unmapped', path=path, args=args, source='osc-feedback'))
                return
            ch, value = args[0]-1, args[1]
            kind = routes[path]
            if kind == 'fader':
                if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 1:
                    raise ValueError('Invalid OSC fader feedback')
                value = round(value*16383)
            if kind == 'scribble':
                value = str(value)[:4]
            if kind == 'meter':
                # Meter math depends on the configured Ardour feedback mode; preserve raw evidence.
                self.record(dict(kind='meter-raw', control=f'meter:{ch}', value=value, source='osc-feedback'))
                return
            control = f'{kind}:{ch}' if kind != 'button' else f'button:{ch}:{ {"/strip/mute":8,"/strip/solo":7,"/strip/recenable":0}[path] }'
            self.event(control, value, 'osc-feedback', feedback=True)
            if kind == 'button':
                self.commanded[control] = int(bool(value))
