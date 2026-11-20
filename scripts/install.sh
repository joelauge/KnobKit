#!/bin/bash
# Builds KnobKit, installs it to /Applications (replacing a previous install) and
# launches it. Set KNOBKIT_INSTALL_DIR to install somewhere else.
#
# The copy in build/ is removed afterwards so macOS only ever sees one KnobKit:
# two bundles with the same identifier confuse login items and `open`.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${KNOBKIT_INSTALL_DIR:-/Applications}/KnobKit.app"

scripts/build.sh release

# Only ever replace our own app.
if [ -e "$DEST" ]; then
  EXISTING="$(defaults read "$DEST/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
  if [ "$EXISTING" != "com.knobkit.app" ]; then
    echo "Refusing to replace $DEST: it is not KnobKit (bundle id: ${EXISTING:-unknown})." >&2
    exit 1
  fi
fi

# Quit a running copy, wherever it was launched from, before swapping the bundle.
pkill -x KnobKit 2>/dev/null || true
sleep 0.6

rm -rf "$DEST"
ditto build/KnobKit.app "$DEST"
rm -rf build/KnobKit.app

open "$DEST"
echo "Installed and launched $DEST"
