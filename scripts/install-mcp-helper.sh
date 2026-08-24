#!/bin/bash
# Build the amgi-mcp helper (release) and install it to ~/bin.
#
# The MCP server is a plain stdio executable spawned by AI clients —
# it must exist OUTSIDE the .app bundle so clients can find a stable
# path. Re-run after pulling engine changes (any anki-bridge-rs /
# anki-upstream change requires ./scripts/build-xcframework.sh first).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${AMGI_MCP_INSTALL_DIR:-$HOME/bin}"
INSTALL_PATH="$INSTALL_DIR/amgi-mcp"

cd "$ROOT_DIR"
echo "==> Building amgi-mcp (release, macOS)..."
swift build -c release --product amgi-mcp

mkdir -p "$INSTALL_DIR"
cp ".build/release/amgi-mcp" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

echo "==> Installed: $INSTALL_PATH"
echo ""
echo "Register with your clients:"
echo "  Claude Desktop : add {\"mcpServers\":{\"amgi\":{\"command\":\"$INSTALL_PATH\"}}} to claude_desktop_config.json"
echo "  Claude Code    : claude mcp add amgi -- $INSTALL_PATH"
echo "  Cursor         : {\"mcpServers\":{\"amgi\":{\"command\":\"$INSTALL_PATH\"}}} in .cursor/mcp.json"
echo "  Codex CLI      : codex mcp add amgi -- $INSTALL_PATH"
echo ""
echo "Test interactively with the MCP Inspector:"
echo "  npx @modelcontextprotocol/inspector $INSTALL_PATH"
