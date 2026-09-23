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
  CONFIGURATION_BUILD_DIR="$ROOT_DIR/AmgiApp/build/Release" build

mkdir -p "$INSTALL_DIR"
cp "AmgiApp/build/Release/ijuka-mcp" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

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
