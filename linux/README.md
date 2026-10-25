# ReadyForPickup for Linux (Arch)

A Linux port of the macOS app: it watches Apple Store **pickup** availability for
iPhone and Mac models at a store (and nearby stores), alerts you with desktop
notifications and Pushover when a model you want comes in, and can **order it
for pickup with your Apple account automatically**.

It uses the same data as the Mac app (`ReadyForPickup/ProductCatalog.json` and
`ReadyForPickup/Stores_LocalBootstrap.json`, symlinked into `rfp/data/`), the
same Apple endpoint, the same request budget and backoff, and the same
"alert only on newly available models" rule. `Scripts/update-*.py` keep working
for both apps.

## Install on Arch

```sh
git clone https://github.com/wehbs/ReadyForPickup && cd ReadyForPickup/linux
makepkg -si                     # installs /usr/bin/rfp and the systemd user unit
```

For auto-order also install a browser, Playwright and a keyring:

```sh
sudo pacman -S chromium gnome-keyring      # or KeePassXC with Secret Service enabled
yay -S python-playwright                   # AUR; or: pip install --user playwright
```

`rfp` uses `/usr/bin/chromium` (then Chrome / Brave) through Playwright, so
`playwright install` isn't needed. To use Playwright's own Chromium instead,
set `rfp config set autobuy.browser_executable /path/to/chrome`.

Without installing: `cd linux && python -m rfp --help`.

## Watch a store

```sh
rfp stores --find michigan                 # find your store's id (R###)
rfp products                               # product types sold in the US
rfp products iPhonePro18                   # its models and part numbers (SKUs)

rfp search add -p iPhonePro18 -s R230 --prefer MJQ34LL/A MJQ44LL/A
rfp check                                  # one check now
systemctl --user enable --now readyforpickup   # keep watching in the background
journalctl --user -u readyforpickup -f         # follow its log
```

Other countries: `-c GB`, `-c JP`, … (`rfp countries`). Preferred models are
the ones that alert you (if a search has none, every model alerts). Flags on
`search add` / `search edit`: `--no-nearby`, `--only-preferred`,
`--custom-sku SKU --nickname NAME`, `--no-desktop`, `--no-pushover`.
`rfp search list | pause | resume | remove <id>`.

**Pushover:** `rfp pushover set` (your own app token + user key, kept in the
keyring), then `rfp pushover test`. `rfp config set pushover_high_priority true`
breaks through quiet hours.

**Apple's throttle:** Apple blocks a network for up to ~30 minutes after about
31 pickup requests in 94 minutes. Every request goes through a budget of 30 per
94 minutes, the interval is raised automatically if your searches need more
(e.g. 2 Mac searches of 16 models = 2 requests per check, so ≥ 7 min), and a
throttled check backs off 2×, 4×, … up to an hour.
`rfp config set interval_minutes 10` (2, 5, 10, 15, 30 or 60).

## Auto-order with your Apple account

1. **Sign in once** in the app's own browser profile (2FA works normally; tick *Trust*):

   ```sh
   rfp account login
   ```

   Optional, for when that session expires: `rfp account set-credentials`
   stores your Apple ID and password in the keyring so it can sign back in by
   itself; if Apple then asks for a 2FA code, you get an alert and it waits for
   you to type it in the window.

2. **Payment:** if your Apple account doesn't already fill a card at checkout,
   `rfp account set-card` saves one in the keyring. It's typed into Apple's
   card fields only when they're empty.

3. **Arm a search and test it end to end without buying:**

   ```sh
   rfp search edit <id> --auto-buy          # requires --prefer models
   rfp config set autobuy.enabled true
   rfp config set autobuy.max_price 1299    # never pay more than this
   rfp buy --search <id> --dry-run          # walks checkout to the final page, then stops
   ```

   Screenshots of every step go to `~/.local/share/readyforpickup/checkout-screenshots/`.
   A dry run works even when the item is out of stock up to the store step,
   so do it ahead of a launch and again after Apple redesigns its store.

4. **Choose how far it goes:**
   * Default (`autobuy.place_order false`): when a preferred model appears it
     fills the whole checkout, alerts you, and leaves the window on *Place Your
     Order* for you to press. It notices when you do and records the order.
   * `rfp config set autobuy.place_order true`: presses *Place Your Order*
     itself. Only after a successful dry run, with `max_price` set.

What it does when a preferred model appears at your store
(or a nearby one with `--auto-buy-nearby`):

* picks the first model in your `--prefer` order, your own store first;
* empties your bag, adds that model, checks the bag holds exactly 1 item at quantity 1;
* checks out for **pickup** at that store with the first time slot, your
  account's pickup contact and saved payment;
* refuses to place the order if the total is over `max_price` or can't be read;
* pauses the search after an order, so it never buys twice;
* if any step fails (Apple changed a page, the slot vanished, a 2FA prompt), it
  alerts you and leaves the browser **mid-checkout** for you to finish, for
  `autobuy.handoff_minutes` (30).

`rfp orders` lists orders and attempts. `rfp account status` shows whether the
session is signed in. `rfp account forget [--session]` deletes the saved
Apple ID, card and (with `--session`) the sign-in.

### Keeping it working

Apple's checkout pages change without notice. Every button and field the
checkout uses is a selector in `rfp/checkout_selectors.json`; copy it to
`~/.config/readyforpickup/checkout_selectors.json` and edit the keys that
break (yours override the defaults). The step screenshots show where it stopped.

The checkout logic is tested against a local mock of the store flow
(`tests/test_checkout_mock.py`), not against apple.com.

### Things to know

* Apple's Sales Policy limits quantities per customer and lets Apple cancel
  orders it judges to be for resale or placed by automated means; this is
  built to get one item for you, not to scale.
* Run it on your desktop session (not headless): Apple is more likely to
  challenge headless browsers, and 2FA needs you.
* Secrets go to the Secret Service keyring via `secret-tool`. If no keyring is
  running they fall back to an **unencrypted** 0600 file, with a warning.

## Files

| Path | What |
|---|---|
| `~/.config/readyforpickup/config.json` | settings and searches (no secrets) |
| `~/.local/state/readyforpickup/state.json` | alert dedupe, request log, backoff, orders |
| `~/.local/share/readyforpickup/browser-profile/` | the signed-in apple.com browser session |
| keyring, service `readyforpickup` | Pushover keys, Apple ID, card |

## Tests

```sh
python -m unittest tests.test_rfp            # watcher, parsing, budget, dedupe (stdlib only)
python -m unittest tests.test_checkout_mock  # checkout vs. a local mock store (needs Playwright)
```
