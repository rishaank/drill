#!/bin/bash
# Builds Drill and runs index.html's built-in self-check inside the real app, headless.
# The copy gets its own bundle ID, so it never reads or writes the sets in your installed Drill.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh >/dev/null
ID=io.github.rishaank.drill.test
T="${TMPDIR:-/tmp}/drill-test"
rm -rf "$T" && mkdir -p "$T" && cp -R "${TMPDIR:-/tmp}/drill-build/Drill.app" "$T/"
plutil -replace CFBundleIdentifier -string "$ID" "$T/Drill.app/Contents/Info.plist"
codesign --force --sign - "$T/Drill.app" 2>/dev/null
clean() { rm -rf ~/Library/WebKit/"$ID" ~/Library/Caches/"$ID" ~/Library/Preferences/"$ID".plist; }
clean
out=$(DRILL_DEBUG=1 DRILL_QUIT=1 DRILL_HASH='#test' DRILL_EVAL='await new Promise(r => setTimeout(r, 2500)); return document.title' timeout 60 "$T/Drill.app/Contents/MacOS/Drill" 2>&1 || true)
clean
# A fresh copy opens the welcome sheet: a second page in a native sheet, which must load cleanly too.
if grep -qE "FAILED|^error:" <<<"$out" || ! grep -q "self-check done" <<<"$out" || ! grep -q "sheet ready: welcome" <<<"$out"; then
  echo "$out"; echo "Self-check FAILED"; exit 1
fi
echo "Self-check passed"
