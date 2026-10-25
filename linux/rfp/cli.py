"""`rfp` command line."""
from __future__ import annotations

import argparse
import getpass
import json
import logging
import sys
from dataclasses import asdict, fields

from rfp import __version__, data, inventory, limits, notify, secrets
from rfp.config import CONFIG_FILE, SCREENSHOT_DIR, STATE_FILE, ALLOWED_INTERVALS, AutoBuySettings, Search, Settings, State

log = logging.getLogger("rfp")


# ---------------------------------------------------------------- catalog
def cmd_countries(a, s):
    for c in data.countries().values():
        print(f"{c.code}  {c.name}")


def cmd_stores(a, s):
    needle = (a.find or "").lower()
    for st in data.stores(a.country):
        line = f"{st.id}  {st.name:<28} {st.city_state}  {st.postal_code}"
        if needle in (line + " " + st.state_name).lower():
            print(line)


def cmd_products(a, s):
    c = data.country(a.country)
    if not a.product:
        for p in data.PRODUCT_NAMES:
            if p in c.products:
                print(f"{p:<16} {data.PRODUCT_NAMES[p]}  ({len(c.products[p])} models)")
        return
    if a.product not in c.products:
        raise SystemExit(f"{a.product} isn't sold in {c.name}; `rfp products -c {c.code}` lists what is")
    for sku, name in c.products[a.product]:
        print(f"{sku:<12} {name}")


# ---------------------------------------------------------------- searches
def _apply_search_flags(search: Search, a) -> None:
    if a.country:
        search.country = a.country.upper()
    if a.store:
        search.store = a.store.upper()
    if a.product:
        search.product = a.product
    c = data.country(search.country)
    if search.product not in c.products:
        raise SystemExit(f"{search.product} isn't sold in {c.name}")
    store = data.find_store(search.country, search.store)
    if store is None:
        raise SystemExit(f"no store {search.store} in {c.name}; `rfp stores -c {c.code} --find <city>`")
    search.store_name = store.name
    if a.stores is not None:
        ids = list(dict.fromkeys(x.upper() for x in a.stores))
        bad = [x for x in ids if data.find_store(search.country, x) is None]
        if bad:
            raise SystemExit(f"no store {', '.join(bad)} in {c.name}; `rfp stores -c {c.code} --find <city>`")
        search.stores = ids
    if a.group is not None:
        search.group = a.group.strip()
    if a.prefer is not None:
        known = dict(c.products[search.product])
        bad = [x for x in a.prefer if x not in known and x != search.custom_sku]
        if bad:
            raise SystemExit(f"not {search.product} models in {c.name}: {', '.join(bad)} "
                             f"(`rfp products -c {c.code} {search.product}`)")
        search.preferred = a.prefer
    for flag, attr in (("only_preferred", "only_preferred"), ("nearby", "include_nearby"),
                       ("desktop", "notify_desktop"), ("pushover", "notify_pushover"),
                       ("auto_buy", "auto_buy"), ("auto_buy_nearby", "auto_buy_nearby")):
        if (v := getattr(a, flag)) is not None:
            setattr(search, attr, v)
    if a.max_price is not None:
        search.max_price = _lim(a.max_price)
    if a.max_orders is not None:
        search.max_orders = _lim(a.max_orders)
    if a.custom_sku is not None:
        search.custom_sku = a.custom_sku
    if a.nickname is not None:
        search.custom_sku_nickname = a.nickname
    if search.auto_buy and not (search.preferred or search.custom):
        raise SystemExit("--auto-buy needs --prefer (the exact models you'd buy), so it can't order the wrong one")


def cmd_search_add(a, s):
    if not a.product:
        raise SystemExit("--product is required")
    search = Search(product=a.product)
    if not a.store:   # the lookup location: the first listed store, else SoHo
        a.store = a.stores[0] if a.stores else "R032"
    _apply_search_flags(search, a)
    s.searches.append(search)
    s.save()
    print(f"added search {search.id}: {_describe(search)}")
    if search.stores:
        print(f"tip: `rfp nearby {search.id}` checks that Apple's lookup covers all of those stores")
    if search.auto_buy and not s.autobuy.enabled:
        print("note: auto-order is off globally; `rfp config set autobuy.enabled true` to arm it")


