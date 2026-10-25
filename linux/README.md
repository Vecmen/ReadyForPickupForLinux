# ReadyForPickup for Linux (Arch and Ubuntu)

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
git clone https://github.com/Vecmen/ReadyForPickupForLinux && cd ReadyForPickupForLinux/linux
makepkg -si                     # installs /usr/bin/rfp and the systemd user unit
```

For auto-order also install a browser, Playwright and a keyring:

```sh
sudo pacman -S chromium gnome-keyring      # or KeePassXC with Secret Service enabled
yay -S python-playwright                   # AUR; or: pip install --user playwright
```

`rfp` uses `/usr/bin/chromium` (then Chrome / Brave) through Playwright, so
`playwright install` isn't needed. To use Playwright's own Chromium instead,
run `rfp config set autobuy.browser_executable bundled` (or give a path).

Without installing: `cd linux && python -m rfp --help`.

## Install on Ubuntu (22.04+, GNOME), e.g. a VM left running

On the VM, as your normal desktop user:

```sh
sudo apt install -y git
git clone https://github.com/Vecmen/ReadyForPickupForLinux
cd ReadyForPickupForLinux/linux/ubuntu
./install.sh                 # or ./install.sh --no-autobuy for alerts only
```

(The installer needs the whole repository, not just `linux/`: the store list
and product catalog live in `ReadyForPickup/`.) To update later:
`git pull && ./install.sh` in the same folder.

It installs the apt packages it needs (sudo), puts the app in
`~/.local/share/readyforpickup/venv`, downloads Playwright's Chromium (Ubuntu's
own Chromium is a snap that can't be automated this way), adds `rfp` to
`~/.local/bin`, and installs and starts a systemd **user** service tied to your
GNOME session. It asks two questions:

* **Does the VM log in automatically?** With automatic login GNOME leaves your
  keyring locked, so it offers to keep secrets in
  `~/.config/readyforpickup/secrets.json` (readable only by you, not
  encrypted) instead. Say no if you type your password at login.
* **Turn off screen lock, blanking and suspend?** Recommended, so the VM keeps
  working while nobody is looking.

For it to come back by itself after the VM reboots, turn on automatic login
(Settings → Users → Automatic Login). To reach the desktop when it hands you a
checkout or asks for a 2FA code, turn on Settings → System → Remote Desktop →
**Desktop Sharing** (it shares the session that's already logged in) and
connect with any RDP client. Pushover is the best way to hear about it on your
phone (`rfp pushover set`).

Service: `systemctl --user status readyforpickup`, log:
`journalctl --user -u readyforpickup -f`. Remove with `./uninstall.sh`
(`--purge` also deletes your settings, history and secrets).

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

### Several stores for one model

One search can watch, and auto-buy at, a list of stores. The first one listed
is where Apple's lookup is centred, and the order is your preference:

```sh
rfp search add -p iPhonePro18 --prefer MJQ34LL/A --auto-buy \
    --stores R230 R041 R055 R763 --group iphone
rfp nearby <id>        # which stores that lookup covers (* = watched)
```

Apple answers for all of a lookup's nearby stores in **one request**, so one
search with a store list checks as often as a single store. Separate searches
each cost a request, so five of them check about every 16 minutes instead of 5.

Stores too far apart to show up in one lookup need their own search. Put them
in the **same group**; when any search in a group places an order, all of them
pause, and the group won't order again:

```sh
rfp search add -p iPhonePro18 --prefer MJQ34LL/A --auto-buy --stores R132 --group iphone
```

If a listed store isn't in its search's lookup, the log says so. Use
`--stores` with nothing after it to go back to "my store plus nearby", and
`--group ""` to leave a group. To buy again after a group has ordered, give its
searches a new group name and `rfp search resume` them.

The running service picks up `rfp search ...`, `rfp limits ...` and
`rfp config set` changes within a minute: no restart needed. With no active
searches it waits instead of exiting.

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

4. **Set your limits** (see [Limits](#limits)): by default it places at most
   **1 order in total**.

5. **Choose how far it goes:**
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
* checks your [limits](#limits) first, and refuses to place the order if the
  total is over the tightest price cap or budget left, or can't be read;
* pauses the search once it has placed the orders it's allowed;
* if any step fails (Apple changed a page, the slot vanished, a 2FA prompt), it
  alerts you and leaves the browser **mid-checkout** for you to finish, for
  `autobuy.handoff_minutes` (30).

If auto-buy is armed, every 12 hours it also checks that your Apple sign-in is
still valid and alerts you if it has expired, so you find out before a drop,
not during one (`autobuy.session_check_hours`, 0 = off).

`rfp orders` lists orders and attempts. `rfp account status` shows whether the
session is signed in. `rfp account forget [--session]` deletes the saved
Apple ID, card and (with `--session`) the sign-in.

### Limits

```sh
rfp limits                                   # what's set and what's been used
rfp limits set --orders 2                    # orders across all searches (default 1)
rfp limits set --spend 2500                  # total of all orders, tax included
rfp limits set --price 1300                  # the most one order may cost
rfp search edit <id> --max-orders 1 --max-price 1250   # per search
```

Use `none` to remove a limit (`rfp limits set --orders none`). Before every
auto-order it checks the order counts (overall and for that search), then
gives the checkout the **tightest** of the per-order price, the search's price
and the budget left. If the total on Apple's final page is over that, it
doesn't place the order: it alerts you and leaves the checkout open in case you
want to buy anyway. When a limit is reached it tells you once and stops
ordering until you raise it. Orders you place yourself during a hand-off count
too. `rfp buy` follows the same limits.

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
| keyring, service `readyforpickup` | Pushover keys, Apple ID, card (or `secrets.json` with `RFP_SECRETS=file`) |

## Tests

```sh
python -m unittest tests.test_rfp            # watcher, parsing, budget, dedupe (stdlib only)
python -m unittest tests.test_checkout_mock  # checkout vs. a local mock store (needs Playwright)
```
