#!/bin/bash
#
# Wraps the SwiftPM `swift build` output for the Hydra macOS executable into a
# proper `.app` bundle so the dock can pick up the AppIcon, the menu-bar
# popover finds its main window, and Launch Services treats it as a UI app
# rather than a CLI tool.
#
# SwiftPM produces:
#   .build/<triple>/<config>/Hydra              (the executable)
#   .build/<triple>/<config>/Hydra_Hydra.bundle (raw resources — Xcode would
#                                                 also compile Assets.xcassets
#                                                 into Assets.car here, but
#                                                 SwiftPM does NOT, so we run
#                                                 actool ourselves below)
#
# `Hydra.app/Contents/Resources/Assets.car` is what macOS reads to resolve
# `CFBundleIconName=AppIcon` from Info.plist into the actual icon image, so we
# compile the xcassets via `actool` and drop the result directly into the
# .app's Resources/ alongside the nested SPM resource bundle that
# `Bundle.module` looks up at runtime.
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

echo "[1/6] swift build -c $CONFIG"
swift build -c "$CONFIG" --product Hydra

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
EXECUTABLE="$BIN_DIR/Hydra"
RESOURCE_BUNDLE="$BIN_DIR/Hydra_Hydra.bundle"

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "executable not found at $EXECUTABLE" >&2
    exit 1
fi

APP="$BIN_DIR/Hydra.app"
echo "[2/6] assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$EXECUTABLE" "$APP/Contents/MacOS/Hydra"

# Copy Info.plist last so Spotlight metadata is correct on first import.
cp "Info.plist" "$APP/Contents/Info.plist"

if [[ -d "$RESOURCE_BUNDLE" ]]; then
    echo "[3/6] copying resource bundle"
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
fi

echo "[4/6] compiling Assets.car via actool"
XCASSETS="Hydra/Assets.xcassets"
if [[ -d "$XCASSETS" ]]; then
    ACTOOL_OUT="$(mktemp -d)"
    # macOS-only build; --app-icon ties the catalog's AppIcon set to the
    # CFBundleIconName key in Info.plist. --output-partial-info-plist is
    # required by actool even though we don't merge it back.
    actool "$XCASSETS" \
        --compile "$ACTOOL_OUT" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$ACTOOL_OUT/Info.partial.plist" \
        >/dev/null
    if [[ -f "$ACTOOL_OUT/Assets.car" ]]; then
        cp "$ACTOOL_OUT/Assets.car" "$APP/Contents/Resources/Assets.car"
    else
        echo "warning: actool produced no Assets.car — icon will be missing" >&2
    fi
    rm -rf "$ACTOOL_OUT"
else
    echo "warning: $XCASSETS not found — skipping icon compile" >&2
fi

# touch the bundle so Launch Services re-reads it on next open
touch "$APP"

echo "[5/6] ad-hoc code sign"
codesign --force --deep --sign - "$APP" >/dev/null

echo "[6/6] done"
echo
echo "  $APP"
echo "  open \"$APP\""