def cmd_search_edit(a, s):
    search = s.search(a.id)
    _apply_search_flags(search, a)
    s.save()
    print(f"updated {search.id}: {_describe(search)}")


def _describe(x: Search) -> str:
    flags = [f for f, on in (("nearby", x.include_nearby and not x.stores), ("only-preferred", x.only_preferred),
                             ("AUTO-BUY" + ("+nearby" if x.auto_buy_nearby and not x.stores else ""), x.auto_buy),
                             ("paused", x.paused)) if on]
    pref = f" prefer={','.join(x.preferred)}" if x.preferred else ""
    if x.stores:
        pref += f" stores={','.join(x.stores)}"
    if x.group:
        pref += f" group={x.group}"
    if x.auto_buy:
        pref += (f" max-orders={'none' if x.max_orders is None else x.max_orders}"
                 + (f" max-price={x.max_price:g}" if x.max_price is not None else ""))
    return (f"{data.PRODUCT_NAMES.get(x.product, x.product)} at {x.store_name or x.store} ({x.store}, {x.country})"
            f"{pref}{' [' + ' '.join(flags) + ']' if flags else ''}")


def cmd_search_list(a, s):
    if not s.searches:
        print("no searches yet: `rfp search add --product iPhonePro18 --store R032 --prefer <SKU>`")
    for x in s.searches:
        print(f"{x.id}  {_describe(x)}")


def cmd_search_remove(a, s):
    s.searches.remove(s.search(a.id))
    s.save()
    print(f"removed {a.id}")


def cmd_search_pause(a, s, paused=True):
    s.search(a.id).paused = paused
    s.save()
    print(f"{'paused' if paused else 'resumed'} {a.id}")


# ---------------------------------------------------------------- run
def _autobuyer():
    from rfp import autobuy

    def run(search, store, part, settings, cap):
        try:
            return autobuy.purchase(search, store.store_number, store.store_name, part.sku, settings, max_price=cap)
        except SystemExit as e:   # Playwright missing: report, don't stop watching
            log.error("auto-buy unavailable: %s", e)
            return autobuy.Result("failed", detail=str(e))
    return run


def _session_checker():
    from rfp import autobuy

    def check(settings, country):
        try:
            return autobuy.session_status(settings, country)
        except SystemExit as e:
            raise RuntimeError(str(e)) from None
    return check


def cmd_check(a, s):
    from rfp.watcher import Watcher
    if a.search:
        s.searches = [s.search(a.search)]
    state = State.load()
    w = Watcher(s, state, autobuyer=_autobuyer())
    results = w.sweep()
    for sid, found in results.items():
        x = next(q for q in s.searches if q.id == sid)
        print(f"\n{sid}  {_describe(x)}")
        if not found:
            print("   nothing available")
        for store, parts in found:
            print(f"   {store.store_name} ({store.location})")
            for p in parts:
                print(f"     {'★' if x.is_preferred(p.sku) else ' '} {p.sku:<12} {p.name}")


def cmd_nearby(a, s):
    """Which stores one lookup returns (costs one Apple request)."""
    from rfp.watcher import RequestBudget
    if a.id:
        search = s.search(a.id)
    else:
        if not a.store:
            raise SystemExit("give a search id, or --store (and --product)")
        search = Search(product=a.product, country=a.country.upper(), store=a.store.upper())
    stores = inventory.fetch_stores(search, on_request=RequestBudget(State.load()).acquire)
    watched = {st.store_number for st in inventory.watched_stores(stores, search)}
    print(f"Apple's lookup near {search.store} returns {len(stores)} store(s):")
    for st in stores:
        mark = "*" if st.store_number in watched else " "
        stock = sum(p.availability == "available" for p in st.parts)
        print(f" {mark} {st.store_number}  {st.store_name:<26} {st.location:<22} {st.distance:>9}  "
              f"{stock} model(s) in stock")
    missing = [x for x in search.stores if x not in {st.store_number for st in stores}]
    print("\n* = watched by this search")
    if missing:
        print(f"not covered by this lookup: {', '.join(missing)}. Watch those from another search with the "
              f"same --group" + (f" ({search.group})" if search.group else "") + ".")


