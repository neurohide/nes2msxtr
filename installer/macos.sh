#!/bin/sh
# macOS installer: nes2msxtr.app (the app, with the project in
# Contents/Resources/project) in a drag-to-Applications disk image.
# usage: installer/macos.sh [version] [rid]     rid: osx-arm64 (default) or osx-x64
# writes dist/nes2msxtr-<version>-<rid>.dmg
set -e
cd "$(dirname "$0")/.."
VERSION=${1:-1.3}
RID=${2:-osx-arm64}
STAGE=dist/mac-$RID
APP=$STAGE/nes2msxtr.app
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

dotnet publish app/Nes2MsxTr.App -c Release -r "$RID" -o "$APP/Contents/MacOS"
python3 tools/package_tool.py --dir "$APP/Contents/Resources/project"
cp installer/icon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>nes2msxtr</string>
  <key>CFBundleDisplayName</key><string>nes2msxtr</string>
  <key>CFBundleIdentifier</key><string>net.nes2msxtr.app</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>nes2msxtr-app</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# ad-hoc signature: Apple silicon refuses to run unsigned code
codesign --force --deep -s - "$APP"

ln -s /Applications "$STAGE/Applications"
DMG=dist/nes2msxtr-$VERSION-$RID.dmg
rm -f "$DMG"
hdiutil create -volname "nes2msxtr $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
echo "wrote $DMG"
