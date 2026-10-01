#!/bin/bash
# End-to-end check: the icon colour must match the health the app computes.
#
# The colour is the whole product, but it only exists on the real menu bar, so
# this launches the built app, screenshots the bar, and classifies the pixels the
# icon added. The expected colour is derived by polling the same config with the
# same provider code, so the assertion is "the icon matches the logic", which
# holds regardless of what the live APIs are doing at that moment.
#
# Fragile by nature: it screenshots the screen and reads the menu bar, so it
# needs a logged in GUI session and no other app is allowed to add a menu bar
# item of its own while it runs.
set -uo pipefail
cd "$(dirname "$0")/.."

APP_BINARY=".build/release/CIStatus"
CONFIG_DIR="$HOME/Library/Application Support/CIStatus"
PROBE=".build/debug/probe"
PIXELS=".build/debug/probe3"
AFTER="/tmp/cistatus-e2e-after.png"
BEFORE="/tmp/cistatus-e2e-before.png"
LOG="/tmp/cistatus-e2e.log"
config="${1:?usage: e2e.sh /path/to/config.json}"

for binary in "$APP_BINARY" "$PROBE" "$PIXELS"; do
  if [ ! -x "$binary" ]; then
    echo "missing $binary"
    echo "build with: swift build && swift build --product probe && swift build --product probe3"
    exit 1
  fi
done

kill_app() {
  pkill -f "CIStatus.*Contents/MacOS" 2>/dev/null
  pkill -f "$APP_BINARY" 2>/dev/null
  # The menu bar item outlives the process briefly, so wait for it to go or the
  # screenshot picks up the previous run's icon.
  for _ in $(seq 1 20); do
    pgrep -f "CIStatus.*Contents/MacOS" >/dev/null 2>&1 || return 0
    sleep 0.5
  done
}

# Bundle the bare executable so LSUIElement keeps it out of the Dock.
APP="/tmp/CIStatus-e2e.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$APP_BINARY" "$APP/Contents/MacOS/CIStatus"
[ -d .build/release/CIStatus_CIStatus.bundle ] && \
  cp -R .build/release/CIStatus_CIStatus.bundle "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>CIStatus</string>
  <key>CFBundleIdentifier</key><string>dev.dolivari.ciStatus.e2e</string>
  <key>CFBundleName</key><string>CIStatus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1

# The app reads this path, so back up and restore the user's real config.
BACKUP="$(mktemp)"
[ -f "$CONFIG_DIR/config.json" ] && cp "$CONFIG_DIR/config.json" "$BACKUP"
mkdir -p "$CONFIG_DIR"
cp "$config" "$CONFIG_DIR/config.json"

cleanup() {
  kill_app
  if [ -s "$BACKUP" ]; then cp "$BACKUP" "$CONFIG_DIR/config.json"; else rm -f "$CONFIG_DIR/config.json"; fi
  rm -f "$BACKUP"
}
trap cleanup EXIT

kill_app

# Ground truth: the same config, the same providers, no GUI.
expected="$("$PROBE" --overall "$config" | tail -1 | tr -d '[:space:]')"
echo "computed health: $expected"
if [ -z "$expected" ] || [ "$expected" = "config" ]; then
  echo "FAIL: could not compute the expected health"
  exit 1
fi

# Baseline the bar with nothing of ours running, so only the pixels our icon
# adds are classified. The bar also holds system items, one of which is a grey
# circle that would otherwise be read as our own.
screencapture -x -R0,0,3800,50 "$BEFORE"

"$APP/Contents/MacOS/CIStatus" >"$LOG" 2>&1 &

for _ in $(seq 1 20); do
  pgrep -f "CIStatus-e2e.app/Contents/MacOS" >/dev/null 2>&1 && break
  sleep 0.5
done

# Sample until the reading stops changing, so a half-drawn icon is not read.
result=""
previous=""
for _ in $(seq 1 12); do
  sleep 3
  if ! pgrep -f "CIStatus-e2e.app/Contents/MacOS" >/dev/null 2>&1; then
    echo "FAIL: app exited early"
    cat "$LOG"
    exit 1
  fi
  screencapture -x -R0,0,3800,50 "$AFTER"
  result="$("$PIXELS" "$BEFORE" "$AFTER" 2900 | tail -1)"
  [ "$result" = "$previous" ] && break
  previous="$result"
done
echo "$result"

# Health names and colour names differ, so map rather than uppercase both.
case "$expected" in
  ok)      expected_colour=GREEN ;;
  pending) expected_colour=ORANGE ;;
  failing) expected_colour=RED ;;
  unknown) expected_colour=GREY ;;
  *)       echo "FAIL: unrecognised health '$expected'"; exit 1 ;;
esac
if [ "$result" = "=> $expected_colour" ]; then
  echo "PASS: icon is $expected_colour, matching the computed health"
  exit 0
fi
echo "FAIL: icon reports '$result' but the computed health is $expected_colour"
exit 1
