#!/bin/zsh
# Builds build/NativeMonitor.app and dist/NativeMonitor.zip.
# Signs ad-hoc, or with $SIGN_ID (a code-signing identity) so macOS keeps permissions across rebuilds.
set -euo pipefail
cd "${0:A:h}/.."
VERSION=1.0.0
APP=build/NativeMonitor.app
rm -rf build dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.4 Sources/main.swift -o build/NativeMonitor
build/NativeMonitor --selftest

# Icon
swift scripts/make-icon.swift build/icon.png
mkdir build/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cp build/NativeMonitor "$APP/Contents/MacOS/NativeMonitor"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.nmani97.NativeMonitor</string>
  <key>CFBundleName</key><string>NativeMonitor</string>
  <key>CFBundleDisplayName</key><string>NativeMonitor</string>
  <key>CFBundleExecutable</key><string>NativeMonitor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>NativeMonitor lowers your Mac's sound below your monitor's lowest volume step. Nothing is recorded.</string>
</dict></plist>
EOF

xattr -cr "$APP"
codesign --force --sign "${SIGN_ID:--}" "$APP"
(cd build && ditto -c -k --norsrc --noextattr --noacl --keepParent NativeMonitor.app ../dist/NativeMonitor.zip)
echo "built $APP and dist/NativeMonitor.zip"
