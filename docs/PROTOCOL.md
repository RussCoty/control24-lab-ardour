# Protocol research notes

These are **source-reported observations**, not verified measurements of this user's desk. Reference: Engine Renewed revision `94d7a3ba42726db8fd5da8151429cc7d28ea7b47`, particularly `motore.py`, `led_finder.py`, and the two reference JSON maps. The implementation is independent; upstream program files are not runtime dependencies.

## Frame

Raw Ethernet EtherType `0x885F`. No IP address is used for the desk connection. The host bridge must be on the same Ethernet segment. Payload header:

| Bytes | Meaning currently used |
| --- | --- |
| 0–1 | Big-endian payload length, including 16-byte header and excluding Ethernet padding |
| 2–3 | Reserved/zero in observed senders |
| 4–7 | Sender sequence |
| 8–11 | Acknowledged sequence |
| 12–13 | Reserved/zero in observed senders |
| 14–15 | Command field / native message count |
| 16 onward | Native MIDI-like messages |

Source implementations pad payloads to at least 46 bytes. Handshake/wake command field `E2 00`, ACK `A0 00`, ping `00 00`. The current decoder records link messages, but the server does not implement an active session or send them. A 50-byte payload is treated as an announcement following the upstream heuristic; validate its full signature before active deployment.

## Inputs and outputs

| Function | Observed native representation | Current support |
| --- | --- | --- |
| Button press/release | `90 note velocity`; section = velocity with bit `0x40` removed; press = bit `0x40` set | Decode and simulator |
| Touch | Channel section `0..23`, note `09`, same down/up bit | Decode; feedback deferred during touch |
| Fader | `B0 ch MSB (B0) ch+32 LSB`; position `(MSB << 7) | LSB` | 14-bit decode and motor-command preview |
| Encoder | CC `64..87`; delta `value - 64` | Decode/log; scroll simulator |
| Jog | CC `92`; raw delta `value - 64` | Decode/log; application direction mapping still to validate |
| Button LED | `90 note (section | 0x40)` on, `90 note section` off | Address catalog, state simulation, command preview |
| Ring | `F0 13 01 00 address high low F7` | One-position pattern preview; richer patterns pending |
| Scribble | `F0 13 01 40 (0x20+ch) 00 [four ASCII chars] F7` | Preview, UI and OSC name feedback |
| Counter | `F0 13 01 30 19 dot-mask [eight segment bytes] F7` | Eight-digit no-dot preview and UI |
| Channel automation | `F0 13 01 20 ch mask F7` | Catalog/research only |
| Counter indicators | `F0 13 01 20 19 mask F7` | Catalog/research only |
| Meter | Native/output patterns and conversion need dedicated audit | Catalog and raw OSC evidence only |

Do not use a conventional MIDI note-on velocity-zero interpretation here. Velocity contains section and pressed state. The native stream uses running status, including the paired fader CCs. The decoder reconstructs these pairs rather than dropping the LSB. SysEx and unknown native commands are retained for investigation. Partial messages at frame boundaries are currently rejected; cross-frame reassembly must be driven by actual capture evidence.

Source-reported automation masks: off `00`, read `04`, touch `08`, latch `10`, trim `20`, write `40`. Counter indicator masks: bars/beats `08`, feet/frames `10`, timecode `20`, min/sec `40`. The upstream HUI-to-counter mode detection uses decimal-point heuristics, which should not become a protocol guarantee without captures for each mode. Counter preview currently supports only eight digits/spaces and no decimal points.

## Catalog provenance and gaps

The reference map has 184 entries: 182 buttons and two ambiguous encoder entries. Expand section-zero button templates over 24 channels, join factual LED addresses, and add output/control families from the engine. After the manual audit, 681 generated entries include analog inventory, output-only addresses, channel families, and source-reported monitoring candidates; preamp-only families stop at channel 16. They are neither a count of physical buttons nor proof of complete coverage.

Two encoder-map entries (`CC 0` and `CC 64`) disagree with the engine's use of CC 0 for fader MSB and CC 64 onward for channel encoders. The catalog uses the engine's ranges and preserves this discrepancy in the research record. Unknown panel labels remain unknown. LED addresses are not assumed to establish an input address.

Future verification should store original captures and expected normalized events as fixtures, preserving capture direction, MAC, firmware, timing, source revision and a physical action description. A guided LED test should let the operator identify one lamp at a time and attach the result to the catalog, rather than sweeping arbitrary raw commands while mixing.
