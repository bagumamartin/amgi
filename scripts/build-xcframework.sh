#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BRIDGE_DIR="$ROOT_DIR/anki-bridge-rs"
OUTPUT_DIR="$ROOT_DIR/AnkiRustLib.xcframework"
HEADER_DIR="$BRIDGE_DIR/include"

export PROTOC="${PROTOC:-$(which protoc 2>/dev/null || echo /opt/homebrew/bin/protoc)}"
export IPHONEOS_DEPLOYMENT_TARGET="17.0"
export WATCHOS_DEPLOYMENT_TARGET="11.0"
export MACOSX_DEPLOYMENT_TARGET="15.0"

# The rslib build script decodes a serialized proto DescriptorPool. Upstream
# resolves it via .cargo/config (DESCRIPTORS_BIN=out/rslib/proto/..., relative
# to anki-upstream/) — but that config only loads when cargo runs from inside
# anki-upstream/, and this script runs from the repo root, so the lookup falls
# back to a cargo-OUT_DIR sibling that only exists after a previous successful
# build. Fresh clones (and fresh fingerprints, e.g. the nightly watchOS leg)
# then fail with "No such file or directory" in the build script. Generate the
# descriptors deterministically with system protoc and export the override, so
# every leg resolves the same file regardless of cache state.
DESCRIPTORS_BIN_PATH="$ROOT_DIR/anki-upstream/out/rslib/proto/descriptors.bin"
echo "==> Generating proto descriptors..."
mkdir -p "$(dirname "$DESCRIPTORS_BIN_PATH")"
"$PROTOC" \
    --proto_path="$ROOT_DIR/anki-upstream/proto" \
    --descriptor_set_out="$DESCRIPTORS_BIN_PATH" \
    --include_imports \
    "$ROOT_DIR"/anki-upstream/proto/anki/*.proto
export DESCRIPTORS_BIN="$DESCRIPTORS_BIN_PATH"
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

DEVICE_LIB="$BRIDGE_DIR/target/aarch64-apple-ios/release/libanki_bridge_ios.dylib"
SIM_LIB="$BRIDGE_DIR/target/aarch64-apple-ios-sim/release/libanki_bridge_ios.dylib"

[ -f "$DEVICE_LIB" ] || { echo "ERROR: device lib not found at $DEVICE_LIB"; exit 1; }
[ -f "$SIM_LIB" ] || { echo "ERROR: simulator lib not found at $SIM_LIB"; exit 1; }

echo "==> Device lib: $(du -h "$DEVICE_LIB" | cut -f1)"
echo "==> Simulator lib: $(du -h "$SIM_LIB" | cut -f1)"

# NOTE: crate-type must stay cdylib (see anki-bridge-rs/Cargo.toml). The
# xcframework ships one dynamic AnkiRustLib.framework per slice: package
# previews (XCPreviewAgent, no app host) resolve the anki_* FFI symbols only
# from a dylib — a static archive fails them with "Symbols not found".
STAGE_DIR="$BRIDGE_DIR/target/xcframework-staging"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# make_framework <slice-dir> <dylib> <platform> <min-version> [versioned]
# Lays out AnkiRustLib.framework mirroring the last known-good artifact:
# flat for iOS/watchOS, macOS-versioned (Versions/A + Current symlinks).
make_framework() {
    local slice_dir="$1" dylib="$2" platform="$3" min_version="$4" versioned="${5:-}"
    local fw="$STAGE_DIR/$slice_dir/AnkiRustLib.framework"
    if [ -n "$versioned" ]; then
        local vdir="$fw/Versions/A"
        mkdir -p "$vdir/Headers" "$vdir/Modules" "$vdir/Resources"
        cp "$dylib" "$vdir/AnkiRustLib"
        chmod +x "$vdir/AnkiRustLib"
        cp "$HEADER_DIR/anki_bridge.h" "$vdir/Headers/"
        write_modulemap "$vdir/Modules/module.modulemap"
        write_info_plist "$vdir/Resources/Info.plist" "$platform" "$min_version"
        cp "$vdir/Resources/Info.plist" "$fw/Resources/Info.plist" 2>/dev/null || {
            mkdir -p "$fw/Resources"
            cp "$vdir/Resources/Info.plist" "$fw/Resources/Info.plist"
        }
        ln -s Versions/Current/AnkiRustLib "$fw/AnkiRustLib"
        ln -s Versions/A/Headers "$fw/Headers"
        ln -s Versions/A/Modules "$fw/Modules"
        ln -s Versions/A/Resources "$fw/Resources"
        ln -s A "$fw/Versions/Current"
    else
        mkdir -p "$fw/Headers" "$fw/Modules"
        cp "$dylib" "$fw/AnkiRustLib"
        chmod +x "$fw/AnkiRustLib"
        cp "$HEADER_DIR/anki_bridge.h" "$fw/Headers/"
        write_modulemap "$fw/Modules/module.modulemap"
        write_info_plist "$fw/Info.plist" "$platform" "$min_version"
    fi
}

write_modulemap() {
    cat > "$1" <<'MODULEMAP'
framework module AnkiRustLib {
    header "anki_bridge.h"
    export *
}
MODULEMAP
}

write_info_plist() {
    local plist="$1" platform="$2" min_version="$3"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>AnkiRustLib</string>
    <key>CFBundleIdentifier</key><string>com.amgi.AnkiRustLib</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>AnkiRustLib</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
    <key>MinimumOSVersion</key><string>$min_version</string>
</dict>
</plist>
PLIST
}

make_framework "ios-arm64" "$DEVICE_LIB" "iPhoneOS" "$IPHONEOS_DEPLOYMENT_TARGET"
make_framework "ios-arm64-simulator" "$SIM_LIB" "iPhoneSimulator" "$IPHONEOS_DEPLOYMENT_TARGET"

XCFRAMEWORK_ARGS=(
    -framework "$STAGE_DIR/ios-arm64/AnkiRustLib.framework"
    -framework "$STAGE_DIR/ios-arm64-simulator/AnkiRustLib.framework"
)

if [ "$BUILD_WATCHOS" = "1" ]; then
    WATCH_SIM_LIB="$BRIDGE_DIR/target/aarch64-apple-watchos-sim/release/libanki_bridge_ios.dylib"
    [ -f "$WATCH_SIM_LIB" ] || { echo "ERROR: watch simulator lib not found at $WATCH_SIM_LIB"; exit 1; }
    echo "==> Watch simulator lib: $(du -h "$WATCH_SIM_LIB" | cut -f1)"
    make_framework "watchos-arm64-simulator" "$WATCH_SIM_LIB" "WatchSimulator" "$WATCHOS_DEPLOYMENT_TARGET"
    XCFRAMEWORK_ARGS+=( -framework "$STAGE_DIR/watchos-arm64-simulator/AnkiRustLib.framework" )
fi

if [ "$BUILD_MACOS" = "1" ]; then
    MAC_ARM_LIB="$BRIDGE_DIR/target/aarch64-apple-darwin/release/libanki_bridge_ios.dylib"
    MAC_X86_LIB="$BRIDGE_DIR/target/x86_64-apple-darwin/release/libanki_bridge_ios.dylib"
    [ -f "$MAC_ARM_LIB" ] || { echo "ERROR: macOS arm64 lib not found at $MAC_ARM_LIB"; exit 1; }
    [ -f "$MAC_X86_LIB" ] || { echo "ERROR: macOS x86_64 lib not found at $MAC_X86_LIB"; exit 1; }
    MAC_UNIVERSAL_DIR="$BRIDGE_DIR/target/universal-apple-darwin/release"
    mkdir -p "$MAC_UNIVERSAL_DIR"
    lipo -create "$MAC_ARM_LIB" "$MAC_X86_LIB" -output "$MAC_UNIVERSAL_DIR/libanki_bridge_ios.dylib"
    MAC_LIB="$MAC_UNIVERSAL_DIR/libanki_bridge_ios.dylib"
    echo "==> macOS universal lib: $(du -h "$MAC_LIB" | cut -f1)"
    make_framework "macos-arm64_x86_64" "$MAC_LIB" "MacOSX" "$MACOSX_DEPLOYMENT_TARGET" versioned
    XCFRAMEWORK_ARGS+=( -framework "$STAGE_DIR/macos-arm64_x86_64/AnkiRustLib.framework" )
fi

echo "==> Packaging XCFramework..."
rm -rf "$OUTPUT_DIR"

xcodebuild -create-xcframework \
    "${XCFRAMEWORK_ARGS[@]}" \
    -output "$OUTPUT_DIR"

# xcodebuild derives the mac slice identifier from the framework's single
# arch (macos-arm64) even for a universal binary — fix it up to the
# conventional macos-arm64_x86_64 with both architectures listed.
if [ "$BUILD_MACOS" = "1" ]; then
    python3 - "$OUTPUT_DIR/Info.plist" <<'PYEOF'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    info = plistlib.load(f)
for lib in info['AvailableLibraries']:
    if lib['LibraryIdentifier'] == 'macos-arm64':
        lib['LibraryIdentifier'] = 'macos-arm64_x86_64'
        lib['SupportedArchitectures'] = ['arm64', 'x86_64']
with open(path, 'wb') as f:
    plistlib.dump(info, f)
print("patched mac slice identifier to macos-arm64_x86_64")
PYEOF
fi

echo "==> Done! XCFramework at: $OUTPUT_DIR"
echo "==> Contents:"
find "$OUTPUT_DIR" -type f | head -15
