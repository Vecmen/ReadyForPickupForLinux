"""Auto-order: put the item in your Apple Store bag and check out for pickup.

How it works
  * A persistent Chromium profile (~/.local/share/readyforpickup/browser-profile)
    holds your apple.com sign-in. You sign in once with `rfp account login`,
    in a normal browser window, so two-factor and "Trust this browser" work.
  * If that session has expired when an item appears, it re-signs in with the
    Apple ID saved in your keyring (`rfp account set-credentials`), and if
    Apple asks for a 2FA code it alerts you and waits for you to type it.
  * Payment: the card saved in your keyring (`rfp account set-card`) is typed
    into Apple's card fields only if they are empty.
  * Safety: the bag is emptied first and must hold exactly one item, quantity
    1; the total is checked against `max_price`; nothing is submitted on the
    final page unless `autobuy.place_order` is true (otherwise it stops there,
    alerts you, and you press Place Order yourself); a search that orders is
    paused so it can never order twice. Any step it can't complete hands the
    open browser to you mid-checkout instead of losing the item.

Apple's checkout pages change without notice. Every selector lives in
checkout_selectors.json and can be overridden; run `rfp buy --dry-run` before
relying on this, and again after Apple redesigns the store.
"""
from __future__ import annotations

import json
import logging
import re
import shutil
import time
from dataclasses import dataclass
from pathlib import Path

from rfp import data, notify, secrets
from rfp.config import BROWSER_PROFILE, CONFIG_DIR, SCREENSHOT_DIR, Search, Settings

log = logging.getLogger("rfp")

DEFAULT_SELECTORS = Path(__file__).with_name("checkout_selectors.json")
USER_SELECTORS = CONFIG_DIR / "checkout_selectors.json"
BROWSER_CANDIDATES = ("/usr/bin/chromium", "/usr/bin/google-chrome-stable", "/usr/bin/google-chrome",
                      "/usr/bin/brave", "/opt/google/chrome/chrome")


@dataclass
class Result:
    status: str               # placed | review_ready | handed_off | failed | dry_run
    order_number: str | None = None
    detail: str = ""
    total: float | None = None
    screenshots: str = ""


class StepError(Exception):
    pass


def load_selectors() -> dict:
    sel = json.loads(DEFAULT_SELECTORS.read_text(encoding="utf-8"))
    if USER_SELECTORS.exists():
        sel.update(json.loads(USER_SELECTORS.read_text(encoding="utf-8")))
    return sel


def parse_total(text: str) -> float | None:
    """The order total from page text: the amount after the last 'Total'."""
    matches = re.findall(r"\btotal\b[^0-9]{0,40}?([0-9]{1,3}(?:[.,\s'][0-9]{3})*(?:[.,][0-9]{2})?)",
                         text, flags=re.I)
    if not matches:
        return None
    raw = matches[-1].replace(" ", "").replace("'", "")
    if re.search(r",\d{2}$", raw):            # 1.299,00 (EU)
        raw = raw.replace(".", "").replace(",", ".")
    else:                                     # 1,299.00 (US/UK)
        raw = raw.replace(",", "")
    try:
        return float(raw)
    except ValueError:
        return None


def find_browser(configured: str = "") -> str | None:
    """None means Playwright's bundled Chromium."""
    if configured == "bundled":
        return None
    if configured:
        return configured
    return next((p for p in BROWSER_CANDIDATES if Path(p).exists()), None)


def _require_playwright():
    try:
        from playwright.sync_api import sync_playwright  # noqa: F401
    except ImportError as e:
        raise SystemExit("auto-order needs Playwright: `pacman -S python-playwright` from the AUR "
                         "(e.g. `yay -S python-playwright`) or `pipx inject readyforpickup playwright`, "
                         "plus a browser: `pacman -S chromium`") from e


def open_context(pw, settings: Settings, headless: bool | None = None):
    BROWSER_PROFILE.mkdir(parents=True, exist_ok=True)
    kwargs = dict(headless=settings.autobuy.headless if headless is None else headless,
                  viewport={"width": 1280, "height": 900}, locale="en-US",
                  args=["--disable-blink-features=AutomationControlled",
                        # Keep working while the window is covered or the screen is
                        # locked (a VM left running): Chromium otherwise pauses
                        # hidden windows' timers and rendering.
                        "--disable-backgrounding-occluded-windows",
                        "--disable-renderer-backgrounding",
                        "--disable-background-timer-throttling"])
    exe = find_browser(settings.autobuy.browser_executable)
    if exe:
        kwargs["executable_path"] = exe
    return pw.chromium.launch_persistent_context(str(BROWSER_PROFILE), **kwargs)


