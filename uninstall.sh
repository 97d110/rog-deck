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
python3 - <<'PYEOF' 2>/dev/null || true
import json, os
path = os.path.expanduser("~/.config/omarchy/shell.json")
try:
    data = json.load(open(path))
except Exception:
    raise SystemExit
layout = data.get("bar", {}).get("layout", {})
changed = False
for section in layout:
    kept = [w for w in layout[section] if w.get("id") != "rog-deck"]
    if len(kept) != len(layout[section]):
        layout[section] = kept
        changed = True
if changed:
    json.dump(data, open(path, "w"), indent=2)
PYEOF
rm -f "$HOME/.local/share/applications/rog-deck.desktop"
systemctl --user daemon-reload
echo "ROG Deck removed. No hardware settings were changed."
