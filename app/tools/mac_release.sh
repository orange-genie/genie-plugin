#!/usr/bin/env bash
# mac_release.sh — the two ways a Mac app reaches people, from one build.
#
#   ./tools/mac_release.sh notarize   the download on xearn.com — signed + notarized, no review
#   ./tools/mac_release.sh appstore   a .pkg ready to upload to App Store Connect
#
# WHY BOTH EXIST AND WHY THEY ARE DIFFERENT
# A notarized direct download and a Mac App Store build are not the same artifact with a
# different sticker. They use different certificates, different entitlements, and different
# containers, and each one is rejected if handed the other's settings:
#
#                     certificate                          entitlements        container
#   notarize          Developer ID Application             direct  (hardened)  .dmg
#   appstore          3rd Party Mac Developer Application  mas     (sandbox)   .pkg
#
# WHAT YOU NEED BEFORE EITHER WORKS — all from the Apple developer account, none of it in here:
#   TEAM_ID           the 10-character Team ID
#   For notarize:     a Developer ID Application certificate in the login keychain, and either
#                     APPLE_ID + APPLE_APP_PASSWORD (an app-specific password), or a notarytool
#                     keychain profile stored once with:
#                       xcrun notarytool store-credentials genie --apple-id … --team-id … --password …
#   For appstore:     "3rd Party Mac Developer Application" and "... Installer" certificates,
#                     plus a provisioning profile for the bundle id from App Store Connect.
#
# NOTHING HERE READS OR PRINTS A CREDENTIAL. Certificates stay in the keychain and the app
# password is passed by environment variable; neither is written to disk by this script.
set -euo pipefail

MODE="${1:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$ROOT/tauri"
BUNDLE_ID="com.xearn.genie"
APP_NAME="Genie 1"
OUT="$ROOT/dist"
mkdir -p "$OUT"

need() { [ -n "${!1:-}" ] || { echo "missing: $1 — see the header of this script"; exit 1; }; }

build() {
  echo "── building universal ──"
  ( cd "$T" && cargo tauri build --target universal-apple-darwin --bundles app )
  APP="$T/target/universal-apple-darwin/release/bundle/macos/$APP_NAME.app"
  [ -d "$APP" ] || { echo "no .app at $APP"; exit 1; }
  echo "  $APP"
}

case "$MODE" in
notarize)
  need TEAM_ID
  build
  echo "── signing with Developer ID (hardened runtime) ──"
  # --options runtime IS the hardened runtime. Notarization refuses a build without it, and
  # the refusal names a different problem, which is how an hour disappears.
  codesign --force --deep --timestamp --options runtime \
    --entitlements "$T/entitlements.direct.plist" \
    --sign "Developer ID Application: ($TEAM_ID)" "$APP"
  codesign --verify --strict --verbose=2 "$APP"

  DMG="$OUT/Genie-1-macOS.dmg"
  rm -f "$DMG"
  hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"
  codesign --force --timestamp --sign "Developer ID Application: ($TEAM_ID)" "$DMG"

  echo "── notarizing (Apple's turnaround is usually minutes) ──"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    need APPLE_ID; need APPLE_APP_PASSWORD
    xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" --wait
  fi
  # Stapling is what makes it work OFFLINE. Without it the first launch on a machine with no
  # network still shows the warning, which reads as the notarization not having worked.
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "  done: $DMG  (no more right-click -> Open)"
  ;;

appstore)
  need TEAM_ID
  build
  echo "── signing sandboxed for the store ──"
  # The provisioning profile must be INSIDE the bundle before signing, or the upload is rejected
  # for a missing profile with no hint about where it was supposed to go.
  if [ -n "${PROVISION_PROFILE:-}" ]; then
    cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
  else
    echo "  WARNING: no PROVISION_PROFILE set — App Store Connect will refuse the upload"
  fi
  codesign --force --deep --timestamp --options runtime \
    --entitlements "$T/entitlements.mas.plist" \
    --sign "3rd Party Mac Developer Application: ($TEAM_ID)" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  # Prove the sandbox actually applied, rather than assuming the flag took.
  codesign -d --entitlements - "$APP" | grep -q "app-sandbox" \
    || { echo "the sandbox entitlement did not apply — stopping"; exit 1; }

  PKG="$OUT/Genie-1-$BUNDLE_ID.pkg"
  rm -f "$PKG"
  productbuild --component "$APP" /Applications \
    --sign "3rd Party Mac Developer Installer: ($TEAM_ID)" "$PKG"
  echo "  done: $PKG"
  echo "  upload with:  xcrun altool --upload-app -f \"$PKG\" -t macos \\"
  echo "                  --apple-id \"\$APPLE_ID\" --password \"\$APPLE_APP_PASSWORD\""
  echo "  or open Transporter and drop it in."
  ;;

*)
  sed -n '2,8p' "$0"; exit 1;;
esac
