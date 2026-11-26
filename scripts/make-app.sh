#!/usr/bin/env bash
# Build a launchable "MRI Viewer.app" in build/.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product MRIViewer
swift build -c release --product mritool
BIN="$(swift build -c release --show-bin-path)"
APP="build/MRI Viewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MRIViewer" "$APP/Contents/MacOS/MRIViewer"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.mri-viewer</string>
  <key>CFBundleName</key><string>MRI Viewer</string>
  <key>CFBundleDisplayName</key><string>MRI Viewer</string>
  <key>CFBundleExecutable</key><string>MRIViewer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.medical</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built: $APP"
echo "CLI:   $BIN/mritool"
