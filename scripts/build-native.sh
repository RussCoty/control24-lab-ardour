#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
cp data/catalog.json data/surface-geometry.json data/control-layout.json data/daw-actions.json native/Sources/Control24Lab/Resources/
if [[ -f web/assets/control24-reference.png ]]; then
    cp web/assets/control24-reference.png native/Sources/Control24Lab/Resources/
fi
swift build --package-path native -c release
native_bin="$(swift build --package-path native -c release --show-bin-path)"
app_path="$task_root/build/Control24 Lab.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$app_path/Contents/Helpers"
cp "$native_bin/Control24Lab" "$app_path/Contents/MacOS/Control24Lab"
cp "$native_bin/Control24Bridge" "$app_path/Contents/Helpers/Control24Bridge"
cp native/Sources/Control24Lab/Resources/* "$app_path/Contents/Resources/"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Control24Lab</string>
<key>CFBundleIdentifier</key><string>com.control24.lab</string>
<key>CFBundleName</key><string>Control24 Lab</string>
<key>CFBundleDisplayName</key><string>Control|24 Lab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Control24</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Send configured OSC controls to your audio workstations and receive their surface feedback.</string>
</dict></plist>
PLIST
mkdir -p "$app_path/Contents/Library/LaunchDaemons"
cp scripts/com.control24.bridge.plist "$app_path/Contents/Library/LaunchDaemons/"
identity="${CONTROL24_SIGN_IDENTITY:-B8533E7A727261A47298809FCE0125FC15AC11B1}"
codesign --force --sign "$identity" --identifier com.control24.bridge "$app_path/Contents/Helpers/Control24Bridge"
codesign --force --sign "$identity" --identifier com.control24.lab "$app_path"
codesign --verify --strict "$app_path"
echo "Built: $app_path"
