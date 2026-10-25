"""A tiny stand-in for Apple's online store, for testing rfp.autobuy offline.

It mimics the shape of the real flow (Apple ID sign-in iframe, buy page with
trade-in / payment / carrier / AppleCare steps, bag, and the checkout stages
named by ?_s=) closely enough to exercise the state machine and its safety
checks. It is NOT a copy of Apple's markup.
"""
from __future__ import annotations

import html
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Store:
    def __init__(self):
        self.signed_in = False
        self.bag: list[str] = []
        self.orders: list[str] = []
        self.card_number = ""
        self.total = "1,165.00"


PAGE = """<!doctype html><html><head><meta charset=utf-8><title>{title}</title></head>
<body><h1>{h1}</h1>{body}</body></html>"""


def make_handler(store: Store):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, title, h1, body, code=200):
            data = PAGE.format(title=title, h1=h1, body=body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _redirect(self, to):
            self.send_response(302)
            self.send_header("Location", to)
            self.end_headers()

        def do_GET(self):  # noqa: C901 - one branch per page
            u = urllib.parse.urlparse(self.path)
            q = dict(urllib.parse.parse_qsl(u.query))
            p = u.path

            if p == "/shop/account/home":
                if not store.signed_in:
                    return self._redirect("/shop/signIn/account?r=home")
                return self._send("Account", "Your Account", "<p>Signed in</p>")
            if p.startswith("/shop/signIn"):
                nxt = urllib.parse.quote(q.get("r", "home"))
                return self._send("Sign In", "Sign in to the Apple Store",
                                  f'<iframe id="aid-auth-widget-iFrame" src="/idms/widget?r={nxt}" width=500 height=300></iframe>')
            if p == "/idms/widget":
                return self._send("Apple ID", "Apple ID", f"""
                  <form action="/idms/login" target="_top">
                    <input type=hidden name=r value="{html.escape(q.get('r', 'home'))}">
                    <input id="account_name_text_field" type="email" name="e">
                    <input id="password_text_field" type="password" name="pw">
                    <button id="sign-in" type="submit">Sign In</button></form>""")
            if p == "/idms/login":
                if q.get("e") and q.get("pw") == "correct-horse":
                    store.signed_in = True
                return self._redirect("/shop/checkout?_s=Fulfillment-init" if q.get("r") == "checkout"
                                      else "/shop/account/home")

            if p.startswith("/shop/product/"):
                sku = p[len("/shop/product/"):]
                return self._redirect(f"/shop/buy-iphone/iphone-18-pro/256gb-black?sku={urllib.parse.quote(sku)}")
            if p.startswith("/shop/buy-iphone/"):
                sku = q.get("sku", "")
                return self._send("Buy iPhone 18 Pro", "Buy iPhone 18 Pro", f"""
                  <div id=steps>
                    <button onclick="pick('trade', this)">No trade-in</button>
                    <button onclick="pick('pay', this)">Buy</button>
                    <button onclick="pick('carrier', this)">Connect to any carrier later</button>
                    <button onclick="pick('care', this)">No AppleCare+ Coverage</button>
                  </div>
                  <form action="/shop/bag/add"><input type=hidden name=sku value="{html.escape(sku)}">
                    <button name="add-to-cart" id=add disabled>Add to Bag</button></form>
                  <script>
                    const need = new Set(['trade','pay','carrier','care']);
                    function pick(k, el) {{ need.delete(k); el.disabled = true;
                      if (!need.size) document.getElementById('add').disabled = false; }}
                  </script>""")
            if p == "/shop/bag/add":
                store.bag.append(q["sku"])
                return self._send("Added", "Added to your bag",
                                  '<a href="/shop/bag"><button name="proceed">Review Bag</button></a>')
            if p == "/shop/bag/remove":
                i = int(q["i"])
                if 0 <= i < len(store.bag):
                    store.bag.pop(i)
                return self._redirect("/shop/bag")
            if p == "/shop/bag":
                rows = "".join(
                    f'<div class=item><span>iPhone 18 Pro 256GB Black ({html.escape(s)})</span>'
                    f'<select data-autom="item-quantity-{i}"><option>1</option><option>2</option></select>'
                    f'<a href="/shop/bag/remove?i={i}"><button data-autom="bag-item-remove-{i}">Remove</button></a></div>'
                    for i, s in enumerate(store.bag))
                return self._send("Bag", f"Your bag total is ${store.total}" if store.bag else "Your bag is empty",
                                  rows + '<a href="/shop/checkout/start"><button data-autom="checkout">Check Out</button></a>')
            if p == "/shop/checkout/start":
                if not store.signed_in:
                    return self._redirect("/shop/signIn?r=checkout")
                return self._redirect("/shop/checkout?_s=Fulfillment-init")

            if p == "/shop/checkout":
                s = q.get("_s", "")
                cont = lambda nxt, label="Continue": (  # noqa: E731
                    f'<button id="rs-checkout-continue-button-bottom" onclick="location=\'/shop/checkout?_s={nxt}\'">{label}</button>')
                if s == "Fulfillment-init":
                    return self._send("Checkout", "How would you like to get your order?", """
                      <button onclick="document.getElementById('pick').style.display='block'">I’ll pick it up</button>
                      <div id=pick style="display:none">
                        <input aria-label="ZIP Code" id=zip onkeydown="if(event.key==='Enter')document.getElementById('stores').style.display='block'">
                        <div id=stores style="display:none">
                          <label><input type=radio name=store value=R055 onclick="ok()"> Apple Somerset</label>
                          <label><input type=radio name=store value=R230 onclick="ok()"> Apple Briarwood</label>
                          <select aria-label="Pickup time" id=slot><option value="">Choose</option><option value="t1">Today 4–5pm</option></select>
                        </div></div>
                      <button id="rs-checkout-continue-button-bottom" onclick="go()">Continue to Pickup Details</button>
                      <script>
                        let picked=false; function ok(){picked=true}
                        function go(){ if(picked && document.getElementById('slot').value) location='/shop/checkout?_s=PickupContact-init'; }
                      </script>""")
                if s == "PickupContact-init":
                    return self._send("Checkout", "Who will pick up your order?", "<p>You</p>" + cont("Billing-init", "Continue to Payment"))
                if s == "Billing-init":
                    return self._send("Checkout", "How do you want to pay?", """
                      <label><input type=radio name=pay id="checkout.billing.billingoptions.credit"> Credit or Debit Card</label>
                      <form action="/shop/checkout/card">
                        <input autocomplete="cc-number" name=n><input autocomplete="cc-exp" name=x><input autocomplete="cc-csc" name=c>
                        <button id="rs-checkout-continue-button-bottom" type=submit>Review Your Order</button></form>""")
                if s == "Review":
                    return self._send("Checkout", "Ready to place your order?",
                                      f'<p>Subtotal $1,099.00</p><p>Total <span data-autom="bagtotalvalue">${store.total}</span></p>'
                                      '<a href="/shop/checkout/place"><button id="rs-checkout-continue-button-bottom">Place Your Order</button></a>')
            if p == "/shop/checkout/card":
                if q.get("n") and q.get("x") and q.get("c"):
                    store.card_number = q["n"]
                    return self._redirect("/shop/checkout?_s=Review")
                return self._redirect("/shop/checkout?_s=Billing-init")
            if p == "/shop/checkout/place":
                order = f"W{1234567890 + len(store.orders)}"
                store.orders.append(order)
                store.bag.clear()
                return self._redirect(f"/shop/checkout/thankyou?o={order}")
            if p == "/shop/checkout/thankyou":
                return self._send("Thank you", "Thank you, your order is placed.", f"<p>Order number: {q.get('o')}</p>")
            self._send("Not found", "Not found", "", 404)
    return H


def serve() -> tuple[ThreadingHTTPServer, Store]:
    store = Store()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(store))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, store
