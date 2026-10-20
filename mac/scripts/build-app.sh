#!/bin/bash
# Builds Satsuma.app (Apple silicon + Intel) and Satsuma-<version>-mac.dmg in mac/build.
#
#   scripts/build-app.sh                 ad hoc signed (Gatekeeper asks once, see the README)
#   SIGN_ID="Developer ID Application: Name (TEAMID)" scripts/build-app.sh
#                                        signed with your Developer ID and the hardened runtime
#   NOTARY_PROFILE=satsuma scripts/build-app.sh
#                                        also notarizes and staples (xcrun notarytool store-credentials first)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
OUT=build
APP="$OUT/Satsuma.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Building Satsuma $VERSION (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Satsuma"
cp "$BIN" "$APP/Contents/MacOS/Satsuma"
lipo -info "$APP/Contents/MacOS/Satsuma"

sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The icon is drawn by the app itself.
"$APP/Contents/MacOS/Satsuma" --make-icon "$OUT/Satsuma.iconset" > /dev/null
iconutil -c icns "$OUT/Satsuma.iconset" -o "$APP/Contents/Resources/Satsuma.icns"
rm -rf "$OUT/Satsuma.iconset"
cp ../LICENSE "$APP/Contents/Resources/LICENSE.txt"
mkdir -p "$APP/Contents/Resources/Licenses"
cp ../THIRD-PARTY-NOTICES.txt "$APP/Contents/Resources/Licenses/THIRD-PARTY-NOTICES.txt"
cp Sources/CWebP/COPYING "$APP/Contents/Resources/Licenses/libwebp-COPYING.txt"
cp Sources/CWebP/PATENTS "$APP/Contents/Resources/Licenses/libwebp-PATENTS.txt"

if [ -n "${SIGN_ID:-}" ]; then
    codesign --force --options runtime --timestamp --entitlements Resources/Satsuma.entitlements --sign "$SIGN_ID" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --verbose=2 "$APP"

# Disk image with an Applications shortcut to drag onto.
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Satsuma-$VERSION-mac.dmg"
hdiutil create -volname "Satsuma" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"
if [ -n "${SIGN_ID:-}" ]; then codesign --force --sign "$SIGN_ID" "$DMG"; fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi
echo "Wrote $DMG"
