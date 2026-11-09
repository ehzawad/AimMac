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

NAME="Orbit Pointer"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
DMG="build/OrbitPointer-$VERSION.dmg"
WORKING="build/OrbitPointer-$VERSION-unfinished.dmg"
STAGE="build/dmg"

# The release name only ever holds a finished file, so a failure can't leave one to upload by mistake.
rm -f "$DMG" "$WORKING"

SIGN_IDENTITY="$IDENTITY" ./build.sh

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "build/$NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$WORKING"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$WORKING"

echo "Notarizing ${WORKING}"
xcrun notarytool submit "$WORKING" \
  --key "$HOME/.appstoreconnect/private_keys/AuthKey_$NOTARY_KEY_ID.p8" \
  --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait

xcrun stapler staple "$WORKING"
spctl -a -vvv -t open --context context:primary-signature "$WORKING"
mv "$WORKING" "$DMG"
echo "Ready: $DMG"
