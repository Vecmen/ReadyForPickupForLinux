import json
import os
import tempfile
import unittest
from pathlib import Path

_tmp = tempfile.mkdtemp()
for var in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME"):
    os.environ[var] = str(Path(_tmp) / var)

from rfp import autobuy, data, inventory, limits, watcher  # noqa: E402
from rfp.config import Search, Settings, State  # noqa: E402


def pickup_body(stores):
    """stores: [(number, name, {sku: pickupDisplay})]"""
    return json.dumps({"body": {"stores": [
        {"storeName": name, "storeNumber": num, "city": "Ann Arbor", "state": "MI",
         "partsAvailability": {sku: {"partNumber": sku, "pickupDisplay": disp} for sku, disp in parts.items()}}
        for num, name, parts in stores]}}).encode()


class FakeApple:
    def __init__(self, responses):
        self.responses, self.urls = list(responses), []

    def __call__(self, url, headers):
        self.urls.append((url, headers))
        r = self.responses.pop(0) if len(self.responses) > 1 else self.responses[0]
        return r


def search(**kw):
    kw.setdefault("product", "iPhonePro18")
    kw.setdefault("store", "R230")
    kw.setdefault("preferred", ["MJQ34LL/A"])
    return Search(**kw)


class InventoryTests(unittest.TestCase):
    def test_request_shape_and_chunking(self):
        s = search(product="MacBookPro14")
        n = len(data.country("US").products["MacBookPro14"])
        fake = FakeApple([(200, pickup_body([("R230", "Briarwood", {})]))])
        inventory.fetch_inventory(s, fake)
        self.assertEqual(len(fake.urls), -(-n // 20))
        url, headers = fake.urls[0]
        self.assertIn("www.apple.com/shop/retail/pickup-message?pl=true&location=48108", url)
        self.assertIn("parts.0=", url)
        self.assertEqual(headers["Referer"], "https://www.apple.com/shop/buy-iphone/")

    def test_own_store_first_default_is_unavailable_and_filters(self):
        body = pickup_body([
            ("R055", "Somerset", {"MJQ34LL/A": "available"}),
            ("R230", "Briarwood", {"MJQ34LL/A": "available", "MJQ44LL/A": "default"}),
        ])
        got = inventory.fetch_inventory(search(), FakeApple([(200, body)]))
        self.assertEqual([st.store_number for st, _ in got], ["R230", "R055"])
        self.assertEqual([p.sku for p in got[0][1]], ["MJQ34LL/A"])
        got = inventory.fetch_inventory(search(include_nearby=False), FakeApple([(200, body)]))
        self.assertEqual([st.store_number for st, _ in got], ["R230"])

    def test_throttle_and_errors(self):
        with self.assertRaises(inventory.Throttled):
            inventory.fetch_inventory(search(), FakeApple([(541, b"")]))
        with self.assertRaises(inventory.InventoryError):
            inventory.fetch_inventory(search(), FakeApple([(200, b'{"body":{"errorMessage":"not buyable"}}')]))

    def test_legacy_shape(self):
        legacy = {"body": {"content": {"pickupMessage": {"stores": json.loads(
            pickup_body([("R230", "Briarwood", {"MJQ34LL/A": "available"})]))["body"]["stores"]}}}}
        got = inventory.fetch_inventory(search(), FakeApple([(200, json.dumps(legacy).encode())]))
        self.assertEqual(got[0][1][0].name, "iPhone 18 Pro 256GB Black")


class WatcherTests(unittest.TestCase):
    def make(self, responses, total=1000.0, **kw):
        kw.setdefault("auto_buy", True)
        s = Settings(desktop_notifications=False, searches=[search(**kw)])
        s.autobuy.enabled = True
        s.autobuy.max_orders = None
        bought, caps = [], []

        def buyer(se, store, part, settings, cap):
            bought.append((store.store_number, part.sku))
            caps.append(cap)
            return autobuy.Result("placed", order_number=f"W{1234567890 + len(bought) - 1}", total=total)
        w = watcher.Watcher(s, State(), fetch=FakeApple(responses), autobuyer=buyer)
        w.budget.sleep = lambda x: None
        w.state.save = lambda: None
        w._pause = lambda sid: [setattr(x, "paused", True) for x in w.settings.searches if x.id == sid]
        w._notify = lambda t, b: w.notices.append(b)
        w.notices = []
        w.caps = caps
        return w, bought

    def test_dedupe_and_autobuy_once(self):
        avail = (200, pickup_body([("R230", "Briarwood", {"MJQ34LL/A": "available"})]))
        w, bought = self.make([avail, avail], auto_buy=True)
        w.sweep()
        self.assertEqual(bought, [("R230", "MJQ34LL/A")])
        self.assertTrue(w.settings.searches[0].paused)       # never orders twice
        self.assertEqual(w.state.orders[0]["order"], "W1234567890")

    def test_preferred_priority_and_nearby_rule(self):
        body = (200, pickup_body([("R055", "Somerset", {"MJQ34LL/A": "available"}),
                                  ("R230", "Briarwood", {"MJQ44LL/A": "available"})]))
        w, bought = self.make([body], auto_buy=True, preferred=["MJQ34LL/A", "MJQ44LL/A"])
        w.sweep()
        self.assertEqual(bought, [("R230", "MJQ44LL/A")])     # own store only by default
        w, bought = self.make([body], auto_buy=True, auto_buy_nearby=True, preferred=["MJQ34LL/A", "MJQ44LL/A"])
        w.sweep()
        self.assertEqual(bought, [("R055", "MJQ34LL/A")])     # first preference wins

    def _flip(self, w, times):
        """Model comes in, goes out, comes in again: `times` new availabilities."""
        on = (200, pickup_body([("R230", "Briarwood", {"MJQ34LL/A": "available"})]))
        off = (200, pickup_body([("R230", "Briarwood", {"MJQ34LL/A": "unavailable"})]))
        for _ in range(times):
            for r in (on, off):
                w.fetch.responses = [r]
                if not w.settings.searches[0].paused:
                    w.sweep()

    def test_search_max_orders(self):
        w, bought = self.make([], max_orders=2)
        self._flip(w, 4)
        self.assertEqual(len(bought), 2)
        self.assertTrue(w.settings.searches[0].paused)

    def test_global_max_orders(self):
        w, bought = self.make([], max_orders=None)
        w.settings.autobuy.max_orders = 1
        self._flip(w, 3)
        self.assertEqual(len(bought), 1)
        self.assertEqual(len(w.notices), 1)             # told once, not every time
        self.assertIn("1 of 1 orders", w.notices[0])

    def test_spending_budget_and_cap(self):
        w, bought = self.make([], total=1100.0, max_orders=None, max_price=1250.0)
        w.settings.autobuy.max_total_spend = 2500.0
        w.settings.autobuy.max_price = 1300.0
        self._flip(w, 4)
        self.assertEqual(len(bought), 3)                 # 1100 + 1100, then 300 left < price, but still tried
        self.assertEqual(w.caps, [1250.0, 1250.0, 300.0])  # tightest of the caps and budget left

    def test_spending_budget_used_up(self):
        w, bought = self.make([], total=1300.0, max_orders=None)
        w.settings.autobuy.max_total_spend = 1300.0
        self._flip(w, 2)
        self.assertEqual(len(bought), 1)
        self.assertIn("spending budget used up", w.notices[0])

    def test_no_autobuy_without_preferences(self):
        body = (200, pickup_body([("R230", "Briarwood", {"MJQ34LL/A": "available"})]))
        w, bought = self.make([body], auto_buy=True, preferred=[])
        w.sweep()
        self.assertEqual(bought, [])

    def test_throttle_backoff(self):
        w, _ = self.make([(429, b"")])
        w.sweep()
        self.assertEqual(w.state.throttle_failures, 1)
        self.assertGreater(w.state.throttled_until, 0)

    def test_budget(self):
        t = [1000.0]
        st = State()
        b = watcher.RequestBudget(st, clock=lambda: t[0], sleep=lambda x: t.__setitem__(0, t[0] + x))
        b.state.save = lambda: None
        for _ in range(30):
            b.acquire()
        self.assertEqual(t[0], 1000.0)
        b.acquire()                     # 31st request waits out the window
        self.assertEqual(t[0], 1000.0 + 94 * 60)


class MultiStoreTests(unittest.TestCase):
    BODY = (200, pickup_body([
        ("R230", "Briarwood", {"MJQ34LL/A": "unavailable"}),
        ("R055", "Somerset", {"MJQ34LL/A": "available"}),
        ("R041", "Twelve Oaks", {"MJQ34LL/A": "available"}),
        ("R999", "Far Away", {"MJQ34LL/A": "available"}),
    ]))

    def make(self, searches):
        s = Settings(desktop_notifications=False, searches=searches)
        s.autobuy.enabled = True
        s.autobuy.max_orders = None
        bought = []

        def buyer(se, store, part, settings, cap):
            bought.append((se.id, store.store_number))
            return autobuy.Result("placed", order_number="W1", total=900.0)
        w = watcher.Watcher(s, State(), fetch=FakeApple([self.BODY]), autobuyer=buyer)
        w.budget.sleep = lambda x: None
        w.state.save = lambda: None
        w._pause = lambda *ids: [setattr(x, "paused", True) for x in w.settings.searches if x.id in ids]
        w._notify = lambda t, b: None
        return w, bought

    def test_store_list_watches_only_listed_in_order(self):
        x = search(stores=["R041", "R230", "R055"])
        got = inventory.fetch_inventory(x, FakeApple([self.BODY]))
        self.assertEqual([st.store_number for st, _ in got], ["R041", "R055"])   # R999 not listed

    def test_autobuy_prefers_listed_order(self):
        w, bought = self.make([search(id="a", stores=["R230", "R041", "R055"], auto_buy=True)])
        w.sweep()
        self.assertEqual(bought, [("a", "R041")])

    def test_group_pauses_all_and_orders_once(self):
        a = search(id="a", stores=["R041"], auto_buy=True, group="iphone", max_orders=None)
        b = search(id="b", stores=["R055"], auto_buy=True, group="iphone", max_orders=None)
        c = search(id="c", stores=["R999"], auto_buy=True, max_orders=None)         # not in the group
        w, bought = self.make([a, b, c])
        w.sweep()
        self.assertEqual(bought, [("a", "R041"), ("c", "R999")])                   # b never orders
        self.assertEqual(len(w.fetch.urls), 2)                                    # b didn't even check
        self.assertTrue(a.paused and b.paused)
        self.assertFalse(c.paused)
        b.paused = False                                                          # resumed by hand
        self.assertFalse(limits.check(w.settings, w.state, b).allowed)            # group already ordered

    def test_real_pause_stops_group_mid_sweep(self):
        a = search(id="a", stores=["R041"], auto_buy=True, group="g", max_orders=None)
        b = search(id="b", stores=["R055"], auto_buy=True, group="g", max_orders=None)
        w, bought = self.make([a, b])
        w.settings.save()
        del w._pause                      # use the real one, which reloads the config file
        w.sweep()
        self.assertEqual(len(w.fetch.urls), 1)
        self.assertTrue(all(x.paused for x in Settings.load().searches))

    def test_missing_listed_store_warns(self):
        w, _ = self.make([search(id="a", stores=["R041", "R132"])])
        with self.assertLogs("rfp", level="WARNING") as cm:
            w.sweep()
        self.assertTrue(any("R132" in m for m in cm.output))


class LimitsTests(unittest.TestCase):
    def test_decision(self):
        s = Settings()
        st = State()
        x = search(max_orders=None)
        self.assertEqual(limits.check(s, st, x).cap, None)
        st.orders = [{"search": "other", "total": 900}]
        self.assertFalse(limits.check(s, st, x).allowed)          # default: 1 order overall
        s.autobuy.max_orders = None
        s.autobuy.max_total_spend = 1500
        self.assertEqual(limits.check(s, st, x).cap, 600)


class ReloadTests(unittest.TestCase):
    def test_config_reload(self):
        s = Settings(searches=[search()])
        s.save()
        w = watcher.Watcher(Settings.load(), State())
        self.assertTrue(w._reload_if_changed())                   # first look records the mtime
        self.assertFalse(w._reload_if_changed())
        s.searches.append(search(store="R055"))
        os.utime(watcher.CONFIG_FILE, (1, 1))
        s.save()
        self.assertTrue(w._reload_if_changed())
        self.assertEqual(len(w.settings.searches), 2)


class CheckoutHelpersTests(unittest.TestCase):
    def test_parse_total(self):
        self.assertEqual(autobuy.parse_total("Subtotal $1,099.00 Estimated tax $66.00 Total $1,165.00"), 1165.0)
        self.assertEqual(autobuy.parse_total("Gesamtsumme 1.299,00 € ... Total 1.299,00 €"), 1299.0)
        self.assertIsNone(autobuy.parse_total("no money here"))

    def test_selectors_load(self):
        sel = autobuy.load_selectors()
        for key in ("bag_checkout", "continue", "place_order", "stage_url_patterns", "add_to_bag"):
            self.assertIn(key, sel)


if __name__ == "__main__":
    unittest.main()
