#!/usr/bin/env bash
# Remove everything install.sh created. The checkout itself is left alone.
set -uo pipefail
SERVICE="rog-deck.service"
systemctl --user disable --now "$SERVICE" 2>/dev/null || true
systemctl --user disable --now rog-deck-ripple.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/$SERVICE"
rm -f "$HOME/.config/systemd/user/rog-deck-ripple.service"
rm -f "$HOME/.local/bin/rog-deck" "$HOME/.local/bin/rog-deck-ripple"
rm -f "$HOME/.config/omarchy/plugins/rog-deck"
command -v omarchy >/dev/null && omarchy bar remove rog-deck >/dev/null 2>&1 || true
rm -f "$HOME/.local/share/applications/rog-deck.desktop"
systemctl --user daemon-reload
echo "ROG Deck removed. No hardware settings were changed."
