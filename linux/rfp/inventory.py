"""Pickup availability from Apple's shop/retail/pickup-message endpoint.

A line-for-line port of the macOS app's FulfillmentModel: part numbers are
sent 20 per request (Apple's cap), stores are merged across chunks, the
search's own store comes first, and "default" pickupDisplay (pre-order /
check back) counts as unavailable.
"""
from __future__ import annotations

import gzip
import json
import platform
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Callable

from rfp import __version__, data
from rfp.config import Search

PARTS_PER_REQUEST = 20
USER_AGENT = f"ReadyForPickup-Linux/{__version__} (Linux {platform.release()})"


class InventoryError(Exception):
    pass


class Throttled(InventoryError):
    def __init__(self, status: int):
        super().__init__(f"Apple is throttling requests (HTTP {status})")
        self.status = status


@dataclass
class Part:
    sku: str
    name: str
    availability: str  # available | unavailable | ineligible


@dataclass
class StoreResult:
    store_number: str
    store_name: str
    city: str
    state: str | None
    parts: list[Part] = field(default_factory=list)
    distance: str = ""      # as Apple words it, e.g. "12.4 mi"; empty if not sent

    @property
    def location(self) -> str:
        return ", ".join(x for x in (self.city, self.state) if x)


def part_numbers(search: Search) -> list[str]:
    c = data.country(search.country)
    skus = [sku for sku, _ in c.products.get(search.product, [])]
    if search.custom and search.custom[0] not in skus:
        skus.append(search.custom[0])
    return skus


def request_count(search: Search) -> int:
    try:
        n = len(part_numbers(search))
    except KeyError:
        return 0
    return -(-n // PARTS_PER_REQUEST)


def pickup_location(search: Search) -> str:
    c = data.country(search.country)
    store = data.find_store(search.country, search.store)
    if store is None:
        if search.include_nearby and (loc := data.CLOSED_STORE_LOCATIONS.get(c.locale, {}).get(search.store)):
            return loc
        raise InventoryError(f"store {search.store} isn't in the {c.name} store list")
    return store.pickup_location


Fetcher = Callable[[str, dict[str, str]], tuple[int, bytes]]


def http_get(url: str, headers: dict[str, str]) -> tuple[int, bytes]:
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            return resp.status, body
    except urllib.error.HTTPError as e:
        return e.code, e.read() or b""
    except urllib.error.URLError as e:
        raise InventoryError(f"network error: {e.reason}") from e


def fetch_inventory(search: Search, fetch: Fetcher = http_get,
                    on_request: Callable[[], None] | None = None) -> list[tuple[StoreResult, list[Part]]]:
    """Available parts per store for `search`, its stores in preference order.

    `on_request` is called before each HTTP request (the rate limiter hooks in
    here). Raises Throttled on HTTP 429/541."""
    return available_models(fetch_stores(search, fetch, on_request), search)


def fetch_stores(search: Search, fetch: Fetcher = http_get,
                 on_request: Callable[[], None] | None = None) -> list[StoreResult]:
    """Every store Apple's lookup for `search` returned, in Apple's order."""
    c = data.country(search.country)
    if search.product not in c.products:
        raise InventoryError(f"{data.PRODUCT_NAMES.get(search.product, search.product)} isn't sold in {c.name}")
    skus = part_numbers(search)
    location = pickup_location(search)
    referer = c.url("shop/buy-iphone/")

    merged: dict[str, StoreResult] = {}
    for start in range(0, len(skus), PARTS_PER_REQUEST):
        chunk = skus[start:start + PARTS_PER_REQUEST]
        query = [("pl", "true"), ("location", location)] + [(f"parts.{i}", s) for i, s in enumerate(chunk) if s]
        url = c.url("shop/retail/pickup-message") + "?" + urllib.parse.urlencode(query)
        if on_request:
            on_request()
        status, body = fetch(url, {"Referer": referer, "User-Agent": USER_AGENT, "Accept": "*/*"})
        for store in parse_response(status, body, search, c):
            if (existing := merged.get(store.store_number)) is None:
                merged[store.store_number] = store
            else:
                have = {p.sku for p in existing.parts}
                existing.parts += [p for p in store.parts if p.sku not in have]

    return list(merged.values())


def parse_response(status: int, body: bytes, search: Search, c: data.Country) -> list[StoreResult]:
    if status in (429, 541):        # 541 = Apple's anti-bot / rate-limit page
        raise Throttled(status)
    if status >= 500:
        raise InventoryError(f"Apple's store is unavailable (HTTP {status})")
    if status >= 400:
        raise InventoryError(f"unexpected HTTP {status} from Apple")
    try:
        payload = json.loads(body)
        b = payload["body"]
    except (ValueError, KeyError, TypeError) as e:
        raise InventoryError("unexpected response shape from Apple") from e

    stores = b.get("stores")
    if stores is None:
        stores = (b.get("content") or {}).get("pickupMessage", {}).get("stores")  # legacy shape
    if stores is None:
        msg = b.get("errorMessage") or "no stores found"
        raise InventoryError(f"Apple returned no stores: {msg}")

    out = []
    for s in stores:
        try:
            name, number, city = s["storeName"], s["storeNumber"], s["city"]
            parts_raw = s["partsAvailability"]
        except (KeyError, TypeError):
            continue
        parts = []
        for p in parts_raw.values():
            sku, disp = p.get("partNumber"), p.get("pickupDisplay")
            if not sku or not disp:
                continue
            disp = "unavailable" if disp == "default" else disp
            if disp not in ("available", "unavailable", "ineligible"):
                continue
            pname = c.sku_name(search.product, sku) or (search.custom[1] if search.custom and search.custom[0] == sku else sku)
            parts.append(Part(sku, pname, disp))
        dist = s.get("storeDistanceWithUnit") or ""
        out.append(StoreResult(number, name, city, s.get("state"), parts, str(dist)))
    return out


def available_models(stores: list[StoreResult], search: Search) -> list[tuple[StoreResult, list[Part]]]:
    flt = None
    if search.only_preferred:
        flt = set(search.preferred) | ({search.custom[0]} if search.custom else set())
    scoped = watched_stores(stores, search)
    result = []
    for store in scoped:
        avail = [p for p in store.parts if p.availability == "available" and (flt is None or p.sku in flt)]
        if avail:
            result.append((store, avail))
    return result


def watched_stores(stores: list[StoreResult], search: Search) -> list[StoreResult]:
    """The stores a search watches, best first.

    With a store list: exactly those stores, in the listed order. Otherwise the
    search's own store, then (with include_nearby) the others in Apple's order."""
    if search.stores:
        by_id = {s.store_number: s for s in stores}
        return [by_id[sid] for sid in search.stores if sid in by_id]
    own = [s for s in stores if s.store_number == search.store]
    return own + [s for s in stores if s.store_number != search.store] if search.include_nearby else own
