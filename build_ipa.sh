#!/bin/bash
#
# build_ipa.sh — build Wandering and package an unsigned IPA.
#
# Unsigned on purpose: install with SideStore/AltStore/ESign using your own Apple
# ID. No entitlements beyond the standard free-profile set are required, because
# the developer tunnel is provided by an already-installed VPN app.
#
set -uo pipefail

PROJECT="Wandering.xcodeproj"
SCHEME="Wandering"
CONFIG="${CONFIG:-Release}"
BUILD_DIR="build"
LOG="$BUILD_DIR/build.log"

mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_DIR/DerivedData"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen missing — install with: brew install xcodegen" >&2
    exit 1
fi
xcodegen generate

if [ ! -f vendor/libidevice_ffi.a ]; then
    echo "vendor/libidevice_ffi.a missing — fetch the idevice FFI release into vendor/" >&2
    exit 1
fi

echo "=== Building ($CONFIG) ==="
set -o pipefail
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    2>&1 | tee "$LOG" | grep -E "(error:|warning: .*deprecated|BUILD SUCCEEDED|BUILD FAILED)" || true

if ! grep -q "BUILD SUCCEEDED" "$LOG"; then
    echo "Error: build failed. See $LOG" >&2
    tail -40 "$LOG" >&2
    exit 1
fi

APP="$(find "$BUILD_DIR/DerivedData/Build/Products" -name "Wandering.app" -type d | head -1)"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "Error: Wandering.app not found" >&2
    exit 1
fi
echo "Built: $APP"

rm -rf "$BUILD_DIR/Payload" "$BUILD_DIR/Wandering.ipa"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/Wandering.app"
(cd "$BUILD_DIR" && zip -q -r Wandering.ipa Payload)

echo "=== IPA ==="
ls -lh "$BUILD_DIR/Wandering.ipa"

mkdir -p "$BUILD_DIR/symbols"
find "$BUILD_DIR/DerivedData/Build/Products" -name "*.dSYM" -maxdepth 3 \
    -exec cp -R {} "$BUILD_DIR/symbols/" \; 2>/dev/null || true