class CheckoutFlow:
    MAX_STAGE_VISITS = 4

    def __init__(self, page, country: data.Country, store_number: str, store_name: str, sku: str,
                 settings: Settings, dry_run: bool, selectors: dict | None = None, shots: Path | None = None,
                 item_name: str = "", max_price: float | None = None):
        self.page, self.c = page, country
        # The most this order may cost: the limits module passes the tightest
        # of your caps and the budget left; on its own, autobuy.max_price.
        self.cap = max_price if max_price is not None else settings.autobuy.max_price
        self.item_name = item_name or sku
        self.store_number, self.store_name, self.sku = store_number, store_name, sku
        self.settings, self.ab, self.dry_run = settings, settings.autobuy, dry_run
        self.sel = selectors or load_selectors()
        self.shots = shots
        self._shot_n = 0
        self.total: float | None = None

    # ---- locator helpers ----------------------------------------------
    def _fmt(self, s: str) -> str:
        return (s.replace("{sku}", self.sku).replace("{store_number}", self.store_number)
                 .replace("{store_name}", re.escape(self.store_name) if s.startswith("text=/") else self.store_name))

    def _find(self, key: str, scope=None):
        scope = scope or self.page
        for raw in self.sel.get(key, []):
            try:
                loc = scope.locator(self._fmt(raw)).first
                if loc.count() and loc.is_visible():
                    return loc
            except Exception:  # bad selector for this page/frame: try the next one
                continue
        return None

    def _wait(self, key: str, timeout: float | None = None, scope=None):
        end = time.time() + (self.ab.step_timeout_seconds if timeout is None else timeout)
        while True:
            if (loc := self._find(key, scope)) is not None:
                return loc
            if time.time() >= end:
                return None
            self.page.wait_for_timeout(250)

    def _click(self, key: str, timeout: float | None = None, required: bool = True) -> bool:
        loc = self._wait(key, timeout)
        if loc is None:
            if required:
                raise StepError(f"couldn't find {key!r} on {self.page.url}")
            return False
        loc.scroll_into_view_if_needed(timeout=5000)
        loc.click(timeout=10000)
        return True

    def _settle(self) -> None:
        try:
            self.page.wait_for_load_state("networkidle", timeout=15000)
        except Exception:
            pass
        self.page.wait_for_timeout(600)

    def shot(self, name: str) -> None:
        if not self.shots:
            return
        self._shot_n += 1
        try:
            self.page.screenshot(path=str(self.shots / f"{self._shot_n:02d}-{name}.png"), full_page=True)
        except Exception as e:
            log.debug("screenshot failed: %s", e)

    # ---- stage detection ----------------------------------------------
    def stage(self) -> str:
        url = self.page.url.lower()
        for name, pat in self.sel["stage_url_patterns"].items():
            if re.search(pat, url, re.I):
                return name
        try:
            heading = " ".join(self.page.locator("h1, h2").all_inner_texts()[:4])
        except Exception:
            heading = ""
        for name, pat in self.sel["stage_heading_patterns"].items():
            if re.search(pat, heading, re.I):
                return name
        return "unknown"

    def _safe_continue(self) -> None:
        """Continue, but never on the final page: that button places the order."""
        if self.stage() in ("review", "thankyou"):
            return
        loc = self._wait("continue")
        if loc is None:
            raise StepError(f"no Continue button on {self.page.url}")
        label = (loc.inner_text(timeout=2000) or "").strip()
        if re.search(r"place.*order", label, re.I):
            return   # this is the order button; the review stage handles it
        loc.click(timeout=10000)
        self._settle()

    # ---- sign-in --------------------------------------------------------
    def signed_in(self) -> bool:
        self.page.goto(self.c.url("shop/account/home"), wait_until="domcontentloaded")
        self._settle()
        return not re.search(self.sel["stage_url_patterns"]["signin"], self.page.url, re.I)

    def sign_in(self) -> None:
        """Fill the Apple ID widget from the keyring, then wait for 2FA if asked."""
        creds = secrets.get_json("apple_id")
        frame = None
        for fsel in self.sel["apple_id_frame"]:
            if self.page.locator(fsel).count():
                frame = self.page.frame_locator(fsel)
                break
        if frame is None:
            self._click("checkout_signin_button", timeout=5, required=False)
            for fsel in self.sel["apple_id_frame"]:
                if self.page.locator(fsel).count():
                    frame = self.page.frame_locator(fsel)
        scope = frame or self.page
        if creds:
            if (email := self._wait("apple_id_email", 15, scope)) is not None:
                email.fill(creds["email"])
                # Apple's widget asks for the email first, then shows the
                # password; a one-page form has both from the start.
                if self._find("apple_id_password", scope) is None:
                    email.press("Enter")
            if (pw := self._wait("apple_id_password", 15, scope)) is not None:
                pw.fill(creds["password"])
                pw.press("Enter")
        self.page.wait_for_timeout(3000)
        needs_user = not creds or (self.stage() == "signin" and self._needs_2fa(scope))
        if needs_user:
            if self.ab.headless:
                raise StepError("Apple wants you to sign in / enter a 2FA code; run `rfp account login` "
                                "or set autobuy.headless to false")
            msg = ("Enter your Apple ID 2FA code in the ReadyForPickup browser window"
                   if creds else "Sign in to your Apple account in the ReadyForPickup browser window")
            self._desktop("ReadyForPickup needs you", msg)
            self._pushover("ReadyForPickup needs you", msg)
        # Wait for Apple (or, for 2FA, the user) to finish signing in.
        wait = self.ab.handoff_minutes * 60 if needs_user else 0
        end = time.time() + max(wait, self.ab.step_timeout_seconds)
        while time.time() < end:
            if (t := self._find("apple_id_trust", scope)) is not None:
                t.click()
            if self.stage() != "signin":
                self._settle()
                return
            self.page.wait_for_timeout(1000)
        raise StepError("sign-in didn't finish in time")

    def _needs_2fa(self, scope) -> bool:
        try:
            txt = scope.locator("body").inner_text(timeout=3000)
        except Exception:
            return False
        return bool(re.search(self.sel["apple_id_2fa_text"], txt, re.I))

    # ---- bag ------------------------------------------------------------
    def clear_bag(self) -> None:
        self.page.goto(self.c.url("shop/bag"), wait_until="domcontentloaded")
        self._settle()
        for _ in range(20):
            if not self._click("bag_remove_item", timeout=2, required=False):
                break
            self._settle()

    def add_to_bag(self) -> None:
        self.page.goto(self.c.product_page_url(self.sku), wait_until="domcontentloaded")
        self._settle()
        self.shot("product")
        clicked: set[str] = set()
        for _ in range(12):   # walk the buy page's option steps (trade-in, payment, carrier, AppleCare)
            add = self._find("add_to_bag")
            if add is not None and add.is_enabled():
                add.click()
                self._settle()
                self._click("added_to_bag_proceed", timeout=6, required=False)
                return
            progressed = False
            for raw in self.sel["buy_page_choices"]:
                if raw in clicked:
                    continue
                try:
                    loc = self.page.locator(raw).first
                    if loc.count() and loc.is_visible() and loc.is_enabled():
                        loc.click(timeout=5000)
                        clicked.add(raw)
                        progressed = True
                        self.page.wait_for_timeout(700)
                except Exception:
                    continue
            if not progressed and not self._click("buy_page_continue", timeout=2, required=False):
                self.page.wait_for_timeout(1000)
        raise StepError("couldn't add the item to the bag (no enabled Add to Bag button)")

    def verify_bag(self) -> None:
        self.page.goto(self.c.url("shop/bag"), wait_until="domcontentloaded")
        self._settle()
        self.shot("bag")
        items = 0
        for raw in self.sel["bag_remove_item"]:
            try:
                items = max(items, self.page.locator(raw).count())
            except Exception:
                pass
        if items != 1:
            raise StepError(f"bag should hold exactly 1 item, has {items}")
        if (q := self._find("bag_quantity")) is not None and q.input_value() != "1":
            q.select_option("1")
            self._settle()
        body = self.page.locator("body").inner_text()
        caps = re.findall(r"\d+\s?[GT]B", self.item_name)
        if caps and not any(re.search(cap.replace(" ", r"\s?"), body, re.I) for cap in caps):
            log.warning("bag item may not match %s (no %s on the bag page)", self.item_name, "/".join(caps))

    # ---- checkout stages ------------------------------------------------
    def do_fulfillment(self) -> None:
        self._click("pickup_option", timeout=10, required=False)
        self._settle()
        store = self._find("store_radio")
        if store is None:
            self._click("store_search_link", timeout=3, required=False)
            if (inp := self._wait("store_search_input", 10)) is not None:
                loc = self.ab.pickup_search_location or self._store_location()
                inp.fill(loc)
                inp.press("Enter")
                self._settle()
            store = self._wait("store_radio", 15)
        if store is None:
            raise StepError(f"store {self.store_name} ({self.store_number}) isn't offered for pickup now")
        store.click()
        self._settle()
        if (d := self._find("pickup_date_button")) is not None:
            d.click()
            self._settle()
        if (ts := self._find("pickup_timeslot_select")) is not None:
            options = ts.locator("option").all()
            values = [o.get_attribute("value") for o in options]
            values = [v for v in values if v]
            if values:
                ts.select_option(values[0])
                self._settle()
        self.shot("fulfillment")
        self._safe_continue()

    def _store_location(self) -> str:
        s = data.find_store(self.c.code, self.store_number)
        return s.pickup_location if s else self.store_name

    def do_pickup_contact(self) -> None:
        self.shot("pickup-contact")
        self._safe_continue()

    def do_billing(self) -> None:
        self._click("pay_with_card", timeout=10, required=False)
        self._settle()
        card = secrets.get_json("card")
        if card:
            self._fill_card(card)
        self.shot("billing")
        self._safe_continue()

    def _fill_card(self, card: dict) -> None:
        exp = f"{card['exp_month']:>02}/{str(card['exp_year'])[-2:]}"
        wanted = (("card_number", card["number"]), ("card_expiration", exp), ("card_cvv", card["cvv"]))
        for key, value in wanted:
            for frame in self.page.frames:   # card fields may sit in an iframe
                loc = self._find(key, frame)
                if loc is not None:
                    if not loc.input_value():
                        loc.fill(value)
                    break

    def do_review(self) -> Result:
        self.shot("review")
        text = self.page.locator("body").inner_text()
        tot = self._find("order_total")
        self.total = parse_total(("Total " + tot.inner_text()) if tot is not None else text) or parse_total(text)
        cap = self.cap
        if cap is not None and (self.total is None or self.total > cap):
            why = (f"couldn't read the total to check it against your limit of {cap:,.2f}" if self.total is None
                   else f"total {self.total:,.2f} is over your limit of {cap:,.2f}")
            return Result("handed_off", detail=f"{why}, so it wasn't placed", total=self.total)
        if self.dry_run:
            return Result("dry_run", detail=f"reached the final page (total {self.total}); stopped before Place Order",
                          total=self.total)
        if not self.ab.place_order:
            return Result("review_ready", detail=f"ready on the final page (total {self.total}); press Place Order",
                          total=self.total)
        self._click("place_order")
        try:
            self.page.wait_for_url(re.compile(self.sel["stage_url_patterns"]["thankyou"], re.I), timeout=60000)
        except Exception:
            pass
        self._settle()
        return self.do_thankyou()

    def do_thankyou(self) -> Result:
        self.shot("thankyou")
        m = re.search(self.sel["order_number_pattern"], self.page.locator("body").inner_text())
        return Result("placed", order_number=m.group(1) if m else None, detail="order placed", total=self.total)

    def checkout(self) -> Result:
        self._click("bag_checkout")
        self._settle()
        visits: dict[str, int] = {}
        for _ in range(25):
            st = self.stage()
            visits[st] = visits.get(st, 0) + 1
            log.info("checkout stage: %s (%s)", st, self.page.url)
            if visits[st] > self.MAX_STAGE_VISITS:
                raise StepError(f"stuck on the {st} step")
            if st == "signin":
                self.sign_in()
            elif st == "fulfillment":
                self.do_fulfillment()
            elif st == "pickupcontact":
                self.do_pickup_contact()
            elif st == "billing":
                self.do_billing()
            elif st == "review":
                return self.do_review()
            elif st == "thankyou":
                return self.do_thankyou()
            elif st == "shipping":
                raise StepError("checkout switched to delivery instead of pickup")
            else:   # still loading, or a page we don't know: give it the step timeout
                visits[st] -= 1
                end = time.time() + self.ab.step_timeout_seconds
                while self.stage() == st and time.time() < end:
                    self.page.wait_for_timeout(1000)
                if self.stage() == st:
                    raise StepError(f"unrecognised checkout page {self.page.url}")
        raise StepError("checkout didn't reach the final page")

    def run(self) -> Result:
        if not self.signed_in():
            self.sign_in()
        if self.ab.clear_bag:
            self.clear_bag()
        self.add_to_bag()
        self.verify_bag()
        return self.checkout()

    def _desktop(self, title: str, msg: str) -> None:
        if self.settings.desktop_notifications:
            notify.desktop(title, msg, urgent=True)

    def _pushover(self, title: str, msg: str) -> None:
        if self.settings.pushover_enabled and notify.pushover_configured():
            try:
                notify.pushover(title, msg, self.page.url, "Open checkout", True)
            except Exception as e:
                log.error("Pushover send failed: %s", e)