def cmd_watch(a, s):
    from rfp.watcher import Watcher
    # Keeps running with no active searches and picks up config edits live,
    # so the service never needs restarting after `rfp search ...`.
    Watcher(s, State.load(), autobuyer=_autobuyer(), session_checker=_session_checker()).run_forever()


def cmd_buy(a, s):
    """Run the checkout now for one search (use --dry-run to test it)."""
    from rfp import autobuy
    search = s.search(a.search)
    sku = a.sku or (search.preferred[0] if search.preferred else None)
    if not sku:
        raise SystemExit("--sku is required (the search has no preferred models)")
    store_id = (a.store or search.store).upper()
    store = data.find_store(search.country, store_id)
    if store is None:
        raise SystemExit(f"no store {store_id} in {search.country}")
    decision = limits.check(s, State.load(), search)
    if not decision.allowed and not a.dry_run:
        raise SystemExit(f"not ordering: {decision.reason} (`rfp limits` to see or raise them)")
    cap = decision.cap if decision.allowed else s.autobuy.max_price
    if not a.dry_run and not a.yes:
        ok = input(f"This will try to ORDER {sku} for pickup at {store.name}"
                   f"{'' if cap is None else f' (max {cap:,.2f})'}"
                   f"{'' if s.autobuy.place_order else ' (stopping at the final page)'}. Continue? [y/N] ")
        if ok.strip().lower() != "y":
            return
    r = autobuy.purchase(search, store.id, store.name, sku, s, dry_run=a.dry_run, max_price=cap)
    print(f"{r.status}: {r.detail}" + (f"  order {r.order_number}" if r.order_number else ""))
    print(f"screenshots: {r.screenshots}")
    if r.status == "placed":
        from rfp.watcher import record_order
        st = State.load()
        record_order(st, search, sku, store.id, r)
        st.save()
        if limits.search_done(st, search):
            search.paused = True
            s.save()


def cmd_orders(a, s):
    st = State.load()
    for o in st.orders:
        total = f"  {o['total']:,.2f}" if o.get("total") else ""
        print(f"{o.get('order') or '(no number)'}  {o['sku']} @ {o['store']}  search {o['search']}{total}")
    for sid, attempts in st.autobuy_attempts.items():
        for line in attempts[-10:]:
            print(f"attempt [{sid}] {line}")
    if not st.orders and not st.autobuy_attempts:
        print("no orders or attempts yet")


# ---------------------------------------------------------------- limits
def cmd_limits_show(a, s):
    for line in limits.summary(s, State.load()):
        print(line)
    print("\nChange with: rfp limits set --orders N --spend AMOUNT --price AMOUNT  (\"none\" = no limit)")


def cmd_limits_set(a, s):
    if a.orders is None and a.spend is None and a.price is None:
        raise SystemExit("give at least one of --orders, --spend, --price")
    if a.orders is not None:
        s.autobuy.max_orders = _lim(a.orders)
    if a.spend is not None:
        s.autobuy.max_total_spend = _lim(a.spend)
    if a.price is not None:
        s.autobuy.max_price = _lim(a.price)
    s.save()
    cmd_limits_show(a, s)


def _limit_num(kind):
    def parse(v: str):
        if v.lower() in ("none", "off", "unlimited"):
            return LIMIT_OFF
        n = kind(v.replace(",", "").lstrip("$"))
        if n < 0:
            raise argparse.ArgumentTypeError("must be 0 or more")
        return n
    parse.__name__ = kind.__name__
    return parse


