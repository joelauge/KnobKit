#!/bin/bash
# Builds KnobKit and assembles a signed .app bundle at build/KnobKit.app.
#
#   scripts/build.sh            release build
#   scripts/build.sh debug      debug build
#
# Signing: uses the first "Apple Development" identity in the keychain so that the
# Accessibility and Input Monitoring grants survive rebuilds (ad-hoc signatures change
# with every build and macOS then forgets the permissions). Override with
# KNOBKIT_SIGN_IDENTITY="<identity name or hash>", or set it to "-" for ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/KnobKit.app"

swift build -c "$CONFIG"

if [ ! -f Resources/AppIcon.icns ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift scripts/make-icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/KnobKit" "$APP/Contents/MacOS/KnobKit"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${KNOBKIT_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')"
fi
codesign --force --sign "${IDENTITY:--}" --identifier com.knobkit.app "$APP"

codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|TeamIdentifier|Signature)" || true
echo "Built $APP"
