#!/usr/bin/env bash
#
# Build, sign, notarize, and package quill for distribution as a menu-bar .app
# shipped inside a .dmg. Everything signs with a single Developer ID
# Application certificate — no Developer ID Installer cert required.
#
# The same script runs locally and in CI.
#
# Configuration (all via environment, with local-dev defaults):
#   VERSION          release version, e.g. 0.1.0            (default: 0.1.0)
#   APP_IDENTITY     "Developer ID Application: ..." name / hash
#   NOTARY_PROFILE   notarytool keychain profile name (enables notarize+staple)
#   SKIP_NOTARIZE=1  build & sign but don't notarize
#
# Requirements: Xcode toolchain and a Developer ID Application cert. Notarization
# needs stored credentials (`xcrun notarytool store-credentials`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.1.0}"
APP_IDENTITY="${APP_IDENTITY:-Developer ID Application: Omer Karisman (XH64JAYUW5)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
BUNDLE_ID="com.digimata.quill"

BUILD_BIN="$ROOT/.build/release/quill"
ENTITLEMENTS="$ROOT/packaging/quill.entitlements"
PLIST_TEMPLATE="$ROOT/packaging/Info.plist"
DIST="$ROOT/dist"
APP="$DIST/quill.app"
DMG="$DIST/quill-$VERSION.dmg"
DMG_STAGE="$DIST/dmg"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

step "Building release binary (arm64)"
swift build -c release

step "Assembling quill.app"
rm -rf "$APP" "$DMG" "$DMG_STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed "s/@VERSION@/$VERSION/g" "$PLIST_TEMPLATE" > "$APP/Contents/Info.plist"
cp "$BUILD_BIN" "$APP/Contents/MacOS/quill"
cp "$ROOT/packaging/quill.icns" "$APP/Contents/Resources/quill.icns"
xattr -cr "$APP"

step "Codesigning app (hardened runtime + entitlements)"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$APP_IDENTITY" \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [[ "${SKIP_NOTARIZE:-}" != "1" && -n "$NOTARY_PROFILE" ]]; then
  step "Notarizing app"
  ditto -c -k --keepParent "$APP" "$DIST/quill-app.zip"
  xcrun notarytool submit "$DIST/quill-app.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$DIST/quill-app.zip"
  step "Stapling app"
  xcrun stapler staple "$APP"
else
  step "Skipping app notarization (SKIP_NOTARIZE set or NOTARY_PROFILE empty)"
fi

step "Building .dmg"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "quill $VERSION" -srcfolder "$DMG_STAGE" \
  -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

step "Codesigning .dmg"
codesign --force --timestamp --sign "$APP_IDENTITY" "$DMG"

if [[ "${SKIP_NOTARIZE:-}" != "1" && -n "$NOTARY_PROFILE" ]]; then
  step "Notarizing .dmg"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  step "Stapling .dmg"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" || true
else
  step "Skipping .dmg notarization"
  echo "WARNING: unsigned-of-notarization build — for local testing only."
fi

step "Done"
echo "App: $APP"
echo "Artifact: $DMG"
