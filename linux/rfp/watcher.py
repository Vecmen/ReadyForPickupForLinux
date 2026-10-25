"""Refresh loop: request budget, throttle backoff, dedupe, alerts, auto-order.

Apple's pickup API blocks a network for up to ~30 minutes after about 31
requests in 94 minutes from the app (Scripts/probe-throttle.py), so every
request goes through a sliding-window budget of 30 per 94 minutes, and a
throttled sweep backs off exponentially (interval x 2^n, max 1 hour), as in
the macOS app's ViewModel.registerThrottle.
"""
from __future__ import annotations

import logging
import math
import time

from rfp import data, inventory, limits, notify
from rfp.config import CONFIG_FILE, Search, Settings, State

log = logging.getLogger("rfp")

BUDGET_REQUESTS = 30
BUDGET_WINDOW = 94 * 60


class RequestBudget:
    def __init__(self, state: State, clock=time.time, sleep=time.sleep):
        self.state, self.clock, self.sleep = state, clock, sleep

    def _prune(self) -> None:
        cutoff = self.clock() - BUDGET_WINDOW
        self.state.request_log = [t for t in self.state.request_log if t > cutoff]

    def wait_seconds(self) -> float:
        self._prune()
        if len(self.state.request_log) < BUDGET_REQUESTS:
            return 0.0
        return self.state.request_log[0] + BUDGET_WINDOW - self.clock()

    def acquire(self) -> None:
        if (w := self.wait_seconds()) > 0:
            log.info("request budget used up (%d in %d min); waiting %d s", BUDGET_REQUESTS,
                     BUDGET_WINDOW // 60, w)
            self.sleep(w)
            self._prune()
        self.state.request_log.append(self.clock())
        self.state.save()


def min_interval_minutes(settings: Settings) -> int:
    """Shortest interval that keeps every sweep inside the request budget."""
    per_sweep = sum(inventory.request_count(s) for s in settings.searches if not s.paused)
    return max(1, math.ceil(BUDGET_WINDOW / 60 * per_sweep / BUDGET_REQUESTS)) if per_sweep else 1


def _key(store: inventory.StoreResult, part: inventory.Part) -> str:
    return f"{store.store_number}|{part.sku}"


def _counts(search: Search, sku: str) -> bool:
    """Models that alert: the preferred ones (and custom SKU); all of them if none are set."""
    if not search.preferred and not search.custom:
        return True
    return search.is_preferred(sku)


class Watcher:
    def __init__(self, settings: Settings, state: State, fetch=inventory.http_get, autobuyer=None,
                 session_checker=None):
        self.settings, self.state, self.fetch = settings, state, fetch
        self.budget = RequestBudget(state)
        # callable(search, store, part, settings, max_price) -> autobuy.Result
        self.autobuyer = autobuyer
        self.session_checker = session_checker  # callable(settings, country_code) -> bool

    # ---- one sweep -------------------------------------------------------
    def sweep(self) -> dict[str, list]:
        results: dict[str, list] = {}
        for search in [s for s in self.settings.searches if not s.paused]:
            try:
                found = inventory.fetch_inventory(search, self.fetch, on_request=self.budget.acquire)
            except inventory.Throttled as e:
                self._register_throttle(e.status)
                return results      # a throttled response ends the sweep
            except (inventory.InventoryError, KeyError) as e:
                log.error("[%s] %s", search.id, e)
                continue
            results[search.id] = found
            self._report(search, found)
            self._handle_new(search, found)
        self.state.throttle_failures = 0
        self.state.throttled_until = 0.0
        self.state.save()
        return results

    def _register_throttle(self, status: int) -> None:
        self.state.throttle_failures += 1
        base = max(self.settings.interval_minutes, 5) * 60
        backoff = min(3600, base * 2 ** min(self.state.throttle_failures, 4))
        self.state.throttled_until = time.time() + backoff
        self.state.save()
        log.warning("Apple is throttling requests (HTTP %d); backing off %d min", status, math.ceil(backoff / 60))

    def _report(self, search: Search, found) -> None:
        label = f"{data.PRODUCT_NAMES.get(search.product, search.product)} @ {search.store_name or search.store}"
        if not found:
            log.info("[%s] %s: nothing available", search.id, label)
        for store, parts in found:
            log.info("[%s] %s (%s): %s", search.id, store.store_name, store.location,
                     ", ".join(("★ " if search.is_preferred(p.sku) else "") + p.name for p in parts))

    # ---- dedupe, alerts, auto-order ------------------------------------
    def _handle_new(self, search: Search, found) -> None:
        current = {_key(st, p) for st, ps in found for p in ps if _counts(search, p.sku)}
        previous = set(self.state.notified.get(search.id, []))
        new = current - previous
        self.state.notified[search.id] = sorted(current)
        self.state.save()
        if not new:
            return
        fresh = [(st, [p for p in ps if _key(st, p) in new]) for st, ps in found]
        fresh = [(st, ps) for st, ps in fresh if ps]
        self._alert(search, fresh)
        if search.auto_buy and self.settings.autobuy.enabled and self.autobuyer:
            self._auto_buy(search, fresh)

    def _alert(self, search: Search, fresh) -> None:
        c = data.country(search.country)
        product = data.PRODUCT_NAMES.get(search.product, search.product)
        lines = [f"{p.name} — {st.store_name}" for st, ps in fresh for p in ps]
        title = f"{product} ready for pickup"
        body = "\n".join(lines[:8]) + (f"\n+{len(lines) - 8} more" if len(lines) > 8 else "")
        first = fresh[0][1][0]
        url = c.product_page_url(first.sku)
        if search.notify_desktop and self.settings.desktop_notifications:
            notify.desktop(title, f"{body}\n{url}", urgent=True)
        if search.notify_pushover and self.settings.pushover_enabled and notify.pushover_configured():
            try:
                notify.pushover(title, body, url, f"View {first.name} at Apple", self.settings.pushover_high_priority)
            except Exception as e:  # never let an alert failure stop the loop
                log.error("Pushover send failed: %s", e)

    def _auto_buy(self, search: Search, fresh) -> None:
        if not search.preferred and not search.custom:
            log.warning("[%s] auto-buy skipped: set preferred models first so it can't buy the wrong one", search.id)
            return
        decision = limits.check(self.settings, self.state, search)
        if not decision.allowed:
            log.warning("[%s] auto-buy skipped: %s", search.id, decision.reason)
            if self.state.limit_alerted.get(search.id) != decision.reason:   # tell you once, not every sweep
                self.state.limit_alerted[search.id] = decision.reason
                self.state.save()
                self._notify("Auto-buy limit reached", f"Not ordering: {decision.reason}. "
                             "Raise it with `rfp limits set` if you want more.")
            return
        self.state.limit_alerted.pop(search.id, None)
        priority = list(search.preferred) + ([search.custom[0]] if search.custom else [])
        candidates = []
        for st, ps in fresh:
            if st.store_number != search.store and not search.auto_buy_nearby:
                continue
            for p in ps:
                if search.is_preferred(p.sku):
                    candidates.append((priority.index(p.sku), st.store_number != search.store, st, p))
        if not candidates:
            return
        _, _, store, part = min(candidates, key=lambda c: (c[0], c[1]))
        cap = "no price limit" if decision.cap is None else f"max {decision.cap:,.2f}"
        log.info("[%s] auto-buy: %s at %s (%s)", search.id, part.name, store.store_name, cap)
        result = self.autobuyer(search, store, part, self.settings, decision.cap)
        self.state.autobuy_attempts.setdefault(search.id, []).append(
            f"{time.strftime('%Y-%m-%d %H:%M')} {part.sku}@{store.store_number}: {result.status}")
        if result.status == "placed":
            record_order(self.state, search, part.sku, store.store_number, result)
            if limits.search_done(self.state, search):
                self._pause(search.id)
        self.state.save()

    def _pause(self, search_id: str) -> None:
        """Pause a search in the saved config without losing edits made meanwhile."""
        fresh = Settings.load()
        for s in fresh.searches:
            if s.id == search_id:
                s.paused = True
        fresh.save()
        self.settings = fresh
        self._config_mtime = _mtime()

    def _notify(self, title: str, body: str) -> None:
        if self.settings.desktop_notifications:
            notify.desktop(title, body, urgent=True)
        if self.settings.pushover_enabled and notify.pushover_configured():
            try:
                notify.pushover(title, body, high_priority=self.settings.pushover_high_priority)
            except Exception as e:
                log.error("Pushover send failed: %s", e)

    # ---- loop -----------------------------------------------------------
    _config_mtime = 0.0

    def _reload_if_changed(self) -> bool:
        """Pick up `rfp search ...` / `rfp config set` edits without a restart."""
        m = _mtime()
        if m and m != self._config_mtime:
            if self._config_mtime:
                self.settings = Settings.load()
                log.info("config changed; reloaded (%d active search(es))",
                         sum(not s.paused for s in self.settings.searches))
            self._config_mtime = m
            return True
        return False

    def _check_session(self) -> None:
        ab = self.settings.autobuy
        armed = [s for s in self.settings.searches if s.auto_buy and not s.paused]
        if not (ab.enabled and armed and ab.session_check_hours and self.session_checker):
            return
        if time.time() - self.state.last_session_check < ab.session_check_hours * 3600:
            return
        self.state.last_session_check = time.time()
        self.state.save()
        try:
            ok = self.session_checker(self.settings, armed[0].country)
        except Exception as e:   # browser busy or missing: try again next time
            log.warning("couldn't check the Apple sign-in: %s", e)
            return
        if ok:
            log.info("Apple sign-in still valid")
        else:
            log.warning("Apple sign-in has expired")
            self._notify("Apple sign-in expired",
                         "Auto-buy can't check out until you sign in again: run `rfp account login`.")

    def run_forever(self) -> None:
        idle_logged = False
        interval = self.settings.interval_minutes
        while True:
            if self._reload_if_changed() or not idle_logged:
                floor = min_interval_minutes(self.settings)
                interval = max(self.settings.interval_minutes, floor)
                if interval > self.settings.interval_minutes:
                    log.warning("interval raised from %d to %d min to stay inside Apple's request budget",
                                self.settings.interval_minutes, interval)
            active = sum(not s.paused for s in self.settings.searches)
            if not active:
                if not idle_logged:
                    log.info("no active searches; waiting for one (`rfp search add` or `rfp search resume`)")
                    idle_logged = True
                time.sleep(30)
                continue
            if idle_logged:
                log.info("watching %d search(es) every %d min", active, interval)
                idle_logged = False
            if (wait := self.state.throttled_until - time.time()) > 0:
                log.info("throttled; next try in %d s", wait)
                time.sleep(wait)
            self._check_session()
            started = time.time()
            self.sweep()
            # Sleep in short steps so config edits take effect promptly.
            end = started + max(10, interval * 60)
            while time.time() < end:
                time.sleep(min(30, max(0, end - time.time())))
                if self._reload_if_changed():
                    break


def _mtime() -> float:
    try:
        return CONFIG_FILE.stat().st_mtime
    except FileNotFoundError:
        return 0.0


def record_order(state: State, search: Search, sku: str, store: str, result) -> None:
    state.orders.append({"search": search.id, "sku": sku, "store": store, "order": result.order_number,
                         "total": getattr(result, "total", None), "at": time.time()})
