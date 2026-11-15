# Source and asset provenance

Read on 6 November 2026.

| Source | Use |
| --- | --- |
| [Control24 Engine Renewed](https://github.com/Davitekk/C24-Engine-Renewed), revision `94d7a3ba42726db8fd5da8151429cc7d28ea7b47` | Native protocol research, factual control/LED address extraction, HUI/modern macOS feasibility. |
| [Button map](https://github.com/Davitekk/C24-Engine-Renewed/blob/94d7a3ba42726db8fd5da8151429cc7d28ea7b47/Control24-LED-Finder/c24_mapping.json) and [LED map](https://github.com/Davitekk/C24-Engine-Renewed/blob/94d7a3ba42726db8fd5da8151429cc7d28ea7b47/Control24-LED-Finder/c24_led_dictionary.json) | Names and wire addresses transformed by `scripts/build_catalog.py`; per-entry source links retained. |
| [Original Control24 product-style PNG](https://github.com/Davitekk/C24-Engine-Renewed/blob/94d7a3ba42726db8fd5da8151429cc7d28ea7b47/Control24-Engine/Control24.png) | `web/assets/control24-reference.png`, unmodified, used as a local prototype visual reference. |
| [ReaControl24 original](https://github.com/phasewalker18/ReaControl24) and [maintained fork](https://github.com/phunkyg/ReaControl24) | Architecture/protocol history and OSC bridge reference. No source files copied into this project. |
| [Original Control|24 Guide](https://images.thomann.de/pics/atg/atgdata/document/manual/138371_manual.pdf) | Manufacturer-authored guide used to audit all catalogued button positions and analog inventory; see MANUAL-AUDIT.md. |
| [Ardour OSC basics](https://manual.ardour.org/using-control-surfaces/controlling-ardour-with-osc/osc-control/) | OSC transport/control addresses. |
| [Ardour feedback](https://manual.ardour.org/using-control-surfaces/controlling-ardour-with-osc/feedback-in-osc/) | Strip fader positions, names, mute/solo/record feedback and the importance of two-way state. |
| [Ardour OSC setup](https://manual.ardour.org/using-control-surfaces/controlling-ardour-with-osc/osc-setup-dialog/) | Bank, feedback port and gain-mode configuration. |
| [Harrison Mixbus manual](https://rsrc.harrisonconsoles.com/mixbus/manuals/harrison_mixbus_v4_manual.pdf) | Historical OSC capability; current installed-version testing is outstanding. |

The upstream Engine Renewed snapshot has no top-level license grant visible in the inspected tree. The original ReaControl24 README identifies GPLv3. This project does not vendor or import either engine. Photo ownership and redistribution permission are not established by the repository's presence; before distributing a packaged application, replace the prototype image with a permission-cleared image or a new photograph of the user's desk, and review source/asset provenance. No project license is being inferred from upstream availability.

Development Ardour actions and OSC negotiation were checked directly in the user’s checkout (`gtk2_ardour/editor_actions.cc`, `ardour.keys.in`, `libs/surfaces/osc/osc.cc` and `osc.h`), without modifying it. Generated action identifiers retain source paths.
