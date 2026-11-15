"""Local-only UI and event bridge. Run with python3 -m control24.server."""
import argparse
import json
import secrets
import socket
import threading
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from .engine import Engine, ROOT
from . import protocol


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, engine, token, **kwargs):
        self.engine, self.token = engine, token
        super().__init__(*args, directory=str(ROOT/'web'), **kwargs)

    def log_message(self, *args):
        pass

    def reply(self, data, status=200):
        encoded = json.dumps(data, allow_nan=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == '/api/state':
            try:
                after = int(parse_qs(parsed.query).get('after', ['0'])[0])
                self.reply(dict(self.engine.snapshot(after), token=self.token))
            except ValueError as exc:
                self.reply({'error': str(exc)}, 400)
        elif parsed.path == '/api/catalog':
            self.reply(self.engine.catalog)
        elif parsed.path == '/api/layout':
            self.reply(json.loads((ROOT/'data/control-layout.json').read_text()))
        elif parsed.path == '/api/actions':
            self.reply(json.loads((ROOT/'data/daw-actions.json').read_text()))
        elif parsed.path == '/api/log':
            path = self.engine.runtime/'events.ndjson'
            with self.engine.lock:
                body = path.read_bytes() if path.exists() else b''
            self.send_response(200)
            self.send_header('Content-Type', 'application/x-ndjson')
            self.send_header('Content-Disposition', 'attachment; filename="control24-events.ndjson"')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            super().do_GET()

    def do_POST(self):
        if self.headers.get('X-Control24-Token') != self.token:
            self.reply({'error': 'Reload the local application'}, 403)
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 262144:
                raise ValueError('Invalid request size')
            data = json.loads(self.rfile.read(length), parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Nonfinite JSON')))
            path = urlparse(self.path).path
            if path == '/api/event':
                self.engine.event(data['control'], data['value'], feedback=bool(data.get('feedback')))
            elif path == '/api/profile':
                self.engine.switch(data['id'])
            elif path == '/api/profile/save':
                self.engine.save_profile(data)
            elif path == '/api/arm':
                if type(data['enabled']) is not bool:
                    raise ValueError('enabled must be boolean')
                self.engine.arm(data['enabled'])
            elif path == '/api/raw':
                self.engine.raw(bytes.fromhex(data['hex']))
            elif path == '/api/preview':
                c = data['control']
                item = self.engine.controls[c]
                if item['kind'] == 'fader':
                    payload = protocol.fader_motor(item['channel']-1, int(data['value']))
                elif item['kind'] == 'ring':
                    payload = protocol.ring(item['channel']-1, int(data['value']))
                elif item['kind'] == 'scribble':
                    payload = protocol.scribble(item['channel']-1, data['value'])
                elif item['kind'] == 'counter':
                    payload = protocol.counter(data['value'])
                elif 'led' in item:
                    payload = protocol.button_led(item['led']['section'], item['led']['note'], bool(data['value']))
                else:
                    raise ValueError('No verified encoding available for this control')
                self.reply({'native': payload.hex(' '), 'frame': protocol.frame([payload]).hex(' '), 'sent': False})
                return
            else:
                self.reply({'error': 'Unknown endpoint'}, 404)
                return
            self.reply({'ok': True})
        except (ValueError, KeyError, TypeError, OverflowError) as exc:
            self.reply({'error': str(exc)}, 400)


def feedback_listener(engine, port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('0.0.0.0', port))
    engine.feedback_port = sock.getsockname()[1]

    def loop():
        while True:
            packet, address = sock.recvfrom(65535)
            try:
                engine.receive_osc(packet, address[0])
            except (ValueError, TypeError, OverflowError) as exc:
                with engine.lock:
                    engine.record(dict(kind='osc-error', source='osc-feedback', error=str(exc)))
    threading.Thread(target=loop, daemon=True).start()


def main():
    parser = argparse.ArgumentParser(description='Control|24 Lab local application')
    parser.add_argument('--port', type=int, default=8124)
    parser.add_argument('--osc-port', type=int, default=None, help='Optional UDP feedback port, e.g. 9124')
    args = parser.parse_args()
    engine = Engine()
    if args.osc_port is not None:
        feedback_listener(engine, args.osc_port)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), partial(Handler, engine=engine, token=secrets.token_urlsafe(32)))
    print(f'Control|24 Lab: http://127.0.0.1:{server.server_port}', flush=True)
    print('Hardware output: not implemented. OSC output: disabled until enabled in the UI.', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        engine.armed = False
        server.server_close()


if __name__ == '__main__':
    main()
