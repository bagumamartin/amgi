#!/bin/bash
# Build the ijuka-mcp helper (release) and install it to ~/bin.
#
# The MCP server is a plain stdio executable spawned by AI clients.
# Re-run after pulling engine changes (any anki-bridge-rs /
# anki-upstream change requires ./scripts/build-xcframework.sh first).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${IJUKA_MCP_INSTALL_DIR:-$HOME/bin}"
INSTALL_PATH="$INSTALL_DIR/ijuka-mcp"

cd "$ROOT_DIR"
echo "==> Building ijuka-mcp (release, macOS)..."
xcodebuild -project AmgiApp/AmgiApp.xcodeproj -target IjukaMCPHelper \
  -configuration Release -sdk macosx \
  CONFIGURATION_BUILD_DIR="$ROOT_DIR/AmgiApp/build/MCPStandalone" \
  CODE_SIGN_ENTITLEMENTS= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ENABLE_APP_SANDBOX=NO ENABLE_HARDENED_RUNTIME=YES \
  'LD_RUNPATH_SEARCH_PATHS=$(inherited) @executable_path/ijuka-mcp-runtime' build

# Keep the standalone binary and its Rust dependency together. Sign the
# framework with the exact certificate used by Xcode for the executable,
# so Hardened Runtime library validation accepts it.
BUILD_DIR="$ROOT_DIR/AmgiApp/build/MCPStandalone"
RUNTIME_DIR="$BUILD_DIR/ijuka-mcp-runtime"
mkdir -p "$RUNTIME_DIR"
cp -R "$BUILD_DIR/AnkiRustLib.framework" "$RUNTIME_DIR/"
codesign --display --extract-certificates="$BUILD_DIR/signing-cert-" "$BUILD_DIR/ijuka-mcp"
SIGN_IDENTITY="$(shasum -a 1 "$BUILD_DIR/signing-cert-0" | cut -d ' ' -f 1)"
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$RUNTIME_DIR/AnkiRustLib.framework"
codesign --verify --strict "$RUNTIME_DIR/AnkiRustLib.framework"
codesign --verify --strict "$BUILD_DIR/ijuka-mcp"
"$BUILD_DIR/ijuka-mcp" --help >/dev/null

mkdir -p "$INSTALL_DIR/ijuka-mcp-runtime"
cp -R "$RUNTIME_DIR/AnkiRustLib.framework" "$INSTALL_DIR/ijuka-mcp-runtime/"
cp "$BUILD_DIR/ijuka-mcp" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"
"$INSTALL_PATH" --help >/dev/null

echo "==> Installed: $INSTALL_PATH"
echo ""
echo "Register with your clients:"
echo "  Claude Desktop : add {\"mcpServers\":{\"ijuka\":{\"command\":\"$INSTALL_PATH\"}}} to claude_desktop_config.json"
echo "  Claude Code    : claude mcp add ijuka -- $INSTALL_PATH"
echo "  Cursor         : {\"mcpServers\":{\"ijuka\":{\"command\":\"$INSTALL_PATH\"}}} in .cursor/mcp.json"
echo "  Codex CLI      : codex mcp add ijuka -- $INSTALL_PATH"
echo ""
echo "Test interactively with the MCP Inspector:"
echo "  npx @modelcontextprotocol/inspector $INSTALL_PATH"
