import json
import os
import tempfile
import unittest
from pathlib import Path

_tmp = tempfile.mkdtemp()
for var in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME"):
    os.environ[var] = str(Path(_tmp) / var)

from rfp import autobuy, data, inventory, watcher  # noqa: E402
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
    def make(self, responses, **kw):
        s = Settings(desktop_notifications=False, searches=[search(**kw)])
        s.autobuy.enabled = True
        bought = []

        class R:
            status, order_number = "placed", "W1234567890"

        def buyer(se, store, part, settings):
            bought.append((store.store_number, part.sku))
            return R()
        w = watcher.Watcher(s, State(), fetch=FakeApple(responses), autobuyer=buyer)
        w.budget.sleep = lambda x: None
        s.save = lambda: None
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
