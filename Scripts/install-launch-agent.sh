#!/bin/bash
# Register ciStatus as a login item that starts with its tokens loaded.
#
# Launching from Finder or Spotlight cannot work: the app reads tokens from
# environment variables, and neither forwards the environment. A LaunchAgent
# with EnvironmentVariables set in its plist is the supported way to get them in,
# and it starts the app at login without anyone opening a terminal.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="CIStatus"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT="$AGENT_DIR/dev.dolivari.ciStatus.plist"
CONFIG_DIR="$HOME/Library/Application Support/$APP_NAME"
SECRETS="$CONFIG_DIR/secrets.env"
CONFIG="$CONFIG_DIR/config.json"

# Read source: name=env var name, matching the tokenEnv values in the config.
declare -a VARS=(GITHUB_API_KEY VERCEL_API_KEY SENTRY_API_KEY)

if [ ! -f "$CONFIG" ]; then
  echo "No config at $CONFIG"
  exit 1
fi

# Fail early if the config names an env var that is not in our list, so a typo
# does not silently produce an app that cannot authenticate.
missing=0
while read -r var; do
  found=0
  for known in "${VARS[@]}"; do
    [ "$var" = "$known" ] && found=1
  done
  if [ "$found" -eq 0 ]; then
    echo "warning: config references $var, which this script does not know about."
    echo "         Add it to VARS in $0 if you use it."
    missing=1
  fi
done < <(grep -o '"tokenEnv"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG" | sed 's/.*"\([^"]*\)"$/\1/')

if [ "$missing" -eq 1 ]; then
  echo
  read -r -p "Continue anyway? [y/N] " reply
  [[ "$reply" == [yY] ]] || exit 1
fi

echo "This writes your tokens to $SECRETS"
echo "It will be chmod 600, and is gitignored if this is a git repo."
echo
read -r -p "Write tokens to $SECRETS? [y/N] " reply
[[ "$reply" == [yY] ]] || { echo "Cancelled."; exit 0; }

mkdir -p "$CONFIG_DIR"
: > "$SECRETS"
for var in "${VARS[@]}"; do
  read -r -s -p "  $var (blank to skip): " value
  echo
  if [ -n "$value" ]; then
    printf 'export %s=%q\n' "$var" "$value" >> "$SECRETS"
  fi
done
chmod 600 "$SECRETS"

# Translate secrets.env into a plist dictionary, escaping for XML.
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  echo '<plist version="1.0">'
  echo '<dict>'
  echo '  <key>Label</key><string>dev.dolivari.ciStatus</string>'
  echo '  <key>ProgramArguments</key>'
  echo '  <array>'
  echo "    <string>/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME</string>"
  echo '  </array>'
  echo '  <key>EnvironmentVariables</key>'
  echo '  <dict>'
  # shellcheck disable=SC1090
  while IFS= read -r line; do
    [[ "$line" == export\ *=* ]] || continue
    key="${line#export }"; key="${key%%=*}"
    value="${line#*=}"
    printf '    <key>%s</key><string>%s</string>\n' "$key" \
      "$(printf '%s' "$value" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
  done < "$SECRETS"
  echo '  </dict>'
  echo '  <key>RunAtLoad</key><true/>'
  echo '  <key>KeepAlive</key><false/>'
  echo '  <key>ProcessType</key><string>Interactive</string>'
  echo '  <key>StandardOutPath</key><string>/tmp/cistatus.out.log</string>'
  echo '  <key>StandardErrorPath</key><string>/tmp/cistatus.err.log</string>'
  echo '</dict>'
  echo '</plist>'
} > "$AGENT"

mkdir -p "$AGENT_DIR"
# A stale copy would be merged rather than replaced, so remove it first.
launchctl bootout "gui/$(id -u)/dev.dolivari.ciStatus" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo
echo "Installed $AGENT"
echo "It will start at login, and the tokens stay out of your shell history."
echo
echo "  logs:    /tmp/cistatus.err.log"
echo "  stop:    launchctl bootout gui/$(id -u)/dev.dolivari.ciStatus"
echo "  remove:  ./Scripts/uninstall-launch-agent.sh"
