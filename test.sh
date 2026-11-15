#!/bin/bash
# Builds Drill, then in an isolated copy (its own bundle ID, so it never touches your real sets):
#   1. runs the built-in self-check (engine, storage, schedule math)
#   2. seeds Drill 1.x web storage, launches, and checks the sets migrate and a study question can be answered.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh >/dev/null
pkill -f drill-test/Drill.app || true
ID=io.github.rishaank.drill.test
T="${TMPDIR:-/tmp}/drill-test"
rm -rf "$T" && mkdir -p "$T" && cp -R "${TMPDIR:-/tmp}/drill-build/Drill.app" "$T/"
plutil -replace CFBundleIdentifier -string "$ID" "$T/Drill.app/Contents/Info.plist"
codesign --force --sign - "$T/Drill.app" 2>/dev/null
clean() { rm -rf ~/Library/WebKit/"$ID" ~/Library/Caches/"$ID" ~/Library/Preferences/"$ID".plist ~/Library/Application\ Support/"$ID"; }
fail() { echo "$1"; echo "Self-check FAILED"; clean; exit 1; }
# Launched through LaunchServices like a real app: run straight from a shell, SwiftUI never opens the window.
run() { : >"$T/out.txt"; local e=(); for v in "$@"; do e+=(--env "$v"); done
  timeout 60 open -n -W "${e[@]}" --stdout "$T/out.txt" --stderr "$T/out.txt" "$T/Drill.app" || true; cat "$T/out.txt"; }

out=$(run DRILL_SELFTEST=1)
grep -q "self-check done" <<<"$out" || fail "$out"

clean
seed=$(python3 -c '
import json
sets = [{"id": 1731600000123, "name": "Old set", "cards": [{"t": "Mitochondria", "d": "Makes ATP", "lv": 1, "miss": 0}, {"t": "Ribosome", "d": "Makes proteins", "lv": 0, "miss": 2}, {"t": "Nucleus", "d": "Holds DNA", "lv": 0, "miss": 0}]}]
cfg = {"ai": False, "model": "auto", "answerWith": "term", "provider": "claude", "days": ["2026-11-13"]}
plan = {"view": {"start": 360, "end": 1380}, "blocks": [{"id": "b1", "start": 540, "end": 600, "title": "Bio"}]}
print(json.dumps({"drill.sets": json.dumps(sets), "drill.cfg": json.dumps(cfg), "drill.plan": json.dumps(plan)}))')
out=$(run "DRILL_SEED_WEBSTORAGE=$seed" DRILL_UI=study DRILL_QUIT=12)
clean
grep -q "migrated: 1 sets, 1 days, 1 blocks" <<<"$out" || fail "$out"
grep -q "^ui: answered" <<<"$out" && ! grep -q "FAILED" <<<"$out" || fail "$out"
echo "Self-check passed"
