#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BRIDGE_DIR="$ROOT_DIR/anki-bridge-rs"
OUTPUT_DIR="$ROOT_DIR/AnkiRust.xcframework"
HEADER_DIR="$BRIDGE_DIR/include"

export PROTOC="${PROTOC:-$(which protoc 2>/dev/null || echo /opt/homebrew/bin/protoc)}"
export IPHONEOS_DEPLOYMENT_TARGET="17.0"
export WATCHOS_DEPLOYMENT_TARGET="11.0"
export MACOSX_DEPLOYMENT_TARGET="15.0"
BUILD_WATCHOS="${BUILD_WATCHOS:-0}"
# macOS slices are tier-1 Rust targets (no nightly/build-std needed), so they
# build by default; set BUILD_MACOS=0 to skip them for iOS-only loops.
BUILD_MACOS="${BUILD_MACOS:-1}"

# watchOS is a tier-3 Rust target: std isn't distributed, so we build it from
# source with -Z build-std on nightly. Requires: rustup toolchain install nightly
# && rustup component add rust-src --toolchain nightly.
NIGHTLY="${NIGHTLY_TOOLCHAIN:-nightly}"

echo "==> Using protoc: $PROTOC"
echo "==> Deployment target: iOS $IPHONEOS_DEPLOYMENT_TARGET"
if [ "$BUILD_WATCHOS" = "1" ]; then
    echo "==> watchOS simulator build enabled (deployment target: $WATCHOS_DEPLOYMENT_TARGET)"
else
    echo "==> watchOS simulator build disabled (set BUILD_WATCHOS=1 to enable)"
fi
if [ "$BUILD_MACOS" = "1" ]; then
    echo "==> macOS build enabled (deployment target: $MACOSX_DEPLOYMENT_TARGET)"
else
    echo "==> macOS build disabled (set BUILD_MACOS=1 to enable)"
fi
echo "==> Building for iOS device (aarch64-apple-ios)..."
cargo build \
    --manifest-path "$BRIDGE_DIR/Cargo.toml" \
    --target aarch64-apple-ios \
    --release

echo "==> Building for iOS simulator (aarch64-apple-ios-sim)..."
cargo build \
    --manifest-path "$BRIDGE_DIR/Cargo.toml" \
    --target aarch64-apple-ios-sim \
    --release

if [ "$BUILD_MACOS" = "1" ]; then
    echo "==> Building for macOS (aarch64-apple-darwin)..."
    cargo build \
        --manifest-path "$BRIDGE_DIR/Cargo.toml" \
        --target aarch64-apple-darwin \
        --release

    echo "==> Building for macOS (x86_64-apple-darwin)..."
    cargo build \
        --manifest-path "$BRIDGE_DIR/Cargo.toml" \
        --target x86_64-apple-darwin \
        --release
fi

if [ "$BUILD_WATCHOS" = "1" ]; then
    echo "==> Building for watchOS simulator (aarch64-apple-watchos-sim, build-std)..."
    # ponytail: sim slice only. The watchOS *device* target is arm64_32-apple-watchos
    # (ILP32); add it here the same way once a physical-watch build is actually needed.
    cargo "+$NIGHTLY" build \
        -Z build-std=std,panic_abort \
        --manifest-path "$BRIDGE_DIR/Cargo.toml" \
        --target aarch64-apple-watchos-sim \
        --release
fi

DEVICE_LIB="$BRIDGE_DIR/target/aarch64-apple-ios/release/libanki_bridge_ios.a"
SIM_LIB="$BRIDGE_DIR/target/aarch64-apple-ios-sim/release/libanki_bridge_ios.a"

[ -f "$DEVICE_LIB" ] || { echo "ERROR: device lib not found at $DEVICE_LIB"; exit 1; }
[ -f "$SIM_LIB" ] || { echo "ERROR: simulator lib not found at $SIM_LIB"; exit 1; }

echo "==> Device lib: $(du -h "$DEVICE_LIB" | cut -f1)"
echo "==> Simulator lib: $(du -h "$SIM_LIB" | cut -f1)"

XCFRAMEWORK_ARGS=(
    -library "$DEVICE_LIB" -headers "$HEADER_DIR"
    -library "$SIM_LIB" -headers "$HEADER_DIR"
)

if [ "$BUILD_WATCHOS" = "1" ]; then
    WATCH_SIM_LIB="$BRIDGE_DIR/target/aarch64-apple-watchos-sim/release/libanki_bridge_ios.a"
    [ -f "$WATCH_SIM_LIB" ] || { echo "ERROR: watch simulator lib not found at $WATCH_SIM_LIB"; exit 1; }
    echo "==> Watch simulator lib: $(du -h "$WATCH_SIM_LIB" | cut -f1)"
    XCFRAMEWORK_ARGS+=( -library "$WATCH_SIM_LIB" -headers "$HEADER_DIR" )
fi

if [ "$BUILD_MACOS" = "1" ]; then
    MAC_ARM_LIB="$BRIDGE_DIR/target/aarch64-apple-darwin/release/libanki_bridge_ios.a"
    MAC_X86_LIB="$BRIDGE_DIR/target/x86_64-apple-darwin/release/libanki_bridge_ios.a"
    [ -f "$MAC_ARM_LIB" ] || { echo "ERROR: macOS arm64 lib not found at $MAC_ARM_LIB"; exit 1; }
    [ -f "$MAC_X86_LIB" ] || { echo "ERROR: macOS x86_64 lib not found at $MAC_X86_LIB"; exit 1; }
    MAC_UNIVERSAL_DIR="$BRIDGE_DIR/target/universal-apple-darwin/release"
    mkdir -p "$MAC_UNIVERSAL_DIR"
    lipo -create "$MAC_ARM_LIB" "$MAC_X86_LIB" -output "$MAC_UNIVERSAL_DIR/libanki_bridge_ios.a"
    MAC_LIB="$MAC_UNIVERSAL_DIR/libanki_bridge_ios.a"
    echo "==> macOS universal lib: $(du -h "$MAC_LIB" | cut -f1)"
    XCFRAMEWORK_ARGS+=( -library "$MAC_LIB" -headers "$HEADER_DIR" )
fi

echo "==> Packaging XCFramework..."
rm -rf "$OUTPUT_DIR"

xcodebuild -create-xcframework \
    "${XCFRAMEWORK_ARGS[@]}" \
    -output "$OUTPUT_DIR"

echo "==> Adding module maps..."
for HEADERS in "$OUTPUT_DIR"/*/Headers; do
    cat > "$HEADERS/module.modulemap" <<'MODULEMAP'
module AnkiRustLib {
    header "anki_bridge.h"
    export *
}
MODULEMAP
done

echo "==> Done! XCFramework at: $OUTPUT_DIR"
echo "==> Contents:"
find "$OUTPUT_DIR" -type f | head -15
