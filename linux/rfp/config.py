"""Settings, saved searches and runtime state, stored under the XDG dirs.

~/.config/readyforpickup/config.json   settings + saved searches (no secrets)
~/.local/state/readyforpickup/state.json  dedupe keys, request log, backoff, orders
~/.local/share/readyforpickup/           browser profile and checkout screenshots
Secrets (Pushover keys, Apple ID, card) live in the system keyring: see secrets.py.
"""
from __future__ import annotations

import json
import os
import tempfile
import uuid
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path

from rfp import APP_NAME


def _xdg(var: str, default: str) -> Path:
    return Path(os.environ.get(var) or Path.home() / default) / APP_NAME


CONFIG_DIR = _xdg("XDG_CONFIG_HOME", ".config")
STATE_DIR = _xdg("XDG_STATE_HOME", ".local/state")
DATA_DIR = _xdg("XDG_DATA_HOME", ".local/share")
CONFIG_FILE = CONFIG_DIR / "config.json"
STATE_FILE = STATE_DIR / "state.json"
BROWSER_PROFILE = DATA_DIR / "browser-profile"
SCREENSHOT_DIR = DATA_DIR / "checkout-screenshots"

ALLOWED_INTERVALS = (2, 5, 10, 15, 30, 60)


@dataclass
class Search:
    """One saved search, as in the macOS app's SavedSearch."""
    product: str
    country: str = "US"
    store: str = "R032"
    store_name: str = ""
    include_nearby: bool = True
    preferred: list[str] = field(default_factory=list)
    only_preferred: bool = False
    notify_desktop: bool = True
    notify_pushover: bool = True
    custom_sku: str = ""
    custom_sku_nickname: str = ""
    paused: bool = False
    # Auto-order: buy the first newly available preferred model.
    auto_buy: bool = False
    auto_buy_nearby: bool = False   # also accept a nearby store, not just `store`
    max_price: float | None = None  # this search's cap on one order's total
    max_orders: int | None = 1      # orders this search may place before it pauses
    id: str = field(default_factory=lambda: uuid.uuid4().hex[:8])

    @property
    def custom(self) -> tuple[str, str] | None:
        sku = self.custom_sku.strip()
        return (sku, self.custom_sku_nickname.strip() or sku) if sku else None

    def is_preferred(self, sku: str) -> bool:
        return sku in self.preferred or (self.custom is not None and self.custom[0] == sku)

    @classmethod
    def from_dict(cls, d: dict) -> "Search":
        known = {f.name for f in fields(cls)}
        return cls(**{k: v for k, v in d.items() if k in known})


@dataclass
class AutoBuySettings:
    enabled: bool = False
    # False = walk checkout to the final review page, then alert you and wait
    # for you to press Place Order. True = press it automatically.
    place_order: bool = False
    headless: bool = False
    max_price: float | None = None      # abort if one order's total is higher
    max_orders: int | None = 1          # orders across all searches; None = no limit
    max_total_spend: float | None = None  # total of all orders' totals; None = no limit
    clear_bag: bool = True               # empty the bag first so only this item is bought
    handoff_minutes: int = 30            # keep the browser open this long for you on review/failure
    step_timeout_seconds: int = 45
    pickup_search_location: str = ""     # ZIP/city for the checkout store search; default: the store's
    # Default: /usr/bin/chromium, then Chrome/Brave. "bundled" = Playwright's own Chromium.
    browser_executable: str = ""
    session_check_hours: int = 12        # warn if the Apple sign-in has expired (0 = off)


@dataclass
class Settings:
    interval_minutes: int = 5
    desktop_notifications: bool = True
    pushover_enabled: bool = False
    pushover_high_priority: bool = False
    autobuy: AutoBuySettings = field(default_factory=AutoBuySettings)
    searches: list[Search] = field(default_factory=list)

    @classmethod
    def load(cls) -> "Settings":
        if not CONFIG_FILE.exists():
            return cls()
        raw = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        ab_known = {f.name for f in fields(AutoBuySettings)}
        s = cls(
            interval_minutes=raw.get("interval_minutes", 5),
            desktop_notifications=raw.get("desktop_notifications", True),
            pushover_enabled=raw.get("pushover_enabled", False),
            pushover_high_priority=raw.get("pushover_high_priority", False),
            autobuy=AutoBuySettings(**{k: v for k, v in raw.get("autobuy", {}).items() if k in ab_known}),
            searches=[Search.from_dict(x) for x in raw.get("searches", [])],
        )
        if s.interval_minutes not in ALLOWED_INTERVALS:
            s.interval_minutes = 5
        return s

    def save(self) -> None:
        _atomic_write(CONFIG_FILE, asdict(self))

    def search(self, ident: str) -> Search:
        for s in self.searches:
            if s.id == ident:
                return s
        raise KeyError(f"no search {ident!r}; `rfp search list` shows their ids")


class State:
    """Mutable runtime state that survives restarts."""

    def __init__(self, raw: dict | None = None):
        raw = raw or {}
        self.notified: dict[str, list[str]] = raw.get("notified", {})      # search id -> ["R032|SKU"]
        self.request_log: list[float] = raw.get("request_log", [])          # epoch seconds
        self.throttle_failures: int = raw.get("throttle_failures", 0)
        self.throttled_until: float = raw.get("throttled_until", 0.0)
        self.orders: list[dict] = raw.get("orders", [])
        self.autobuy_attempts: dict[str, list[str]] = raw.get("autobuy_attempts", {})
        self.last_session_check: float = raw.get("last_session_check", 0.0)
        self.limit_alerted: dict[str, str] = raw.get("limit_alerted", {})   # search id -> reason

    @classmethod
    def load(cls) -> "State":
        try:
            return cls(json.loads(STATE_FILE.read_text(encoding="utf-8")))
        except (FileNotFoundError, json.JSONDecodeError):
            return cls()

    def save(self) -> None:
        _atomic_write(STATE_FILE, self.__dict__)


def _atomic_write(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
