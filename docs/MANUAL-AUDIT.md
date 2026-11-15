# Original Control|24 manual audit

Source: Digidesign Control|24 Guide, PN 9106-18918-00 REV A 03/06, [manufacturer-authored PDF hosted by Thomann](https://images.thomann.de/pics/atg/atgdata/document/manual/138371_manual.pdf). Figure 1 on printed page 40 (PDF page 50) provides the top-down control drawing. Section detail drawings were used to identify labels and rows.

`data/control-layout.json` stores the manual coordinates, panel-relative footprints, evidence and wire status. `scripts/build_layout.py` reproduces it and rejects missing catalogued buttons or duplicate regions. The photo and its two projective panel transforms are retained.

- 681 catalog entries, including output addresses, sensor entries and analog inventory.
- 467 catalogued buttons, all 467 placed on the photo.
- 550 manual layout regions plus 24 independently projected fader tracks. Touch sensors share the faders.
- Preamp HPF/source controls limited to channels 1–16; channels 17–24 are submixer inputs.
- Function keys use two vertical columns; normal F1–F10 remain assignable. Shift+Option+F1–F6 selects profiles.

Placement is audited; wire addressing is not fully validated. Some monitoring controls have only LED-address evidence, which does not prove the same input address. They are labelled unverified rather than silently treated as working inputs. The lower edit-tools row differs between the guide and upstream legends; preserve IDs pending physical verification. Analog gain/monitor pots and rear phantom switches are inventory items, not promised digital inputs. Fixed meter/indicator outputs are not assignable button inputs.

The desk is not connected as of this audit. Physical test procedure: run the input helper, enter Learn mappings, press one control at a time, compare raw address and label, bind any correction, then release it. Repeat for all controls before validating lamp/ring/counter encodings. Store corrected bindings separately from source evidence. Physical output support requires a subsequent implementation and bench test.
