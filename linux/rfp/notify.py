"""Desktop notifications (libnotify's notify-send) and Pushover."""
from __future__ import annotations

import json
import logging
import shutil
import subprocess
import urllib.parse
import urllib.request

from rfp import secrets

log = logging.getLogger("rfp")
PUSHOVER_URL = "https://api.pushover.net/1/messages.json"


def desktop(title: str, body: str, urgent: bool = False) -> None:
    if not shutil.which("notify-send"):
        log.info("notify-send not installed (pacman -S libnotify); %s: %s", title, body)
        return
    cmd = ["notify-send", "-a", "ReadyForPickup", "-i", "dialog-information"]
    if urgent:
        cmd += ["-u", "critical"]
    try:
        subprocess.run(cmd + [title, body], timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired) as e:
        log.warning("desktop notification failed: %s", e)


def pushover_configured() -> bool:
    return bool(secrets.get("pushover_token")) and bool(secrets.get("pushover_user"))


def pushover(title: str, message: str, url: str | None = None, url_title: str | None = None,
             high_priority: bool = False) -> None:
    """One attempt, never a retry loop (as in the macOS app). Raises on failure."""
    fields = {
        "token": (secrets.get("pushover_token") or "").strip(),
        "user": (secrets.get("pushover_user") or "").strip(),
        "title": title[:250],
        "message": message[:1024],
        "priority": "1" if high_priority else "0",
    }
    if url:
        fields["url"] = url
        if url_title:
            fields["url_title"] = url_title[:100]
    req = urllib.request.Request(PUSHOVER_URL, data=urllib.parse.urlencode(fields).encode(),
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        payload = json.loads(resp.read() or b"{}")
    if payload.get("status") != 1:
        raise RuntimeError(f"Pushover rejected the message: {payload.get('errors')}")
