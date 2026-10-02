#!/bin/bash
# Remove the ciStatus login item, and optionally its stored tokens.
#
# Tokens are left alone unless --tokens is passed: removing the login item
# should not silently destroy credentials the app may still need when launched
# by hand.
set -euo pipefail

LABEL="dev.dolivari.ciStatus"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
TOKENS="$HOME/Library/Application Support/CIStatus/tokens.json"
# Left from the era before tokens.json, when tokens were written to a shell file.
LEGACY_SECRETS="$HOME/Library/Application Support/CIStatus/secrets.env"

pkill -x CIStatus 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

if [ -f "$AGENT" ]; then
  rm -f "$AGENT"
  echo "Removed $AGENT"
fi

if [ -f "$LEGACY_SECRETS" ]; then
  echo "Also removing the old plaintext token file at $LEGACY_SECRETS"
  rm -f "$LEGACY_SECRETS"
fi

if [ "${1:-}" = "--tokens" ]; then
  if [ -f "$TOKENS" ]; then
    rm -f "$TOKENS"
    echo "Removed $TOKENS"
    echo "Those tokens were on disk in the clear, so rotate them if the machine is shared."
  fi
else
  echo "Tokens were left at $TOKENS. Remove them with:"
  echo "  ./Scripts/uninstall-launch-agent.sh --tokens"
fi

echo "Done. The app in /Applications was left alone; remove it with: make uninstall"
