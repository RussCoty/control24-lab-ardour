"""Passive Ethernet capture to NDJSON. No handshake or transmission.

Install scapy in a project venv. Run on the desk's LAN with BPF/pcap access.
An offline or unclaimed desk may emit only announcements. Active session later.
"""
import argparse
import json
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--interface', required=True)
    parser.add_argument('--console-mac', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    from scapy.all import Ether, sniff
    mac = args.console_mac.lower()
    if len(mac.split(':')) != 6 or any(len(p) != 2 or any(c not in '0123456789abcdef' for c in p) for p in mac.split(':')):
        parser.error('Invalid console MAC')
    with open(args.output, 'a', buffering=1) as out:
        def receive(packet):
            if Ether in packet and packet[Ether].type == 0x885F and packet[Ether].src.lower() == mac:
                out.write(json.dumps(dict(time=time.time(), source=mac,
                                         hex=bytes(packet[Ether].payload).hex(' ')))+'\n')
        print(f'Listening on {args.interface}; no packets will be sent', flush=True)
        sniff(iface=args.interface, filter=f'ether proto 0x885f and ether src {mac}', prn=receive, store=False)


if __name__ == '__main__':
    main()
