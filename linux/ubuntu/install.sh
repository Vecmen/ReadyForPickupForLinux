#!/usr/bin/env bash
# Install ReadyForPickup on Ubuntu (22.04 or later) with a GNOME desktop.
# Run as your normal desktop user, not root; it uses sudo for apt.
#
#   ./install.sh                 interactive
#   ./install.sh --no-autobuy    alerts only (skips Playwright and Chromium)
#   ./install.sh --yes           accept the defaults without asking
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # the linux/ folder
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/readyforpickup"
VENV="$APP_DIR/venv"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
AUTOBUY=1
ASSUME_YES=0
BROWSER_FAILED=0
for arg in "$@"; do
  case "$arg" in
    --no-autobuy) AUTOBUY=0 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ask() {  # ask "question" default(y/n)
  local def="$2" reply
  if [ "$ASSUME_YES" = 1 ]; then [ "$def" = y ]; return; fi
  read -r -p "$1 [$( [ "$def" = y ] && echo Y/n || echo y/N )] " reply || true
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy] ]]
}

[ "$(id -u)" -ne 0 ] || { echo "Run this as your normal user (it calls sudo when needed), not as root." >&2; exit 1; }
command -v apt-get >/dev/null || { echo "This installer is for Ubuntu/Debian (apt)." >&2; exit 1; }
[ -f "$SRC/rfp/data/ProductCatalog.json" ] || {
  echo "Can't find the product catalog. Run this from inside the full ReadyForPickup folder" \
       "(it needs ../ReadyForPickup/*.json next to linux/)." >&2; exit 1; }

say "Installing system packages (sudo)"
sudo apt-get update -q
sudo apt-get install -y -q python3 python3-venv python3-pip libnotify-bin libsecret-tools gnome-keyring

PY_OK=$(python3 -c 'import sys; print(int(sys.version_info >= (3, 10)))')
[ "$PY_OK" = 1 ] || { echo "Python 3.10 or later is required (Ubuntu 22.04+)." >&2; exit 1; }

say "Creating the app environment in $VENV"
mkdir -p "$APP_DIR"
python3 -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip
if [ "$AUTOBUY" = 1 ]; then
  "$VENV/bin/pip" install -q "$SRC[autobuy]"
else
  "$VENV/bin/pip" install -q "$SRC"
fi

if [ "$AUTOBUY" = 1 ]; then
  say "Installing Chromium for auto-order (Playwright's build; sudo for its libraries)"
  # Ubuntu's own chromium is a snap that can't use a profile outside ~/snap,
  # so auto-order uses Playwright's Chromium instead.
  sudo "$VENV/bin/python" -m playwright install-deps chromium
  if ! "$VENV/bin/python" -m playwright install chromium; then
    BROWSER_FAILED=1
    echo "WARNING: couldn't download Chromium. Alerts will work; for auto-order, rerun later:" >&2
    echo "  $VENV/bin/python -m playwright install chromium" >&2
  fi
fi

SECRETS_LINE=""
say "Secrets (Pushover keys, Apple ID, card)"
echo "With automatic login, GNOME doesn't unlock your keyring, so secrets can't be read"
echo "until someone types your password. In that case they can go in a file only your"
echo "user can read (not encrypted)."
if ask "Does this VM log in to the desktop automatically?" n; then
  SECRETS_LINE="RFP_SECRETS=file"
  echo "Secrets will be kept in ~/.config/readyforpickup/secrets.json (mode 600)."
else
  echo "Secrets will be kept in the GNOME keyring."
fi

say "Installing the rfp command in $BIN_DIR"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/rfp" <<EOF
#!/bin/sh
# ReadyForPickup launcher (written by install.sh)
${SECRETS_LINE:+export $SECRETS_LINE}
exec "$VENV/bin/rfp" "\$@"
EOF
chmod 755 "$BIN_DIR/rfp"

if [ "$AUTOBUY" = 1 ]; then
  "$BIN_DIR/rfp" config set autobuy.browser_executable bundled >/dev/null
fi

say "Installing the background service"
mkdir -p "$UNIT_DIR"
sed -e "s|@RFP@|$BIN_DIR/rfp|" "$SRC/ubuntu/readyforpickup.service" > "$UNIT_DIR/readyforpickup.service"
systemctl --user daemon-reload 2>/dev/null || echo "(systemd --user isn't running here; enable the service after you log in)"

if ask "Stop this VM from locking the screen, blanking it, or suspending? (recommended: it keeps running unattended)" y; then
  gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
  gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null || true
fi

if ask "Start the service now and at every login?" y; then
  systemctl --user enable --now readyforpickup.service 2>/dev/null \
    && echo "Running. Follow it with: journalctl --user -u readyforpickup -f" \
    || echo "Couldn't start it from here; after logging in run: systemctl --user enable --now readyforpickup"
fi

say "Done"
[ "$BROWSER_FAILED" = 0 ] || echo "Remember: Chromium didn't download, so auto-order won't run until you rerun:
  $VENV/bin/python -m playwright install chromium"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Open a new terminal (or log out and in) so 'rfp' is on your PATH, or run $BIN_DIR/rfp." ;;
esac
cat <<'EOF'
Next steps:
  rfp stores --find <city or ZIP>                    find your store id
  rfp products iPhonePro18                           model part numbers
  rfp search add -p iPhonePro18 -s R230 --prefer MJQ34LL/A
  rfp pushover set                                   phone alerts
  rfp account login                                  sign in to Apple (auto-order)
  rfp limits set --orders 1 --spend 1500 --price 1300
  rfp buy --search <id> --dry-run                    practice checkout
The service picks up changes by itself; no restart needed.
EOF
