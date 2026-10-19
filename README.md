# inventory-checker-app

InventoryWatch — a macOS app that watches Apple Store pickup stock for current US iPhones and Macs and alerts you when your preferred models come into stock.

## Download

Grab the latest built app from the **[Releases page](https://github.com/wehbs/inventory-checker-app/releases)** — download the `.dmg`, open it, and drag InventoryWatch into Applications.

> **Note:** builds from v0.3.1 onward are Developer ID-signed and notarized by Apple, so they open with a normal double-click (earlier builds, e.g. v0.3.0, were unsigned for distribution and needed Privacy & Security -> Open Anyway on first launch).

## About this fork

This is a modernized fork of [worthbak's InventoryWatch](https://github.com/worthbak/inventory-checker-app) (thanks, Worth!). Since the 2023 upstream release it has been updated for macOS 13+, Apple's current pickup API, the current US iPhone/Mac catalog, a 2.0-style three-pane interface with multiple saved searches, auto-refresh with throttle backoff, and Pushover phone notifications (bring your own Pushover app token, entered in Settings).

Licensed under GPL-3.0 — see LICENSE.md.

The upstream project page is here: https://worthbak.github.io/inventory-checker-app/

## Auto-updates (Sparkle)

InventoryWatch 0.3.2+ uses [Sparkle 2.9.6](https://github.com/sparkle-project/Sparkle) (MIT — see `Sparkle-LICENSE.txt`) to check for updates automatically (daily, on by default; toggle in Settings → Software Updates, or use **InventoryWatch → Check for Updates…**).

- **Update feed:** `https://raw.githubusercontent.com/wehbs/inventory-checker-app/main/appcast.xml` — a file in this repo (on `main`), chosen so releases are version-controlled, reviewable, and don't depend on a separate hosting service. The DMG enclosures it points to are GitHub Release assets.
- **Signing key:** updates are EdDSA-signed. The *private* key lives only in the maintainer's Mac login Keychain (created by Sparkle's `generate_keys`; service `https://sparkle-project.org`, account `ed25519`) — it is never in this repo. Only the public key (`SUPublicEDKey`) is embedded in the app's `Info.plist`.
- **One-time manual update:** v0.3.1 and earlier were built *without* Sparkle, so they cannot self-update. Download v0.3.2 (or later) manually once from the Releases page; after that, updates flow automatically.

## Releasing

Run `Scripts/build-notarized-release.sh` (see its header). It builds, signs Sparkle's nested code then the app, makes the DMG, notarizes (`notarytool submit --wait` — this can take hours; the submission ID is printed — if running detached, poll `xcrun notarytool info <id> --key … --key-id … --issuer …` every ~2 min, and on `Accepted` staple/validate and check `spctl` on the mounted app), staples, then generates/signs `appcast.xml` with Sparkle's `generate_appcast` (fails safe if the Sparkle tools are missing). Then, in order:

1. Commit + push the version bump and the generated `appcast.xml`.
2. `gh release create v<VERSION> /tmp/inventorywatch-release/InventoryWatch-<VERSION>.dmg --repo wehbs/inventory-checker-app --title "InventoryWatch <VERSION>" --notes "…"` — **always pass `--repo wehbs/inventory-checker-app`** (`gh` otherwise defaults to the upstream worthbak repo here).
3. Verify: the release asset downloads (HTTP 200), its SHA-256 matches the local DMG, the mounted app passes `spctl -a -vvv` (`accepted source=Notarized Developer ID`), and the live appcast enclosure URL/signature match. Note the DMG itself may show `spctl` "no usable signature" (it isn't codesigned) — the app inside is what matters.

Do not delete old releases; note in the release notes that 0.3.2 is the first auto-updating release.
