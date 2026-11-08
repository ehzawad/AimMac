#!/bin/bash
# Builds the public download: a signed, notarized .dmg in build/.
#
# Needs a Developer ID Application certificate and an App Store Connect API key
# saved as ~/.appstoreconnect/private_keys/AuthKey_<key id>.p8:
#   NOTARY_KEY_ID=... NOTARY_ISSUER=... ./release.sh
set -euo pipefail
cd "$(dirname "$0")"

: "${NOTARY_KEY_ID:?Set NOTARY_KEY_ID to your App Store Connect key ID}"
: "${NOTARY_ISSUER:?Set NOTARY_ISSUER to your App Store Connect issuer ID}"

IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)"
if [[ -z "$IDENTITY" ]]; then
  echo "No Developer ID Application certificate found." >&2
  exit 1
fi

SIGN_IDENTITY="$IDENTITY" ./build.sh

NAME="Orbit Pointer"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
DMG="build/OrbitPointer-$VERSION.dmg"
STAGE="build/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "build/$NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "Notarizing $DMG…"
xcrun notarytool submit "$DMG" \
  --key "$HOME/.appstoreconnect/private_keys/AuthKey_$NOTARY_KEY_ID.p8" \
  --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait

xcrun stapler staple "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG"
echo "Ready: $DMG"
