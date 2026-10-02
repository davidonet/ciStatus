#!/bin/bash
# Register ciStatus as a login item.
#
# Tokens live in tokens.json next to the config, mode 600, which the app can read
# whenever it starts. So this script has no secrets of its own to handle: it only
# writes a plist that launches the app at login.
#
# Run with --install-tokens to store a token per service as well, which is the
# one step needed before this agent is useful.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="CIStatus"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT="$AGENT_DIR/dev.dolivari.ciStatus.plist"
CONFIG_DIR="$HOME/Library/Application Support/$APP_NAME"
CONFIG="$CONFIG_DIR/config.json"
TOKENS="$CONFIG_DIR/tokens.json"

if [ ! -f "$CONFIG" ]; then
  echo "No config at $CONFIG"
  echo "Open CIStatus → Settings… and add your projects, or copy the example:"
  echo "  mkdir -p \"$CONFIG_DIR\""
  echo "  cp \"$(cd "$(dirname "$0")/.." && pwd)/Sources/CIStatus/Resources/config.example.json\" \"$CONFIG\""
  exit 1
fi

# Reads which services the config wants enabled, so only those are prompted for.
# Parsed with python because the section is JSON, and a grep would match keys
# that are not service names.
SERVICES=()
if command -v python3 >/dev/null 2>&1; then
  while IFS= read -r name; do
    [ -n "$name" ] && SERVICES+=("$name")
  done < <(python3 - "$CONFIG" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        tokens = json.load(fh).get("tokens") or {}
except Exception as exc:
    print(f"warning: could not read the tokens section: {exc}", file=sys.stderr)
    tokens = {}
for service, enabled in tokens.items():
    # The previous shape was {"github": {"keychain": true}}.
    if isinstance(enabled, dict):
        enabled = enabled.get("keychain")
    if enabled is True:
        print(service)
PY
  )
else
  echo "warning: python3 not found, so the enabled services cannot be read from the config."
fi

if [ "${#SERVICES[@]}" -eq 0 ]; then
  echo "No service in $CONFIG is enabled in its \"tokens\" section."
  echo "Open CIStatus → Settings… and save a token for at least one service."
  exit 1
fi

if [ ! -f "$TOKENS" ] && [ "${1:-}" != "--install-tokens" ]; then
  echo "No token file at $TOKENS"
  echo "Add one with: $0 --install-tokens"
  echo
fi

if [ "${1:-}" = "--install-tokens" ]; then
  echo "This writes each token to $TOKENS (mode 600)."
  echo
  for service in "${SERVICES[@]}"; do
    read -r -s -p "  $service token: " value
    echo
    if [ -z "$value" ]; then
      echo "  skipped $service"
      continue
    fi
    # Through `probe`, so the file is written and chmod'd by the same code the
    # app reads it with, rather than by hand-rolled shell here.
    if swift build --product probe >/dev/null 2>&1 \
         && ./.build/debug/probe --store-token "$service" "$value" >/dev/null 2>&1; then
      echo "  stored $service"
    else
      echo "  could not store $service"
    fi
    unset value
  done
  echo
fi

# Warn rather than fail: the app runs fine at login without tokens, it just
# reports every source as unreachable until one is stored.
MISSING=()
for service in "${SERVICES[@]}"; do
  grep -q "\"$service\"" "$TOKENS" 2>/dev/null || MISSING+=("$service")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "No stored token for: ${MISSING[*]}"
  echo "Those rows will report as unreachable. Re-run with --install-tokens to add them."
  echo
fi

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.dolivari.ciStatus</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/CIStatus/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/CIStatus/launchd.err.log</string>
</dict>
</plist>
PLIST

mkdir -p "$AGENT_DIR"
mkdir -p "$HOME/Library/Logs/CIStatus"

# A stale copy would be merged rather than replaced, so remove it first.
launchctl bootout "gui/$(id -u)/dev.dolivari.ciStatus" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "Installed $AGENT"
echo "It will start at login and read its tokens from $TOKENS"
echo
echo "  log:     ~/Library/Logs/CIStatus/ciStatus.log"
echo "  stop:    launchctl bootout gui/$(id -u)/dev.dolivari.ciStatus"
echo "  remove:  ./Scripts/uninstall-launch-agent.sh"