class _Off:
    """argparse value meaning "remove this limit" (stored as None)."""


LIMIT_OFF = _Off()


def _lim(v):
    return None if v is LIMIT_OFF else v


# ---------------------------------------------------------------- config / secrets
def cmd_config_show(a, s):
    d = asdict(s)
    d.pop("searches")
    print(json.dumps(d, indent=2))
    print(f"\nconfig: {CONFIG_FILE}\nstate:  {STATE_FILE}\nscreenshots: {SCREENSHOT_DIR}")


def _coerce(value: str, current):
    if isinstance(current, bool):
        if value.lower() in ("true", "on", "yes", "1"):
            return True
        if value.lower() in ("false", "off", "no", "0"):
            return False
        raise SystemExit(f"expected true/false, got {value!r}")
    if isinstance(current, int):
        return int(value)
    if value.lower() in ("none", "null", ""):
        return None
    try:
        return float(value) if current is None or isinstance(current, float) else value
    except ValueError:
        return value


def cmd_config_set(a, s):
    key = a.key
    if key.startswith("autobuy."):
        attr = key.split(".", 1)[1]
        if attr not in {f.name for f in fields(AutoBuySettings)}:
            raise SystemExit(f"unknown setting {key}")
        setattr(s.autobuy, attr, _coerce(a.value, getattr(s.autobuy, attr)))
    elif key in ("interval_minutes", "desktop_notifications", "pushover_enabled", "pushover_high_priority"):
        v = _coerce(a.value, getattr(s, key))
        if key == "interval_minutes" and v not in ALLOWED_INTERVALS:
            raise SystemExit(f"interval must be one of {ALLOWED_INTERVALS}")
        setattr(s, key, v)
    else:
        raise SystemExit(f"unknown setting {key}")
    s.save()
    print(f"{key} = {a.value}")
    if key == "autobuy.place_order" and s.autobuy.place_order:
        print("warning: auto-order will now press Place Order without asking. Set autobuy.max_price "
              "and test with `rfp buy --dry-run` first.")


def cmd_pushover_set(a, s):
    secrets.set("pushover_token", getpass.getpass("Pushover app API token: ").strip())
    secrets.set("pushover_user", getpass.getpass("Pushover user key: ").strip())
    s.pushover_enabled = True
    s.save()
    print("saved to keyring; Pushover enabled")


def cmd_pushover_test(a, s):
    notify.pushover("ReadyForPickup test", "Pushover is set up.", high_priority=s.pushover_high_priority)
    print("sent")


def cmd_notify_test(a, s):
    notify.desktop("ReadyForPickup test", "Desktop notifications work.", urgent=True)


def cmd_account_login(a, s):
    from rfp import autobuy
    ok = autobuy.interactive_login(s, a.country)
    if ok:
        print("Signed in. Auto-buy will use this session.")
    else:
        print("Not signed in. If the Apple page accepted your password but kept loading, wait for your "
              "account page before closing the window. `rfp -v account login` shows more detail.")
    return 0 if ok else 1


def cmd_account_status(a, s):
    from rfp import autobuy
    signed = autobuy.session_status(s, a.country)
    print(f"apple.com session: {'signed in' if signed else 'signed out (run `rfp account login`)'}")
    creds = secrets.get_json("apple_id")
    print(f"saved Apple ID:    {creds['email'] if creds else 'none'}")
    card = secrets.get_json("card")
    print(f"saved card:        {'•••• ' + card['number'][-4:] if card else 'none'}")
    print(f"browser:           {autobuy.find_browser(s.autobuy.browser_executable) or 'Playwright bundled Chromium'}")


def cmd_account_set_credentials(a, s):
    email = input("Apple ID (email): ").strip()
    pw = getpass.getpass("Apple ID password: ")
    secrets.set_json("apple_id", {"email": email, "password": pw})
    print("saved to keyring (used only to re-sign-in when the saved session expires)")


