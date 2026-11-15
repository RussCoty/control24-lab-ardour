"""Replay captures into the local app as offline events (never routed live)."""
import argparse
import json
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('capture')
parser.add_argument('--url', default='http://127.0.0.1:8124')
args = parser.parse_args()
state = json.load(urllib.request.urlopen(args.url+'/api/state'))
with open(args.capture) as capture:
    count = 0
    for line in capture:
        entry = json.loads(line)
        if 'hex' not in entry:
            continue
        request = urllib.request.Request(args.url+'/api/raw', data=json.dumps({'hex': entry['hex']}).encode(),
            headers={'Content-Type': 'application/json', 'X-Control24-Token': state['token']})
        with urllib.request.urlopen(request) as response:
            json.load(response)
        count += 1
print(f'Replayed {count} Ethernet payloads (original timing not preserved)')
