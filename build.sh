#!/bin/bash
# Builds Drill.app (Apple Silicon + Intel) and packs it as dist/Drill.dmg and dist/Drill.zip.
# Needs only Apple's free command line tools:  xcode-select --install
# Usage: ./build.sh [version]
set -euo pipefail
cd "$(dirname "$0")"
VERSION=${1:-2.0.0}
# Staged outside the project: iCloud Drive re-adds file metadata to anything inside it, which breaks the code signature.
B="${TMPDIR:-/tmp}/drill-build"
APP="$B/Drill.app"
rm -rf "$B" dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$B/dmg" dist

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.3" -Xlinker -weak_framework -Xlinker FoundationModels -o "$B/Drill-$arch" Sources/*.swift
done
lipo -create "$B/Drill-arm64" "$B/Drill-x86_64" -output "$APP/Contents/MacOS/Drill"
cp AppIcon.icns drill-set.skill "$APP/Contents/Resources/"
unzip -p drill-set.skill drill-set/SKILL.md > "$APP/Contents/Resources/drill-set.md"  # the same instructions as a prompt for any chatbot
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Drill</string>
  <key>CFBundleDisplayName</key><string>Drill</string>
  <key>CFBundleIdentifier</key><string>io.github.rishaank.drill</string>
  <key>CFBundleExecutable</key><string>Drill</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.3</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Made by Rishaan Kotian</string>
  <!-- Ollama / LM Studio run on plain http://localhost -->
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
# Ad-hoc signature (free). Without a valid one, macOS calls a downloaded app "damaged" and offers no way to open it.
xattr -cr "$APP"  # Finder metadata copied in with the sources makes codesign refuse the bundle
codesign --force --sign - "$APP"

ditto -c -k --norsrc --noextattr --keepParent "$APP" dist/Drill.zip
cp -R "$APP" "$B/dmg/" && ln -s /Applications "$B/dmg/Applications"
hdiutil create -quiet -volname Drill -srcfolder "$B/dmg" -ov -format UDZO dist/Drill.dmg
echo "Built dist/Drill.dmg and dist/Drill.zip (v$VERSION). App to try: $APP"
