#!/bin/zsh
# Build a Developer ID-signed, notarized, Sparkle-ready InventoryWatch DMG.
#
# Flow: build Release (unsigned) -> sign Sparkle nested code then the app
# -> DMG -> notarize (notarytool --wait) -> staple -> generate/sign appcast.
# The script prints the DMG path, its SHA-256, and the generated appcast.xml
# path. It does NOT publish the GitHub release or commit appcast.xml; see
# README "Releasing" for those steps (gh must use --repo wehbs/...).
#
# Sparkle / notarization prerequisites:
#   * Developer ID Application cert in login Keychain (Account Holder only).
#   * App Store Connect API key in ~/.appstoreconnect/config.json.
#   * Sparkle EdDSA private key ONLY in login Keychain (Sparkle's
#     generate_keys; service https://sparkle-project.org, account ed25519).
#     Never commit/export/print it. Only SUPublicEDKey is in Info.plist.
#   * Sparkle tools come from the SPM artifact bundle resolved by Xcode;
#     this script fails safe (exits) if generate_appcast is missing.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
if [[ -z "${IDENTITY:-}" ]]; then
  echo "ERROR: No 'Developer ID Application' identity in the keychain." >&2
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

# Locate Sparkle tools from the SPM artifact; fail safe if missing.
SPARKLE_BIN=$(find "$WORK/DerivedData/SourcePackages/artifacts" -path "*Sparkle/bin/generate_appcast" 2>/dev/null | head -1 || true)
if [[ -z "${SPARKLE_BIN:-}" ]]; then
  echo "ERROR: Sparkle generate_appcast not found under DerivedData; resolve SPM packages first." >&2
  exit 1
fi
SPARKLE_TOOLS=$(dirname "$SPARKLE_BIN")
echo "Sparkle tools: $SPARKLE_TOOLS"

# Sign Sparkle's nested code first (not --deep), then the app.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  for xpc in "$SPARKLE_FW"/Versions/B/XPCServices/*.xpc; do
    [[ -e "$xpc" ]] && codesign --force --timestamp --options runtime --sign "$IDENTITY" "$xpc"
  done
  [[ -e "$SPARKLE_FW/Versions/B/Autoupdate" ]] && codesign --force --timestamp --options runtime --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/Autoupdate"
  [[ -e "$SPARKLE_FW/Versions/B/Updater.app" ]] && codesign --force --timestamp --options runtime --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/Updater.app"
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$SPARKLE_FW"
fi
codesign --force --timestamp --options runtime \
  --entitlements InventoryWatch/InventoryWatch.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p "$WORK/stage"; cp -R "$APP" "$WORK/stage/"
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -volname InventoryWatch -srcfolder "$WORK/stage" -ov -format UDZO "$DMG"

read KEY_ID ISSUER_ID KEY_PATH < <(python3 -c "
import json,pathlib
c=json.load(open(pathlib.Path.home()/'.appstoreconnect/config.json'))
print(c['keyID'], c['issuerID'], c['keyPath'])")
# NOTE: notarization can take hours. --wait blocks; submission ID is printed
# by notarytool. If detached, poll: notarytool info <id> ... (see README).
xcrun notarytool submit "$DMG" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER_ID" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG" || true

# Generate + EdDSA-sign appcast entry for THIS version. Enclosure URL points
# at the GitHub Release asset (published separately via gh release create).
mkdir -p "$WORK/appcast"
cp "$DMG" "$WORK/appcast/"
cp appcast.xml "$WORK/appcast/appcast.xml" 2>/dev/null || true
"$SPARKLE_TOOLS/generate_appcast" \
  --download-url-prefix "https://github.com/wehbs/inventory-checker-app/releases/download/v$VERSION/" \
  -o "$WORK/appcast-out.xml" "$WORK/appcast"
# generate_appcast writes into the archives dir; prefer its appcast.xml
if [[ -f "$WORK/appcast/appcast.xml" ]]; then cp "$WORK/appcast/appcast.xml" ./appcast.xml; fi
python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('appcast.xml'); print('appcast.xml: well-formed XML')"
shasum -a 256 "$DMG"
echo "Done: $DMG"
echo "Appcast updated: $(pwd)/appcast.xml (review, commit + push it, then create the GitHub release)"
