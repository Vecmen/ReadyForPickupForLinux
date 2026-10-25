"""Auto-buy limits: how many orders, how much per order, how much in total.

Limits (unset = no limit):
  autobuy.max_orders        orders placed across all searches (default 1)
  autobuy.max_total_spend   total of all placed orders' totals
  autobuy.max_price         one order's total
  search.max_orders         orders placed by that search (default 1)
  search.group              one order per group of searches
  search.max_price          one order's total for that search

Every placed order is recorded in state.json with its total, whether the
tool pressed Place Order or you did during a hand-off. The per-order cap
handed to the checkout is the smallest of the price caps and the budget left.
"""
from __future__ import annotations

from dataclasses import dataclass

from rfp.config import Search, Settings, State


@dataclass
class Decision:
    allowed: bool
    reason: str = ""
    cap: float | None = None     # the most this order may cost


def orders_placed(state: State, search_id: str | None = None) -> int:
    return sum(1 for o in state.orders if search_id is None or o.get("search") == search_id)


def spent(state: State) -> float:
    return sum(float(o.get("total") or 0) for o in state.orders)


def check(settings: Settings, state: State, search: Search) -> Decision:
    ab = settings.autobuy
    if ab.max_orders is not None and orders_placed(state) >= ab.max_orders:
        return Decision(False, f"auto-buy limit reached: {orders_placed(state)} of {ab.max_orders} orders placed")
    if search.max_orders is not None and orders_placed(state, search.id) >= search.max_orders:
        return Decision(False, f"this search already placed {search.max_orders} order(s)")
    if search.group and any(o.get("group") == search.group for o in state.orders):
        return Decision(False, f"group {search.group!r} already placed its order (give the searches a new group "
                               "name to buy again)")
    caps = [c for c in (ab.max_price, search.max_price) if c is not None]
    if ab.max_total_spend is not None:
        left = ab.max_total_spend - spent(state)
        if left <= 0:
            return Decision(False, f"spending budget used up ({spent(state):.2f} of {ab.max_total_spend:.2f})")
        caps.append(left)
    return Decision(True, cap=min(caps) if caps else None)


def search_done(state: State, search: Search) -> bool:
    """Whether a search has placed all the orders it may (so it should pause)."""
    return search.max_orders is not None and orders_placed(state, search.id) >= search.max_orders


def summary(settings: Settings, state: State) -> list[str]:
    ab = settings.autobuy

    def fmt(v, money=True):
        return "no limit" if v is None else (f"{v:,.2f}" if money else str(v))

    lines = [
        f"orders placed:      {orders_placed(state)} of {fmt(ab.max_orders, False)}",
        f"total spent:        {spent(state):,.2f} of {fmt(ab.max_total_spend)}",
        f"max per order:      {fmt(ab.max_price)}",
    ]
    for s in settings.searches:
        if s.auto_buy:
            d = check(settings, state, s)
            status = f"can buy up to {fmt(d.cap)}" if d.allowed else d.reason
            n = orders_placed(state, s.id)
            of = "no limit" if s.max_orders is None else f"limit {s.max_orders}"
            lines.append(f"search {s.id}:    {n} order{'' if n == 1 else 's'} ({of}), "
                         f"max price {fmt(s.max_price)}  -> {status}")
    return lines
