#!/bin/bash
# Code-sign AnkiRustLib.xcframework: every framework slice, then the
# XCFramework itself.
#
# Run automatically at the end of ./scripts/build-xcframework.sh, and on its
# own to re-sign an existing XCFramework without rebuilding the Rust engine:
#
#   ./scripts/sign-xcframework.sh                      # default identity
#   CODESIGN_IDENTITY="Apple Development: …" ./scripts/sign-xcframework.sh
#   CODESIGN_IDENTITY=- ./scripts/sign-xcframework.sh  # ad hoc
#
# Why it must ship signed: on Apple Silicon, macOS refuses to load unsigned
# code. Apps re-sign the framework when they embed it, so they never noticed,
# but SwiftPM test bundles (AnkiClientsTests and friends) load it straight
# from the products directory and died with
#   Library not loaded: @rpath/AnkiRustLib.framework/AnkiRustLib
#   … not valid for use in process: Trying to load an unsigned library
#
# The identity defaults to the first "Apple Development" certificate in the
# keychain, falling back to ad hoc on a machine without one. Either is
# replaceable: Xcode re-signs the embedded framework with the app's own
# identity on build, archive and export, so App Store distribution is
# unaffected by which identity signed it here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
XCFRAMEWORK="${1:-$ROOT_DIR/AnkiRustLib.xcframework}"

[ -d "$XCFRAMEWORK" ] || { echo "ERROR: no XCFramework at $XCFRAMEWORK" >&2; exit 1; }

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
    CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
fi
echo "==> Signing with: $([ "$CODESIGN_IDENTITY" = "-" ] && echo "ad hoc" || echo "$CODESIGN_IDENTITY")"

found=0
while IFS= read -r -d '' framework; do
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp=none "$framework"
    codesign --verify --strict "$framework"
    echo "    signed $(basename "$(dirname "$framework")")"
    found=$((found + 1))
done < <(find "$XCFRAMEWORK" -mindepth 2 -maxdepth 2 -name "AnkiRustLib.framework" -print0)
[ "$found" -gt 0 ] || { echo "ERROR: no framework slices in $XCFRAMEWORK" >&2; exit 1; }

# Xcode verifies an XCFramework's own signature and shows its signer in the
# Inspector. An ad hoc signature has no signer to show, so skip it then.
if [ "$CODESIGN_IDENTITY" != "-" ]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp=none "$XCFRAMEWORK"
    codesign --verify --strict "$XCFRAMEWORK"
    echo "    signed $(basename "$XCFRAMEWORK")"
fi
