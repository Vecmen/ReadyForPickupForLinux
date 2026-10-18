#!/bin/zsh
# Build a Developer ID-signed, notarized InventoryWatch DMG.
#
# Prerequisites (one-time, must be done by the Account Holder):
#   1. Create a "Developer ID Application" certificate:
#      Xcode > Settings > Accounts > (Shamir's Apple ID) > Manage
#      Certificates > + > Developer ID Application.
#      NOTE: an App Store Connect API key CANNOT do this - Apple's
#      Certificates API returns 403 "This operation can only be
#      performed by the Account Holder" (verified 2026-10-18).
#   2. Verify it landed:  security find-identity -v -p codesigning
# Then run this script - no other setup needed. Notarization uses
# the App Store Connect API key in ~/.appstoreconnect/config.json.
#
# Bundle ID decision: com.worthbak.InventoryWatch is KEPT for now.
# Developer ID notarization needs no provisioning profile and does
# not require the bundle ID to be registered, so this notarizes as
# is. Renaming to com.wehbs.InventoryWatch is cleaner long-term but
# changes the UserDefaults domain (saved searches/preferences live
# under the bundle ID) and the Pushover Keychain service name
# (com.worthbak.InventoryWatch.pushover) - do that rename as its
# own migration change, not as part of a signing fix.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
if [[ -z "${IDENTITY:-}" ]]; then
  echo "ERROR: No 'Developer ID Application' identity in the keychain."
  echo "The Account Holder must create one first:"
  echo "  Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application"
  echo "Then re-run this script."
  exit 1
fi
echo "Signing identity: $IDENTITY"

VERSION=$(grep -m1 "MARKETING_VERSION" InventoryWatch.xcodeproj/project.pbxproj | sed -E 's/.*= ([0-9.]+);/\1/')
WORK=/tmp/inventorywatch-release
APP="$WORK/DerivedData/Build/Products/Release/InventoryWatch.app"
DMG="$WORK/InventoryWatch-$VERSION.dmg"
rm -rf "$WORK"; mkdir -p "$WORK"

xcodebuild -project InventoryWatch.xcodeproj -scheme InventoryWatch \
  -configuration Release -derivedDataPath "$WORK/DerivedData" \
  build CODE_SIGNING_ALLOWED=NO | tail -2

codesign --force --deep --timestamp --options runtime \
  --entitlements InventoryWatch/InventoryWatch.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

mkdir -p "$WORK/stage"; cp -R "$APP" "$WORK/stage/"
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -volname InventoryWatch -srcfolder "$WORK/stage" -ov -format UDZO "$DMG"

# Notarize with the App Store Connect API key (ids are read from
# config.json; the .p8 private key itself is never printed).
read KEY_ID ISSUER_ID KEY_PATH < <(python3 -c "
import json,pathlib
c=json.load(open(pathlib.Path.home()/'.appstoreconnect/config.json'))
print(c['keyID'], c['issuerID'], c['keyPath'])")
xcrun notarytool submit "$DMG" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER_ID" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG" || true
echo "Done: $DMG"
