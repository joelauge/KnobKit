#!/bin/bash
# Builds the KnobKit download: a universal app signed with a Developer ID certificate
# and the hardened runtime, inside a signed disk image, notarized by Apple.
#
#   scripts/package.sh
#
# Result: dist/KnobKit-<version>.dmg
#
# Environment:
#   KNOBKIT_DEVELOPER_ID     Signing identity. Default: the first "Developer ID
#                            Application" certificate in the keychain.
#   KNOBKIT_NOTARY_PROFILE   notarytool keychain profile. Default: knobkit. Create it
#                            once with:
#                              xcrun notarytool store-credentials knobkit \
#                                --apple-id <Apple ID> --team-id <Team ID>
#                            (it asks for an app-specific password from
#                            account.apple.com).
#   KNOBKIT_SKIP_NOTARIZE=1  Stop after signing. The image then opens only after the
#                            person approves it in System Settings.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
PROFILE="${KNOBKIT_NOTARY_PROFILE:-knobkit}"
DIST="dist"
APP="$DIST/KnobKit.app"
DMG="$DIST/KnobKit-$VERSION.dmg"

IDENTITY="${KNOBKIT_DEVELOPER_ID:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi
if [ -z "$IDENTITY" ]; then
  echo "No Developer ID Application certificate in the keychain. Set KNOBKIT_DEVELOPER_ID." >&2
  exit 1
fi

echo "== Building universal binary"
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
# The output folder differs between toolchains, so ask for it.
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/KnobKit"

echo "== Assembling $APP"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/KnobKit"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "== Signing with the hardened runtime"
codesign --force --timestamp --options runtime \
  --entitlements Resources/KnobKit.entitlements \
  --sign "$IDENTITY" --identifier com.knobkit.app "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "== Building $DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/KnobKit.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "KnobKit $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "${KNOBKIT_SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "Signed, not notarized: $DMG"
  exit 0
fi

echo "== Notarizing (profile: $PROFILE)"
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No usable notarytool profile named \"$PROFILE\". Create it (see the top of this" >&2
  echo "script), then run scripts/package.sh again. Signed, not notarized: $DMG" >&2
  exit 2
fi
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "Signed and notarized: $DMG"
shasum -a 256 "$DMG"
