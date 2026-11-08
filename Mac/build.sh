#!/bin/bash
# Builds Orbit Pointer.app for Apple silicon and Intel. Needs Xcode or the Command Line Tools.
#   ./build.sh           build
#   ./build.sh run       build and open from build/
#   ./build.sh install   build, copy to /Applications and open
#
# Signs with SIGN_IDENTITY if set, otherwise your Apple Development certificate
# if there is one. A real certificate lets macOS remember the Accessibility
# permission across rebuilds; an ad-hoc signature does not.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Orbit Pointer"
EXE="OrbitPointer"
APP="build/$NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 6 \
    -target "$arch-apple-macos14.0" \
    -o "build/$EXE-$arch" \
    Sources/*.swift ../Shared/*.swift \
    -framework AppKit -framework CoreBluetooth -framework ApplicationServices
done
lipo -create -output "$APP/Contents/MacOS/$EXE" "build/$EXE-arm64" "build/$EXE-x86_64"
rm -f "build/$EXE-arm64" "build/$EXE-x86_64"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/game.html "$APP/Contents/Resources/game.html"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)"
fi
if [[ -n "$identity" ]]; then
  stamp="--timestamp=none"
  [[ "$identity" == Developer\ ID* ]] && stamp="--timestamp"
  codesign --force --options runtime "$stamp" --sign "$identity" "$APP" >/dev/null
  echo "Signed with $identity"
else
  codesign --force --sign - "$APP" >/dev/null
  echo "Signed ad-hoc: turn Orbit Pointer off and on in Accessibility after each rebuild."
fi

echo "Built $APP"
case "${1:-}" in
  run)
    pkill -x "$EXE" 2>/dev/null || true
    pkill -x AimMac 2>/dev/null || true
    open "$APP"
    ;;
  install)
    pkill -x "$EXE" 2>/dev/null || true
    pkill -x AimMac 2>/dev/null || true
    rm -rf "/Applications/$NAME.app"
    cp -R "$APP" "/Applications/$NAME.app"
    open "/Applications/$NAME.app"
    echo "Installed to /Applications/$NAME.app"
    ;;
esac
