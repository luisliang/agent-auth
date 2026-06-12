#!/bin/bash
set -euo pipefail
NAME="AgentAuth"
SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Desktop/$NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Compile
swiftc -o "$APP/Contents/MacOS/$NAME" \
  "$SRC/$NAME.swift" \
  -framework SwiftUI -framework AppKit -framework Foundation \
  -parse-as-library \
  -target arm64-apple-macosx14.0

# Info.plist
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.agent.auth</string>
    <key>CFBundleName</key>
    <string>$NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Generate icns from SVG
qlmanage -t -s 1024 -o /tmp "$SRC/AppIcon.svg" > /dev/null 2>&1
ICONSET=/tmp/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 64 128 256 512; do
  sips -z $s $s /tmp/AppIcon.svg.png --out "$ICONSET/icon_${s}x${s}.png" > /dev/null 2>&1
done
cp /tmp/AppIcon.svg.png "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" /tmp/AppIcon.svg.png

# Sign
codesign --force --deep --sign - "$APP"

# Zip for release
ditto -c -k --sequesterRsrc --keepParent "$APP" "$SRC/${NAME}.app.zip"

echo "✅ $APP built + signed + zipped"
