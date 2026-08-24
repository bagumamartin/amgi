# amgi-mcp (Python shim for `uvx`)

This is a tiny Python wrapper that makes the Amgi MCP server runnable via [`uvx`](https://docs.astral.sh/uv/guides/tools/#running-tools-with-uvx) — the pattern many MCP clients expect:

```
Command: uvx
Parameters: amgi-mcp
```

The Swift helper is still the real server; this package just finds the bundled binary at `/Applications/AmgiApp.app/Contents/Helpers/amgi-mcp` (or the dev helpers in `~/bin`, `/usr/local/bin`, `DerivedData`) and `exec`s it, forwarding stdio.

`uvx` (`uv tool run`) holds the uv cache lock for the lifetime of the server (`astral-sh/uv#15990`). With several clients all using `uvx` the spawns serialize and can hit the 10 s handshake timeout. For multi-client / daily use install once persistently.

## Install / run

```sh
# One-off / trial — no install, uses cached env after first run:
uvx amgi-mcp --help
# Pin for reproducibility:
uvx amgi-mcp==1.0.2 --help

# Daily / multi-client — persistent, fastest, no cache-lock contention:
uv tool install amgi-mcp
amgi-mcp --help

# Update the persistent install:
uv tool upgrade amgi-mcp
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

### Troubleshooting: `uvx` timeout or `Waiting to acquire lock`

If several AI clients launch `uvx amgi-mcp` at once and one times out, either switch that client to the persistent `amgi-mcp` command or re-run the failing `uvx` once - `uv cache` is shared and `uvx` retains a shared lock for the server lifetime. `uv tool install` avoids the lock entirely.
