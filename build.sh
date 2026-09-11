#!/bin/bash
# Build WiZard.app and (re)install it to /Applications.
#
# Works around the broken CommandLine Tools include dir ("redefinition of
# module 'SwiftBridging'") without sudo: a clang VFS overlay shadows the stale
# module.modulemap so only bridging.modulemap is seen. On healthy toolchains
# the -Xcc flags are harmless; delete them if you like.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="WiZard"
BUNDLE_ID="com.arshzip"

OVERLAY=/tmp/swiftfix.yaml
EMPTY=/tmp/empty.modulemap

if [ ! -f "$EMPTY" ]; then touch "$EMPTY"; fi
if [ ! -f "$OVERLAY" ]; then
cat > "$OVERLAY" <<'EOF'
{
  "version": 0,
  "roots": [
    {
      "name": "/Library/Developer/CommandLineTools/usr/include/swift",
      "type": "directory",
      "contents": [
        { "name": "bridging", "type": "file", "external-contents": "/Library/Developer/CommandLineTools/usr/include/swift/bridging" },
        { "name": "bridging.modulemap", "type": "file", "external-contents": "/Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap" },
        { "name": "module.modulemap", "type": "file", "external-contents": "/tmp/empty.modulemap" }
      ]
    }
  ]
}
EOF
fi

OUT="$APP_NAME.app/Contents/MacOS/$APP_NAME"
mkdir -p "$APP_NAME.app/Contents/MacOS" "$APP_NAME.app/Contents/Resources"
xcrun swiftc -O -Xcc -ivfsoverlay -Xcc "$OVERLAY" -o "$OUT" main.swift

# Bundle metadata
PLIST="$APP_NAME.app/Contents/Info.plist"
if [ ! -f "$PLIST" ]; then
cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>WiZard</string>
	<key>CFBundleDisplayName</key>
	<string>WiZard</string>
	<key>CFBundleExecutable</key>
	<string>WiZard</string>
	<key>CFBundleIdentifier</key>
	<string>com.arshzip</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
</dict>
</plist>
EOF
fi

if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APP_NAME.app/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP_NAME.app"

# Install to /Applications (the location the menu bar app runs from)
if [ -d "/Applications/$APP_NAME.app" ]; then
    cp "$OUT" "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME"
    PLIST2="/Applications/$APP_NAME.app/Contents/Info.plist"
    plutil -replace CFBundleName -string "$APP_NAME" "$PLIST2"
    plutil -replace CFBundleDisplayName -string "$APP_NAME" "$PLIST2"
    plutil -replace CFBundleExecutable -string "$APP_NAME" "$PLIST2"
    plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$PLIST2"
    plutil -replace CFBundleIconFile -string "AppIcon" "$PLIST2"
    mkdir -p "/Applications/$APP_NAME.app/Contents/Resources"
    if [ -f AppIcon.icns ]; then
        cp AppIcon.icns "/Applications/$APP_NAME.app/Contents/Resources/AppIcon.icns"
    fi
    codesign --force --sign - "/Applications/$APP_NAME.app"
fi

echo "Built: $OUT"
