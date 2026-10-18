# inventory-checker-app

InventoryWatch — a macOS app that watches Apple Store pickup stock for current US iPhones and Macs and alerts you when your preferred models come into stock.

## Download

Grab the latest built app from the **[Releases page](https://github.com/wehbs/inventory-checker-app/releases)** — download the `.dmg`, open it, and drag InventoryWatch into Applications.

> **Note:** current builds are **not notarized / not Developer ID-signed**, so on first launch macOS Gatekeeper will block a normal double-click. **Right-click (Control-click) the app → Open** to launch it the first time. A notarized build is planned once a Developer ID is enrolled.

## About this fork

This is a modernized fork of [worthbak's InventoryWatch](https://github.com/worthbak/inventory-checker-app) (thanks, Worth!). Since the 2023 upstream release it has been updated for macOS 13+, Apple's current pickup API, the current US iPhone/Mac catalog, a 2.0-style three-pane interface with multiple saved searches, auto-refresh with throttle backoff, and Pushover phone notifications (bring your own Pushover app token, entered in Settings).

Licensed under GPL-3.0 — see LICENSE.md.

The upstream project page is here: https://worthbak.github.io/inventory-checker-app/
