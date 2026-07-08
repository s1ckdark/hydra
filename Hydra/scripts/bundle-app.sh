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

echo "[1/7] swift build -c $CONFIG"
swift build -c "$CONFIG" --product Hydra

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
EXECUTABLE="$BIN_DIR/Hydra"
RESOURCE_BUNDLE="$BIN_DIR/Hydra_Hydra.bundle"

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "executable not found at $EXECUTABLE" >&2
    exit 1
fi

APP="$BIN_DIR/Hydra.app"
echo "[2/7] assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$EXECUTABLE" "$APP/Contents/MacOS/Hydra"

# Copy Info.plist last so Spotlight metadata is correct on first import.
cp "Info.plist" "$APP/Contents/Info.plist"

if [[ -d "$RESOURCE_BUNDLE" ]]; then
    echo "[3/7] copying resource bundle"
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
fi

echo "[4/7] compiling Assets.car via actool"
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

echo "[5/7] go build hydra-server (embedded backend)"
# The Hydra menu-bar app spawns this binary at launch so the user does not
# have to run `make run-server` separately. cmd/server lives at the repo
# root (one level above this Hydra/ working dir).
SERVER_BIN="$APP/Contents/Resources/hydra-server"
(cd .. && go build -o "$SERVER_BIN" ./cmd/server)
chmod +x "$SERVER_BIN"

echo "[5b/7] bundle Python runtime + vendored hydra_client"
# python-build-standalone (macOS arm64, install_only). PBS_TAG/PBS_FILE 는
# releases 페이지에서 확인한 현재 유효한 값으로 설정할 것.
PBS_TAG="${PBS_TAG:-20260623}"
PBS_FILE="${PBS_FILE:-cpython-3.12.13+20260623-aarch64-apple-darwin-install_only.tar.gz}"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_FILE}"
PBS_CACHE="${PBS_CACHE:-$HOME/.cache/hydra-pbs}"
mkdir -p "$PBS_CACHE"
PBS_TARBALL="$PBS_CACHE/$PBS_FILE"

if [[ ! -f "$PBS_TARBALL" ]]; then
    echo "  downloading $PBS_URL"
    curl -fL --retry 3 -o "$PBS_TARBALL" "$PBS_URL" || { echo "PBS download failed: $PBS_URL" >&2; exit 1; }
fi

PY_DEST="$APP/Contents/Resources/python-runtime"
rm -rf "$PY_DEST"
mkdir -p "$PY_DEST"
# install_only tarball 은 최상위 'python/' 디렉터리로 전개된다 → 그 내용을 python-runtime/ 로.
tar -xzf "$PBS_TARBALL" -C "$PBS_CACHE/extract-$$" --one-top-level 2>/dev/null || {
    mkdir -p "$PBS_CACHE/extract-$$"; tar -xzf "$PBS_TARBALL" -C "$PBS_CACHE/extract-$$"; }
# 전개 결과 python/ 하위를 python-runtime 으로 이동, bin/python3 심볼릭 정규화
if [[ -d "$PBS_CACHE/extract-$$/python" ]]; then
    cp -R "$PBS_CACHE/extract-$$/python/." "$PY_DEST/"
else
    cp -R "$PBS_CACHE/extract-$$/." "$PY_DEST/"
fi
rm -rf "$PBS_CACHE/extract-$$"
# bin/python3 이 실제 실행 가능해야 한다 (install_only 는 bin/python3.x + python3 심볼릭 제공)
if [[ ! -x "$PY_DEST/bin/python3" ]]; then
    # python3.x 만 있으면 python3 심볼릭 생성
    PYBIN="$(ls "$PY_DEST"/bin/python3.* 2>/dev/null | head -1)"
    [[ -n "$PYBIN" ]] && ln -sf "$(basename "$PYBIN")" "$PY_DEST/bin/python3"
fi
[[ -x "$PY_DEST/bin/python3" ]] || { echo "python-runtime/bin/python3 not executable after extract" >&2; exit 1; }

# 벤더링: hydra_client 소스를 Resources/pylib/ 로 복사 (repo 루트 기준 ../python/src)
PYLIB_DEST="$APP/Contents/Resources/pylib"
rm -rf "$PYLIB_DEST"
mkdir -p "$PYLIB_DEST"
cp -R "../python/src/hydra_client" "$PYLIB_DEST/hydra_client"
# 벤더 라이브러리의 런타임 의존성(requests, websockets)은 번들 파이썬에 설치
"$PY_DEST/bin/python3" -m pip install --quiet --target "$PYLIB_DEST" "requests>=2.31" "websockets>=12" \
    || { echo "pip install into pylib failed" >&2; exit 1; }

# touch the bundle so Launch Services re-reads it on next open
touch "$APP"

# Code-signing identity. A STABLE identity (e.g. "Apple Development: …") keeps
# the app's designated requirement constant across rebuilds, so macOS Keychain
# "Always Allow" grants persist instead of re-prompting on every build. Ad-hoc
# ("-") signing changes the cdhash each build, which invalidates those grants.
#
# Resolution order:
#   1. $CODESIGN_IDENTITY if exported (full name or SHA-1 hash)
#   2. first "Apple Development" / "Developer ID Application" identity found
#   3. ad-hoc ("-") fallback when no real identity exists (CI, fresh checkout)
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$CODESIGN_IDENTITY" ]]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
fi
[[ -z "$CODESIGN_IDENTITY" ]] && CODESIGN_IDENTITY="-"

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "[6/7] ad-hoc code sign (no stable identity — Keychain re-prompts each build)"
else
    echo "[6/7] code sign: $CODESIGN_IDENTITY"
fi
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP" >/dev/null

echo "[7/7] done"
echo
echo "  $APP"
echo "  open \"$APP\""
