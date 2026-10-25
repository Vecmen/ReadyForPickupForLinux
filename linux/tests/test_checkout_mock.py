"""End-to-end checkout runs against tests/mock_apple_store.py (needs Playwright + Chromium)."""
import os
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path

_tmp = tempfile.mkdtemp()
for var in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME"):
    os.environ[var] = str(Path(_tmp) / var)

try:
    from playwright.sync_api import sync_playwright
except ImportError:  # pragma: no cover
    sync_playwright = None

from rfp import autobuy, data, secrets  # noqa: E402
from rfp.config import Settings  # noqa: E402
from tests import mock_apple_store  # noqa: E402

SKU = "MJQ34LL/A"


@dataclass(frozen=True)
class LocalCountry(data.Country):
    base: str = ""

    def url(self, path: str) -> str:
        return f"{self.base}/{path}"


@unittest.skipIf(sync_playwright is None, "Playwright not installed")
class CheckoutAgainstMockStore(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv, _ = mock_apple_store.serve()
        us = data.country("US")
        cls.base = f"http://127.0.0.1:{cls.srv.server_port}"
        cls.country = LocalCountry(us.code, us.name, us.locale, us.store_host, us.store_path, us.products, cls.base)
        secrets.set_json("apple_id", {"email": "me@example.com", "password": "correct-horse"})
        secrets.set_json("card", {"number": "4111111111111111", "exp_month": "7", "exp_year": "2029", "cvv": "123"})
        cls.pw = sync_playwright().start()
        cls.browser = cls.pw.chromium.launch()

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.pw.stop()
        cls.srv.shutdown()

    def run_flow(self, place_order=False, dry_run=False, max_price=None, prefill_bag=0):
        self.srv.RequestHandlerClass = mock_apple_store.make_handler(store := mock_apple_store.Store())
        store.bag = ["MX999LL/A"] * prefill_bag
        s = Settings()
        s.autobuy.headless = True
        s.autobuy.place_order = place_order
        s.autobuy.max_price = max_price
        s.autobuy.step_timeout_seconds = 8
        s.autobuy.handoff_minutes = 0
        page = self.browser.new_context().new_page()
        flow = autobuy.CheckoutFlow(page, self.country, "R230", "Briarwood", SKU, s, dry_run,
                                    item_name="iPhone 18 Pro 256GB Black")
        result = flow.run()
        page.context.close()
        return result, store

    def test_stops_at_review_by_default(self):
        r, store = self.run_flow(prefill_bag=2)
        self.assertEqual(r.status, "review_ready", r.detail)
        self.assertEqual(store.orders, [])
        self.assertEqual(store.bag, [SKU])             # other items were removed first
        self.assertEqual(store.card_number, "4111111111111111")

    def test_dry_run_never_places(self):
        r, store = self.run_flow(place_order=True, dry_run=True)
        self.assertEqual(r.status, "dry_run", r.detail)
        self.assertEqual(store.orders, [])

    def test_places_order_when_armed(self):
        r, store = self.run_flow(place_order=True, max_price=1200)
        self.assertEqual(r.status, "placed", r.detail)
        self.assertEqual(r.order_number, "W1234567890")
        self.assertEqual(store.orders, ["W1234567890"])

    def test_price_cap_blocks_order(self):
        r, store = self.run_flow(place_order=True, max_price=999)
        self.assertEqual(r.status, "handed_off")
        self.assertIn("over your limit of 999.00", r.detail)
        self.assertEqual(store.orders, [])


if __name__ == "__main__":
    unittest.main()
