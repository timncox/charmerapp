#!/bin/bash
# Builds Charmera.dmg from the signed .app and (if credentials are set up)
# submits it to Apple's notary service so Gatekeeper lets users open it
# without the "unidentified developer" prompt.
#
# One-time setup to enable notarization:
#   1. Generate an app-specific password at https://appleid.apple.com
#      (Sign-In and Security → App-Specific Passwords)
#   2. Run once:
#        xcrun notarytool store-credentials charmera-notary \
#          --apple-id tim.cox@gmail.com \
#          --team-id P5EK689L33 \
#          --password <app-specific-password>
#   3. Re-run this script. It'll detect the profile and notarize+staple
#      automatically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Charmera"
BUNDLE_DIR="$SCRIPT_DIR/build/$APP_NAME.app"
DMG_DIR="$SCRIPT_DIR/build/dmg"
DMG_PATH="$SCRIPT_DIR/build/$APP_NAME.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-charmera-notary}"

if [ ! -d "$BUNDLE_DIR" ]; then
    echo "Error: $BUNDLE_DIR not found. Run ./build.sh first."
    exit 1
fi

echo "Creating DMG..."
rm -rf "$DMG_DIR" "$DMG_PATH"
mkdir -p "$DMG_DIR"

cp -R "$BUNDLE_DIR" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_DIR"

echo "Created: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo ""
    echo "Skipping notarization: keychain profile '$NOTARY_PROFILE' not set up."
    echo "See the header of dmg.sh for one-time setup instructions."
    exit 0
fi

echo ""
echo "Submitting to Apple notary service (this usually takes 1-5 minutes)..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "Stapling ticket..."
xcrun stapler staple "$DMG_PATH"

echo ""
echo "Notarized: $DMG_PATH"
xcrun stapler validate "$DMG_PATH"
