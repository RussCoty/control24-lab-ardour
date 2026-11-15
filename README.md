# Control|24 Lab

A new local application for the **original Digidesign Control|24**, distinct from the later C|24. This is the first implementation milestone: a photograph-backed simulator, protocol workbench, evidence catalog, and OSC routing core.

**Native Swift macOS app:** build with `scripts/build-native.sh`, then open `build/Control24 Lab.app`. The [native app guide](native/README.md) covers Xcode, packaging and native settings. It runs without Python or a browser. The browser prototype below remains available for development.

Run from this directory with Python 3.11 or newer:

```sh
python3 -m control24.server --osc-port 9124
```

Open **http://127.0.0.1:8124**. The base application has no pip/npm dependencies and does not need administrator access. `--osc-port` is optional; omitting it disables inbound OSC. The interface is served only on localhost. Optional OSC feedback listens on UDP on all network interfaces.

The [implementation plan](docs/IMPLEMENTATION.md) describes the full hardware bridge, DAW adapters, remote-machine support, and lighting integrations. The [protocol notes](docs/PROTOCOL.md) record source evidence and uncertainty.

## Try it

1. Drag a fader on the photograph, or use the accessible channel-focus slider. Press a channel/transport button and watch its input events. Scroll over a rotary encoder to log detents.
2. Select a control to inspect its ID, evidence, mapping, and feedback encoding. A button press and its feedback LED are separate states. Orange dots represent simulated/received LED feedback; the source photograph also contains static illuminated LEDs.
3. Open **Control inventory** to search 681 research entries, including controls, output addresses, and analog inventory candidates. This count does **not** mean 681 individually verified physical controls. The manual layout now positions all 467 catalogued buttons; analog controls and output addresses are tracked separately.
4. Use **Protocol lab → Load sample frame → Decode & log offline**. The native decoder handles buttons, 14-bit faders, running status, channel encoders, and jog. Unknown messages and raw frames remain in the event log. Replay never sends OSC.
5. Open **Profiles & mappings** to edit a destination and its OSC mappings. Apply mappings to the draft, then save. The selected mapping fields also apply when saving. Shift+Option+F1–F6 on the desk choose the six profiles; a physical desk connection is required before this can work on the real keys.
6. Export events as NDJSON, export the catalog as JSON, or calibrate photo hotspots. Calibration is browser-local and can be exported; profile edits and events are stored in `runtime/`.

## Current adapter capabilities

| Profile | Current implementation |
| --- | --- |
| Ardour | OSC UDP output; fader, mute, solo, record-enable and basic transport mappings. Optional strip feedback. DAW configuration/hardware testing pending. |
| Mixbus | Same OSC starting map; verify against the installed version and surface configuration. |
| Pro Tools, local/network | Saved destination profiles; HUI MIDI adapter and remote agent planned. |
| DaVinci Resolve | Saved destination profile; MCU adapter and installed-version capability testing planned. |
| OSC lighting | Editable OSC profile with no invented venue addresses. Needs the lighting controller's actual command map. Art-Net/sACN adapters planned. |

**OSC output is initially disabled.** Set the intended destination IP and UDP port and enable it explicitly. While enabled, simulator fader/button actions send real OSC commands. Profile switches, profile saves, and process restarts disable it. A logged UDP send is not delivery confirmation. The native Hardware helper includes experimental ownership/keepalive and fader echo; general physical LED/motor/display feedback remains pending desk testing.

For Ardour, enable OSC in its control-surface preferences, configure a 24-strip bank, and set feedback to return strip IDs 1–24 with positional faders. Configure the feedback destination to this machine and port 9124 when using `--osc-port 9124`. The native app’s **Connect DAW** sends `/set_surface` and `/refresh` with 24 strips and positional faders, using native feedback port 9126. The browser prototype does not negotiate a session. Meter values are preserved as raw evidence until the feedback mode is explicitly configured.

## Passive hardware capture

The optional capture helper requires Scapy and OS packet-capture access. It **only listens**; it does not bring an offline desk online, claim ownership, acknowledge packets, or move motors. An unclaimed desk may emit only announcements. Capture a known working session for button/fader evidence.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install scapy
.venv/bin/python scripts/capture.py --interface en6 --console-mac 00:a0:7e:xx:xx:xx --output runtime/capture.ndjson
python3 scripts/replay.py runtime/capture.ndjson
```

Replace the example interface and MAC with real values (the placeholder MAC will be rejected). On macOS, BPF access must already be available; otherwise arrange a narrowly scoped capture helper. Do not run the entire UI as root. Do not run two active surface owners against the same desk during future handshake testing.

## Development / verification

```sh
python3 -m unittest discover -s tests -v
node --check web/app.js
python3 -m compileall -q control24 scripts
```

The tests exercise wire decoding/encoding, running status, bad frames, touch arbitration, profile persistence, source filtering, and a real local UDP loopback route. They do not establish compatibility with a physical desk or an installed DAW.

Source map extraction can be reproduced with `python3 scripts/build_catalog.py /path/to/C24-Engine-Renewed` using revision `94d7a3ba42726db8fd5da8151429cc7d28ea7b47`. Upstream code is not imported or executed. See [source and asset provenance](docs/SOURCES.md).


## License

Control24 Lab is available under the [MIT License](LICENSE). The prototype
photograph is optional and is excluded from the public repository. To use
a photograph you have permission to use, place a matching reference at
`web/assets/control24-reference.png` before running the native build script
or starting the web prototype.
