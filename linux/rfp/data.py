"""The bundled store list and product catalog, shared with the macOS app.

Both files are the ones the macOS app ships (ReadyForPickup/*.json) and are
rebuilt by the same Scripts/update-*.py tools. In a git checkout they are
symlinked into rfp/data/; an installed package carries real copies.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

CATALOG_FILE = "ProductCatalog.json"
STORES_FILE = "Stores_LocalBootstrap.json"

# Product types in the macOS app's ProductType order, with display names.
PRODUCT_NAMES: dict[str, str] = {
    "MacBookNeo": "MacBook Neo",
    "M5MacBookAir13": "M5 MacBook Air 13in",
    "M5MacBookAir15": "M5 MacBook Air 15in",
    "MacBookPro14": "MacBook Pro 14in",
    "MacBookPro16": "MacBook Pro 16in",
    "iMac": "iMac",
    "MacMini": "Mac mini",
    "MacStudio": "Mac Studio",
    "iPhone16": "iPhone 16",
    "iPhone17": "iPhone 17",
    "iPhone17e": "iPhone 17e",
    "iPhoneAir": "iPhone Air",
    "iPhoneDuo": "iPhone Duo",
    "iPhonePro18": "iPhone 18 Pro",
    "iPhoneProMax18": "iPhone 18 Pro Max",
}


def _data_dirs() -> list[Path]:
    dirs = []
    if env := os.environ.get("RFP_DATA_DIR"):
        dirs.append(Path(env))
    here = Path(__file__).resolve().parent
    dirs += [
        here / "data",
        here.parent.parent / "ReadyForPickup",          # repo checkout
        Path("/usr/share/readyforpickup"),               # PKGBUILD install
    ]
    return dirs


def data_file(name: str) -> Path:
    for d in _data_dirs():
        p = d / name
        if p.is_file():
            return p
    raise FileNotFoundError(f"{name} not found (looked in {', '.join(map(str, _data_dirs()))}); "
                            "set RFP_DATA_DIR to the folder that has it")


@dataclass(frozen=True)
class Country:
    code: str
    name: str
    locale: str
    store_host: str
    store_path: str
    products: dict[str, list[tuple[str, str]]] = field(hash=False, compare=False)  # type -> [(sku, name)]

    def storefront_path(self, path: str) -> str:
        """'/uk/shop/buy-iphone/' for 'shop/buy-iphone/' in the UK."""
        return f"/{path}" if not self.store_path else f"/{self.store_path}/{path}"

    def url(self, path: str) -> str:
        return f"https://{self.store_host}{self.storefront_path(path)}"

    def product_page_url(self, sku: str) -> str:
        """Redirects to the buy page with that configuration selected."""
        return self.url(f"shop/product/{sku}")

    def sku_name(self, product: str, sku: str) -> str | None:
        return dict(self.products.get(product, [])).get(sku)


@dataclass(frozen=True)
class RetailStore:
    id: str
    name: str
    city: str
    state_code: str
    state_name: str
    postal_code: str

    @property
    def city_state(self) -> str:
        st = self.state_code or self.state_name
        return f"{self.city}, {st}" if st else self.city

    @property
    def pickup_location(self) -> str:
        """pickup-message takes a postal code or 'City, ST', not R###."""
        return self.postal_code or self.city_state


@lru_cache(maxsize=1)
def countries() -> dict[str, Country]:
    raw = json.loads(data_file(CATALOG_FILE).read_text(encoding="utf-8"))
    out: dict[str, Country] = {}
    for entry in raw["countries"]:
        if entry["code"] in out:
            continue
        products: dict[str, list[tuple[str, str]]] = {}
        for ptype, models in entry["products"].items():
            if ptype not in PRODUCT_NAMES:
                continue  # a type this build doesn't know
            seen: dict[str, str] = {}
            for m in models:
                seen.setdefault(m["sku"], m["name"])
            if seen:
                products[ptype] = list(seen.items())
        if products:
            out[entry["code"]] = Country(entry["code"], entry["name"], entry["locale"],
                                         entry["storeHost"], entry["storePath"], products)
    return out


def country(code: str) -> Country:
    try:
        return countries()[code.upper()]
    except KeyError:
        raise KeyError(f"country {code!r} isn't supported; try: {', '.join(countries())}") from None


@lru_cache(maxsize=1)
def _stores_by_locale() -> dict[str, list[RetailStore]]:
    raw = json.loads(data_file(STORES_FILE).read_text(encoding="utf-8"))
    out: dict[str, list[RetailStore]] = {}
    for c in raw["storeListData"]:
        groups = c["state"] if c.get("hasStates") else [{"store": c.get("store", [])}]
        stores = []
        for g in groups:
            for s in g["store"]:
                a = s.get("address", {})
                stores.append(RetailStore(s["id"], s["name"], a.get("city", ""), a.get("stateCode") or "",
                                          a.get("stateName") or "", a.get("postalCode") or ""))
        out[c["locale"]] = stores
    return out


def stores(country_code: str) -> list[RetailStore]:
    return _stores_by_locale().get(country(country_code).locale, [])


def find_store(country_code: str, store_id: str) -> RetailStore | None:
    return next((s for s in stores(country_code) if s.id == store_id.upper()), None)


# Stores the 2026-10 store-list refresh dropped (closed), with the postal code
# searches saved before then sent. Mirrors FulfillmentModel.closedStoreLocations.
CLOSED_STORE_LOCATIONS = {
    "en_AU": {"R458": "2077"},
    "en_GB": {"R252": "BS1 3BZ"},
    "en_US": {"R052": "95014", "R063": "21204", "R141": "60062", "R198": "96815",
              "R218": "48038", "R285": "92025", "R463": "28216", "R629": "06611"},
}