def _handoff(flow: CheckoutFlow, minutes: int) -> Result | None:
    """Leave the window open for the user; record the order if they place it."""
    end = time.time() + minutes * 60
    while time.time() < end:
        if flow.page.is_closed():
            return None
        try:
            if flow.stage() == "thankyou":
                return flow.do_thankyou()
            flow.page.wait_for_timeout(2000)
        except Exception:
            return None
    return None


def purchase(search: Search, store_number: str, store_name: str, sku: str, settings: Settings,
             dry_run: bool = False, max_price: float | None = None) -> Result:
    """Order `sku` for pickup at `store_number`. Never raises: failures come back as a Result."""
    _require_playwright()
    from playwright.sync_api import sync_playwright

    c = data.country(search.country)
    shots = SCREENSHOT_DIR / time.strftime("%Y%m%d-%H%M%S")
    shots.mkdir(parents=True, exist_ok=True)
    item = c.sku_name(search.product, sku) or sku

    with sync_playwright() as pw:
        ctx = open_context(pw, settings)
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        flow = CheckoutFlow(page, c, store_number, store_name, sku, settings, dry_run, shots=shots, item_name=item,
                            max_price=max_price)
        try:
            result = flow.run()
        except Exception as e:  # StepError or Playwright errors: hand off, don't lose the item
            flow.shot("failed")
            result = Result("failed", detail=str(e).splitlines()[0][:300])
        result.screenshots = str(shots)

        messages = {
            "placed": (f"Order placed: {item}", f"Pickup at {store_name}. Order {result.order_number or '(see email)'}"),
            "review_ready": (f"Ready to order: {item}", f"At {store_name}. {result.detail}"),
            "dry_run": (f"Dry run OK: {item}", result.detail),
            "handed_off": (f"Finish your order: {item}", result.detail),
            "failed": (f"Auto-order stopped: {item}", f"{result.detail}. Checkout is open for you to finish."),
        }
        t, body = messages[result.status]
        log.info("auto-order %s: %s", result.status, result.detail)
        flow._desktop(t, body)
        flow._pushover(t, body)

        if result.status in ("review_ready", "handed_off", "failed") and not settings.autobuy.headless:
            done = _handoff(flow, settings.autobuy.handoff_minutes)
            if done is not None:
                result = done
                flow._desktop(f"Order placed: {item}", f"Order {done.order_number or '(see email)'}")
        ctx.close()
    return result