def cmd_account_set_card(a, s):
    print("Typed into Apple's card fields only when they're empty. Stored in your keyring.")
    number = input("Card number: ").replace(" ", "").replace("-", "")
    if not number.isdigit() or not 12 <= len(number) <= 19 or not _luhn(number):
        raise SystemExit("that doesn't look like a valid card number")
    month = input("Expiry month (MM): ").strip().zfill(2)
    year = input("Expiry year (YY or YYYY): ").strip()
    cvv = getpass.getpass("Security code: ").strip()
    secrets.set_json("card", {"number": number, "exp_month": month, "exp_year": year, "cvv": cvv})
    print(f"saved card ending {number[-4:]}")


def _luhn(n: str) -> bool:
    total = 0
    for i, ch in enumerate(reversed(n)):
        d = int(ch)
        if i % 2:
            d = d * 2 - 9 if d > 4 else d * 2
        total += d
    return total % 10 == 0


def cmd_account_forget(a, s):
    for key in ("apple_id", "card"):
        secrets.delete(key)
    if a.session:
        import shutil
        from rfp.config import BROWSER_PROFILE
        shutil.rmtree(BROWSER_PROFILE, ignore_errors=True)
    print("removed saved Apple ID and card" + (" and the browser session" if a.session else ""))


# ---------------------------------------------------------------- parser
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="rfp", description="Watch Apple Store pickup availability (and order).")
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--version", action="version", version=f"rfp {__version__}")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("countries", help="supported countries").set_defaults(fn=cmd_countries)
    x = sub.add_parser("stores", help="Apple Stores in a country")
    x.add_argument("-c", "--country", default="US")
    x.add_argument("-f", "--find", help="filter by name, city, state or ZIP")
    x.set_defaults(fn=cmd_stores)
    x = sub.add_parser("products", help="product types, or one type's models and SKUs")
    x.add_argument("product", nargs="?")
    x.add_argument("-c", "--country", default="US")
    x.set_defaults(fn=cmd_products)

    srch = sub.add_parser("search", help="manage saved searches").add_subparsers(dest="sub", required=True)

    def search_flags(sp, add: bool):
        sp.add_argument("--product", "-p", required=False)
        sp.add_argument("--country", "-c", default="US" if add else None)
        sp.add_argument("--store", "-s", help="store id, e.g. R230: where Apple's lookup is centred")
        sp.add_argument("--stores", nargs="*", metavar="R###",
                        help="watch and auto-buy at exactly these stores, best first (none = clear)")
        sp.add_argument("--group", metavar="NAME",
                        help="searches in a group stop together once one of them orders (\"\" = none)")
        sp.add_argument("--prefer", nargs="*", metavar="SKU", help="preferred models (alerts and auto-order)")
        sp.add_argument("--max-price", type=_limit_num(float), metavar="AMOUNT",
                        help="auto-buy: most one order may cost (\"none\" = no limit)")
        sp.add_argument("--max-orders", type=_limit_num(int), metavar="N",
                        help="auto-buy: orders this search may place, default 1 (\"none\" = no limit)")
        sp.add_argument("--custom-sku")
        sp.add_argument("--nickname")
        for name, helptext in (("only-preferred", "show only preferred models"),
                               ("nearby", "include nearby stores"), ("desktop", "desktop notifications"),
                               ("pushover", "Pushover alerts"), ("auto-buy", "order automatically"),
                               ("auto-buy-nearby", "auto-order at a nearby store too")):
            sp.add_argument(f"--{name}", dest=name.replace("-", "_"), action=argparse.BooleanOptionalAction,
                            default=None, help=helptext)

    x = srch.add_parser("add")
    search_flags(x, True)
    x.set_defaults(fn=cmd_search_add)
    x = srch.add_parser("edit")
    x.add_argument("id")
    search_flags(x, False)
    x.set_defaults(fn=cmd_search_edit)
    srch.add_parser("list").set_defaults(fn=cmd_search_list)
    for name, fn in (("remove", cmd_search_remove), ("pause", cmd_search_pause),
                     ("resume", lambda a, s: cmd_search_pause(a, s, False))):
        x = srch.add_parser(name)
        x.add_argument("id")
        x.set_defaults(fn=fn)

    x = sub.add_parser("nearby", help="which stores one lookup covers (uses one Apple request)")
    x.add_argument("id", nargs="?", help="a search id")
    x.add_argument("-s", "--store")
    x.add_argument("-p", "--product", default="iPhonePro18")
    x.add_argument("-c", "--country", default="US")
    x.set_defaults(fn=cmd_nearby)

    x = sub.add_parser("check", help="check once now")
    x.add_argument("--search")
    x.set_defaults(fn=cmd_check)
    sub.add_parser("watch", help="keep checking (what the systemd service runs)").set_defaults(fn=cmd_watch)

    x = sub.add_parser("buy", help="run the checkout now for a search (test with --dry-run)")
    x.add_argument("--search", required=True)
    x.add_argument("--sku")
    x.add_argument("--store")
    x.add_argument("--dry-run", action="store_true", help="go all the way to the final page, never place the order")
    x.add_argument("-y", "--yes", action="store_true")
    x.set_defaults(fn=cmd_buy)
    sub.add_parser("orders", help="orders placed and auto-order attempts").set_defaults(fn=cmd_orders)

    lim = sub.add_parser("limits", help="auto-buy limits: orders, spending, price per order")
    lim.set_defaults(fn=cmd_limits_show)
    limsub = lim.add_subparsers(dest="sub")
    x = limsub.add_parser("set", help='e.g. --orders 2 --spend 2500 --price 1299 ("none" = no limit)')
    x.add_argument("--orders", type=_limit_num(int), metavar="N", help="orders across all searches")
    x.add_argument("--spend", type=_limit_num(float), metavar="AMOUNT", help="total of all orders")
    x.add_argument("--price", type=_limit_num(float), metavar="AMOUNT", help="most one order may cost")
    x.set_defaults(fn=cmd_limits_set)

    cfg = sub.add_parser("config", help="settings").add_subparsers(dest="sub", required=True)
    cfg.add_parser("show").set_defaults(fn=cmd_config_show)
    x = cfg.add_parser("set", help="e.g. interval_minutes 10, autobuy.enabled true, autobuy.max_price 1299")
    x.add_argument("key")
    x.add_argument("value")
    x.set_defaults(fn=cmd_config_set)

    po = sub.add_parser("pushover", help="Pushover phone alerts").add_subparsers(dest="sub", required=True)
    po.add_parser("set").set_defaults(fn=cmd_pushover_set)
    po.add_parser("test").set_defaults(fn=cmd_pushover_test)
    sub.add_parser("notify-test", help="send a test desktop notification").set_defaults(fn=cmd_notify_test)

    acc = sub.add_parser("account", help="your Apple account for auto-order").add_subparsers(dest="sub", required=True)
    for name, fn in (("login", cmd_account_login), ("status", cmd_account_status)):
        x = acc.add_parser(name)
        x.add_argument("-c", "--country", default="US")
        x.set_defaults(fn=fn)
    acc.add_parser("set-credentials", help="save Apple ID + password to the keyring").set_defaults(
        fn=cmd_account_set_credentials)
    acc.add_parser("set-card", help="save a payment card to the keyring").set_defaults(fn=cmd_account_set_card)
    x = acc.add_parser("forget", help="delete saved Apple ID and card")
    x.add_argument("--session", action="store_true", help="also sign out (delete the browser profile)")
    x.set_defaults(fn=cmd_account_forget)
    return p


def main(argv: list[str] | None = None) -> int:
    a = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if a.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S", stream=sys.stderr)
    try:
        return a.fn(a, Settings.load()) or 0
    except KeyError as e:
        print(f"error: {e.args[0]}", file=sys.stderr)
        return 2
    except inventory.InventoryError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
