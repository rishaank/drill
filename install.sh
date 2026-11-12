#!/bin/bash
# Installs (or updates) Drill into Applications and opens it.
#   curl -fsSL https://raw.githubusercontent.com/rishaank/drill/main/install.sh | bash
# Downloading with curl skips macOS's "downloaded from the internet" flag, so Drill opens with no security prompt.
set -euo pipefail
URL=https://github.com/rishaank/drill/releases/latest/download/Drill.zip
DEST=/Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }  # accounts that can't write to /Applications
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Drill…"
curl -fL --progress-bar "$URL" -o "$TMP/Drill.zip"
ditto -x -k "$TMP/Drill.zip" "$TMP"
osascript -e 'quit app "Drill"' >/dev/null 2>&1 || true
rm -rf "$DEST/Drill.app"
mv "$TMP/Drill.app" "$DEST/"
open "$DEST/Drill.app"
echo "Done! Drill is in $DEST. Open it any time from Launchpad or Spotlight. Your sets stay when you update."
