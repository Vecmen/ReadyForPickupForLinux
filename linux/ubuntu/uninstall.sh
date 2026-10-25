#!/usr/bin/env bash
# Remove ReadyForPickup installed by install.sh.
#   ./uninstall.sh           keep your searches, settings, order history and sign-in
#   ./uninstall.sh --purge   also delete those and the saved secrets
set -euo pipefail
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/readyforpickup"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/readyforpickup"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/readyforpickup"
UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/readyforpickup.service"

systemctl --user disable --now readyforpickup.service 2>/dev/null || true
if [ "${1:-}" = "--purge" ] && [ -x "$HOME/.local/bin/rfp" ]; then
  "$HOME/.local/bin/rfp" account forget --session >/dev/null 2>&1 || true
  rm -rf "$CONF_DIR" "$STATE_DIR"
fi
rm -f "$UNIT" "$HOME/.local/bin/rfp"
if [ "${1:-}" = "--purge" ]; then
  rm -rf "$APP_DIR"
else
  rm -rf "$APP_DIR/venv"
fi
systemctl --user daemon-reload 2>/dev/null || true
echo "ReadyForPickup removed${1:+ ($1)}."
