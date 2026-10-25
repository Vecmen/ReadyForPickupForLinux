"""Secrets in the desktop keyring via libsecret's `secret-tool`.

Works with GNOME Keyring, KeePassXC or KWallet (any Secret Service provider).
On Arch: `pacman -S libsecret gnome-keyring` (or enable KeePassXC's Secret
Service integration). If no keyring is reachable, falls back to a 0600 file
in ~/.config/readyforpickup/secrets.json with a warning, which is NOT
encrypted, so the keyring is strongly preferred for Apple ID and card data.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

from rfp.config import CONFIG_DIR

SERVICE = "readyforpickup"
_FALLBACK = CONFIG_DIR / "secrets.json"
_warned = False


def _have_keyring() -> bool:
    return shutil.which("secret-tool") is not None and bool(os.environ.get("DBUS_SESSION_BUS_ADDRESS")
                                                             or os.path.exists(f"/run/user/{os.getuid()}/bus"))


def _warn_fallback() -> None:
    global _warned
    if not _warned:
        print("warning: no Secret Service keyring found (install libsecret + gnome-keyring or KeePassXC); "
              f"storing secrets unencrypted in {_FALLBACK}", file=sys.stderr)
        _warned = True


def _fallback_read() -> dict:
    try:
        return json.loads(_FALLBACK.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _fallback_write(d: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    fd = os.open(_FALLBACK, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(d, f)


def get(key: str) -> str | None:
    if _have_keyring():
        r = subprocess.run(["secret-tool", "lookup", "service", SERVICE, "key", key],
                           capture_output=True, text=True)
        if r.returncode == 0 and r.stdout:
            return r.stdout
        # Not in the keyring (exit 1): maybe stored by an earlier fallback.
        return _fallback_read().get(key) if _FALLBACK.exists() else None
    _warn_fallback()
    return _fallback_read().get(key)


def set(key: str, value: str) -> None:  # noqa: A001 - mirrors keyring API
    if _have_keyring():
        r = subprocess.run(["secret-tool", "store", "--label", f"ReadyForPickup {key}", "service", SERVICE, "key", key],
                           input=value, capture_output=True, text=True)
        if r.returncode == 0:
            return
        print(f"warning: keyring store failed ({r.stderr.strip()})", file=sys.stderr)
    _warn_fallback()
    d = _fallback_read()
    d[key] = value
    _fallback_write(d)


def delete(key: str) -> None:
    if _have_keyring():
        subprocess.run(["secret-tool", "clear", "service", SERVICE, "key", key], capture_output=True)
    if _FALLBACK.exists():
        d = _fallback_read()
        if d.pop(key, None) is not None:
            _fallback_write(d)


def get_json(key: str) -> dict | None:
    v = get(key)
    return json.loads(v) if v else None


def set_json(key: str, value: dict) -> None:
    set(key, json.dumps(value))