def interactive_login(settings: Settings, country_code: str) -> bool:
    """Open the store's account page and wait for the user to sign in."""
    _require_playwright()
    from playwright.sync_api import sync_playwright

    c = data.country(country_code)
    with sync_playwright() as pw:
        ctx = open_context(pw, settings, headless=False)
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        flow = CheckoutFlow(page, c, "", "", "", settings, dry_run=True)
        if flow.signed_in():
            print("Already signed in.")
            ctx.close()
            return True
        print("Sign in to your Apple account in the browser window (tick 'Trust' if asked). "
              "Waiting up to 10 minutes...")
        end = time.time() + 600
        ok = False
        while time.time() < end and not page.is_closed():
            if flow.stage() != "signin":
                ok = True
                break
            page.wait_for_timeout(1000)
        if ok:
            page.wait_for_timeout(2000)   # let Apple set its cookies
        ctx.close()
        return ok


def session_status(settings: Settings, country_code: str) -> bool:
    _require_playwright()
    from playwright.sync_api import sync_playwright

    with sync_playwright() as pw:
        ctx = open_context(pw, settings, headless=True)
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        ok = CheckoutFlow(page, data.country(country_code), "", "", "", settings, True).signed_in()
        ctx.close()
        return ok


def have_browser() -> bool:
    return find_browser() is not None or shutil.which("chromium") is not None
