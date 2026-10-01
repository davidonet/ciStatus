#!/bin/bash
# Remove the ciStatus login item and its stored tokens.
set -euo pipefail

LABEL="dev.dolivari.ciStatus"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
SECRETS="$HOME/Library/Application Support/CIStatus/secrets.env"

pkill -x CIStatus 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

[ -f "$AGENT" ] && rm -f "$AGENT" && echo "Removed $AGENT"

if [ -f "$SECRETS" ]; then
  echo "Also removing the stored tokens at $SECRETS"
  rm -f "$SECRETS"
  echo "Since these were written to disk in plain text, rotate them."
fi

echo "Done. The app in /Applications was left alone; remove it with: make uninstall"
