#!/usr/bin/env bash
# Remove everything install.sh created. The checkout itself is left alone.
set -uo pipefail
SERVICE="rog-deck.service"
systemctl --user disable --now "$SERVICE" 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/$SERVICE"
rm -f "$HOME/.local/bin/rog-deck"
rm -f "$HOME/.local/share/applications/rog-deck.desktop"
systemctl --user daemon-reload
echo "ROG Deck removed. No hardware settings were changed."
