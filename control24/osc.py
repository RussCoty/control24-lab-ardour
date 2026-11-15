"""Minimal OSC 1.0 messages. Bundles deliberately rejected for this first slice."""
import math
import struct


def string(value):
    data = value.encode('utf8') + b'\0'
    return data + b'\0' * (-len(data) % 4)


def encode(path, args):
    if not path.startswith('/') or '\0' in path:
        raise ValueError('OSC address must start with / and contain no NUL')
    tags, payload = ',', b''
    for arg in args:
        if isinstance(arg, (bool, int)):
            tags += 'i'
            payload += struct.pack('>i', int(arg))
        elif isinstance(arg, float) and math.isfinite(arg):
            tags += 'f'
            payload += struct.pack('>f', arg)
        elif isinstance(arg, str):
            tags += 's'
            payload += string(arg)
        else:
            raise ValueError('Unsupported OSC argument')
    return string(path) + string(tags) + payload


def decode(data):
    offset = 0

    def read_string():
        nonlocal offset
        end = data.index(0, offset)
        value = data[offset:end].decode('utf8')
        offset = (end + 4) & ~3
        return value

    try:
        path, tags = read_string(), read_string()
        if not path.startswith('/') or not tags.startswith(','):
            raise ValueError('Expected OSC message')
        args = []
        for tag in tags[1:]:
            if tag == 's':
                args.append(read_string())
            elif tag in ('i', 'f'):
                args.append(struct.unpack('>i' if tag == 'i' else '>f', data[offset:offset+4])[0])
                offset += 4
            else:
                raise ValueError('Unsupported OSC type')
        if offset != len(data):
            raise ValueError('Trailing OSC bytes')
        return path, args
    except (IndexError, UnicodeError, struct.error) as exc:
        raise ValueError('Malformed OSC packet') from exc
