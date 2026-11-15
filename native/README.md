# Control|24 Lab — native Swift application

Native SwiftUI/AppKit for macOS 14 and later. No Python process, web server, browser, JavaScript runtime, or third-party Swift packages are required to run the app.

From the project root, build the macOS application:

```sh
scripts/build-native.sh
```

The result is `build/Control24 Lab.app`. Open it from Finder. The package script builds for the current Mac's architecture, bundles the photo/catalog/calibration and ad-hoc signs the app. It is a local development build, not a notarized distribution release.

For development, open `native/Package.swift` in Xcode, or run:

```sh
swift run --package-path native Control24Lab
swift test --package-path native
```

The app includes the photograph-backed surface, projected controls, a searchable 681-entry evidence catalog, a native inspector, profile/mapping editing, NDJSON event logging/export, native packet decoding/capture import, native output-byte previews, UDP OSC routing and an optional OSC feedback listener. An optional libpcap helper supports experimental Ethernet ownership and input capture. Physical feedback validation, HUI and MCU remain pending.

Profiles and events are saved under `~/Library/Application Support/Control24Lab/`. The native app uses its own settings and does not depend on the browser prototype's `runtime/` directory. Output starts disabled and is disabled when profiles are switched/saved. Enabling OSC sends real commands from simulated controls to the configured IP/port. Offline replay remains preview-only. The optional native feedback port defaults to 9126 so it can coexist with the browser bridge's 9124 listener.

The upper and lower desk panels have separate projective transforms. Fader lanes/caps, control footprints, lower-panel circular controls and display text bases follow the photo's panel geometry. Fader dragging uses the inverse transform, so pointer motion follows the photographed slot. Calibration is stored in the shared `data/surface-geometry.json`; packaging synchronizes it into the native resource bundle. The shared manual-audited layout positions all 467 catalogued buttons. Photo calibration and wire addresses still need physical validation.

Use the numbered profile buttons below the photo; desk selection uses Shift+Option+F1–F6. Keyboard shortcuts Control-Option-1 through Control-Option-6 also select profiles. Command-Shift-Period disables OSC output. All input sources, profile changes, feedback and route decisions appear in the event stream. Leaving the app releases held simulated controls.

Catalog and photograph provenance are documented in `docs/SOURCES.md` at the project root. The image remains a prototype reference with static illumination; orange overlays indicate received/simulated feedback rather than measured physical lamps.


**Assigning controls:** select Ardour or Mixbus, click **Learn mappings**, then click a photo control (or press it on the connected desk). Choose a searchable action and click **Assign action**. Output is disabled while learning. **Learn hardware address** can associate a source-reported address with the selected physical control when the desk becomes available.


**Hardware:** click **Hardware**, select the Ethernet interface, and start the local receiver. The sheet supplies a command for the bundled `Control24Bridge` executable. On this Mac BPF capture needs elevated access, so run only that helper with appropriate privileges. Passive mode does not claim the desk; active mode requires its MAC and must be the only surface owner. No hardware is currently connected. General physical LED/ring/display/motor feedback is not yet implemented.
