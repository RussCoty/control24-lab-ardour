"""Independent protocol implementation from documented Control|24 wire observations.

Inputs are Ethernet payloads (not full Ethernet frames). No network I/O here.
All encodings are source-reported until verified against this user's hardware.
"""
import struct

ETHERTYPE = 0x885F


def frame(messages, sequence=1, acknowledgement=0, command=None):
    body = b''.join(messages)
    length = 16 + len(body)
    header = struct.pack('>HHIIHH', length, 0, sequence, acknowledgement, 0,
                         len(messages) if command is None else command)
    return (header + body).ljust(46, b'\0')


def button_led(section, note, on):
    if not 0 <= section <= 31 or not 0 <= note <= 127:
        raise ValueError('Invalid LED address')
    return bytes([0x90, note, section | (0x40 if on else 0)])


def fader_motor(channel, value):
    if not 0 <= channel < 24 or not 0 <= value <= 16383:
        raise ValueError('Invalid fader address or value')
    return bytes([0xB0, channel, value >> 7, channel + 32, value & 127])


def scribble(channel, text):
    if not 0 <= channel < 24:
        raise ValueError('Invalid scribble address')
    return bytes([0xF0, 0x13, 1, 0x40, 0x20 + channel, 0]) + str(text)[:4].ljust(4).encode('ascii', 'replace') + b'\xf7'


def ring(channel, position):
    if not 0 <= channel < 24 or not 0 <= position <= 14:
        raise ValueError('Ring requires channel 0..23 and position 0..14')
    address = channel | (0x40 if position == 0 else 0)
    high = (0x40 >> (position - 1)) if 1 <= position <= 7 else 0
    low = (0x40 >> (position - 8)) if 8 <= position <= 14 else 0
    return bytes([0xF0, 0x13, 1, 0, address, high, low, 0xF7])


def counter(text):
    """Eight digits, no inferred frame rate or decimal-position conversion."""
    if len(text) != 8 or any(c not in '0123456789 ' for c in text):
        raise ValueError('Counter requires exactly eight digits/spaces')
    segments = [0x7E, 0x30, 0x6D, 0x79, 0x33, 0x5B, 0x5F, 0x70, 0x7F, 0x7B]
    return bytes([0xF0, 0x13, 1, 0x30, 0x19, 0] +
                 [0 if c == ' ' else segments[int(c)] for c in text] + [0xF7])


class Decoder:
    def __init__(self):
        self.msb = [None] * 24

    def decode(self, data):
        if len(data) < 16:
            raise ValueError('Truncated Control|24 header')
        length, _, sequence, ack, _, command = struct.unpack('>HHIIHH', data[:16])
        if length < 16 or length > len(data):
            raise ValueError('Invalid declared frame length')
        if length == 50:
            return [{'kind': 'announce', 'sequence': sequence, 'raw': data[:length].hex(' ')}]
        if command in (0xA000, 0xE200) or length == 16:
            return [{'kind': 'link', 'sequence': sequence, 'command': command}]
        out = []
        for msg in self._messages(data[16:length]):
            status, *values = msg
            if status & 0xF0 in (0x80, 0x90) and len(values) == 2:
                note, velocity = values
                section = velocity & 0xBF
                out.append({'kind': 'button', 'control': f'button:{section}:{note}',
                            'value': bool(velocity & 0x40), 'raw': bytes(msg).hex(' ')})
            elif status & 0xF0 == 0xB0 and len(values) == 2:
                cc, value = values
                if cc < 24:
                    self.msb[cc] = value
                elif 32 <= cc < 56:
                    ch = cc - 32
                    if self.msb[ch] is not None:
                        out.append({'kind': 'fader', 'control': f'fader:{ch}',
                                    'value': (self.msb[ch] << 7) | value,
                                    'raw': f'b0 {ch:02x} {self.msb[ch]:02x} {cc:02x} {value:02x}'})
                    else:
                        out.append({'kind': 'unknown', 'raw': bytes(msg).hex(' '), 'reason': 'LSB without MSB'})
                elif 64 <= cc < 88 or cc == 92:
                    out.append({'kind': 'encoder', 'control': f'encoder:{cc-64}' if cc != 92 else 'jog',
                                'value': value - 64, 'raw': bytes(msg).hex(' ')})
                else:
                    out.append({'kind': 'unknown', 'raw': bytes(msg).hex(' ')})
            else:
                out.append({'kind': 'unknown', 'raw': bytes(msg).hex(' ')})
        return out

    @staticmethod
    def _messages(data):
        status = None
        pending = []
        sysex = None
        for b in data:
            if b >= 0xF8:
                continue  # realtime bytes never clear running status
            if sysex is not None:
                sysex.append(b)
                if b == 0xF7:
                    yield sysex
                    sysex = None
                continue
            if b == 0xF0:
                sysex = [b]
                status, pending = None, []
            elif b & 0x80:
                status, pending = (b if b < 0xF0 else None), []
            elif status is not None:
                pending.append(b)
                needed = 1 if status & 0xF0 in (0xC0, 0xD0) else 2
                if len(pending) == needed:
                    yield [status, *pending]
                    pending = []
        if sysex is not None or pending:
            raise ValueError('Truncated native MIDI message')
