#!/bin/bash
# Builds DeskKit, has Apple notarize it, and packs build/DeskKit.zip for a GitHub release.
#
# One-time setup:
#   1. A "Developer ID Application" certificate with its private key in your keychain
#      (developer.apple.com, Certificates; or import a .p12 exported from another Mac).
#   2. Without Xcode, Apple's "Developer ID - G2" intermediate certificate too, or codesign can't
#      build the chain (apple.com/certificateauthority, DeveloperIDG2CA.cer).
#   3. notarytool credentials saved in your keychain under the profile name "DeskKit", either an
#      App Store Connect API key:
#        xcrun notarytool store-credentials DeskKit --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer ID>
#      or your Apple ID with an app-specific password (made at account.apple.com):
#        xcrun notarytool store-credentials DeskKit --apple-id <your Apple ID> --team-id <your team ID>
# Set DESKKIT_NOTARY_PROFILE to use another profile name.
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${DESKKIT_NOTARY_PROFILE:-DeskKit}"
APP=build/DeskKit.app
UPLOAD=build/DeskKit-notarize.zip

./build.sh --no-install
# grep without -q reads to the end, so codesign isn't cut off mid-write (pipefail would count that).
if ! codesign -dvv "$APP" 2>&1 | grep "^Authority=Developer ID Application" >/dev/null; then
    echo "DeskKit wasn't signed with a Developer ID Application certificate, so Apple won't notarize it." >&2
    exit 1
fi

ditto -c -k --keepParent "$APP" "$UPLOAD"
echo "Sending DeskKit to Apple to notarize (this usually takes a minute or two)…"
OUTPUT="$(xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" --wait 2>&1)" || true
echo "$OUTPUT"
rm -f "$UPLOAD"
if ! grep -q "status: Accepted" <<<"$OUTPUT"; then
    ID="$(sed -n 's/^ *id: \([0-9a-f-]*\).*/\1/p' <<<"$OUTPUT" | head -1)"
    if [[ -n "$ID" ]]; then xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true; fi
    echo "Notarization failed." >&2
    exit 1
fi

xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm -f build/DeskKit.zip
ditto -c -k --keepParent "$APP" build/DeskKit.zip
echo "Ready to publish: build/DeskKit.zip"
