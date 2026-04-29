#!/bin/bash
#
# Wraps the SwiftPM `swift build` output for the Hydra macOS executable into a
# proper `.app` bundle so the dock can pick up the AppIcon, the menu-bar
# popover finds its main window, and Launch Services treats it as a UI app
# rather than a CLI tool.
#
# SwiftPM produces:
#   .build/<triple>/<config>/Hydra              (the executable)
#   .build/<triple>/<config>/Hydra_Hydra.bundle (resources, including
#                                                 compiled Assets.car)
#
# `Hydra.app/Contents/Resources/Assets.car` is what macOS reads to resolve
# `CFBundleIconName=AppIcon` from Info.plist into the actual icon image, so we
# also lift Assets.car directly into the .app's Resources/ alongside the
# nested resource bundle that `Bundle.module` looks up at runtime.
#
# Usage:
#   ./scripts/bundle-app.sh [debug|release]   (default: release)
#
set -euo pipefail

CONFIG="${1:-release}"
case "$CONFIG" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

cd "$(dirname "$0")/.."

echo "[1/5] swift build -c $CONFIG"
swift build -c "$CONFIG" --product Hydra

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
EXECUTABLE="$BIN_DIR/Hydra"
RESOURCE_BUNDLE="$BIN_DIR/Hydra_Hydra.bundle"

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "executable not found at $EXECUTABLE" >&2
    exit 1
fi

APP="$BIN_DIR/Hydra.app"
echo "[2/5] assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$EXECUTABLE" "$APP/Contents/MacOS/Hydra"

# Copy Info.plist last so Spotlight metadata is correct on first import.
cp "Info.plist" "$APP/Contents/Info.plist"

if [[ -d "$RESOURCE_BUNDLE" ]]; then
    echo "[3/5] copying resource bundle"
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
    # Lift compiled asset catalog to the .app level so the OS finds AppIcon
    # via CFBundleIconName without descending into a nested SPM resource bundle.
    if [[ -f "$RESOURCE_BUNDLE/Contents/Resources/Assets.car" ]]; then
        cp "$RESOURCE_BUNDLE/Contents/Resources/Assets.car" "$APP/Contents/Resources/Assets.car"
    fi
fi

# touch the bundle so Launch Services re-reads it on next open
touch "$APP"

echo "[4/5] ad-hoc code sign"
codesign --force --deep --sign - "$APP" >/dev/null

echo "[5/5] done"
echo
echo "  $APP"
echo "  open \"$APP\""
