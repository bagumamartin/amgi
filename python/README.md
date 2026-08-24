# amgi-mcp (Python shim for `uvx`)

This is a tiny Python wrapper that makes the Amgi MCP server runnable via [`uvx`](https://docs.astral.sh/uv/guides/tools/#running-tools-with-uvx) — the pattern many MCP clients expect:

```
Command: uvx
Parameters: amgi-mcp
```

The Swift helper is still the real server; this package just finds the bundled binary at `/Applications/AmgiApp.app/Contents/Helpers/amgi-mcp` (or the dev helpers in `~/bin`, `/usr/local/bin`, `DerivedData`) and `exec`s it, forwarding stdio.

## Install / run

```sh
# Try without installing (uv will fetch from PyPI once published):
uvx amgi-mcp --help

# Or install as a persistent tool:
uv tool install amgi-mcp
amgi-mcp --help
```

Local development (no PyPI):

```sh
uvx --from ./python amgi-mcp --help
uv tool install --from ./python amgi-mcp
```

All arguments are passed through, so tier/profile flags still work:

```sh
amgi-mcp --help
amgi-mcp --profile work
```
