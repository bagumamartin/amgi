# ijuka-mcp (Python shim for `uvx`)

This is a tiny Python wrapper that makes the Ijuka MCP server runnable via [`uvx`](https://docs.astral.sh/uv/guides/tools/#running-tools-with-uvx) — the pattern many MCP clients expect:

```
Command: uvx
Parameters: ijuka-mcp
```

The Swift helper is the real server. Install its standalone build from the repository with `./scripts/install-mcp-helper.sh` first. This package finds it in `~/bin` or `/usr/local/bin` and `exec`s it, forwarding stdio. `IJUKA_MCP_HELPER_PATH` can select another standalone build.

The App Store binary inside `Contents/Helpers` inherits the app's sandbox. External MCP clients cannot launch it directly; installing the app alone does not install a standalone MCP server.

`uvx` (`uv tool run`) holds the uv cache lock for the lifetime of the server (`astral-sh/uv#15990`). With several clients all using `uvx` the spawns serialize and can hit the 10 s handshake timeout. For multi-client / daily use install once persistently.

## Install / run

```sh
# One-off / trial — no install, uses cached env after first run:
uvx ijuka-mcp --help
# Pin for reproducibility:
uvx ijuka-mcp==1.2.1 --help

# Daily / multi-client — persistent, fastest, no cache-lock contention:
uv tool install ijuka-mcp
ijuka-mcp --help

# Update the persistent install:
uv tool upgrade ijuka-mcp
```

Local development (no PyPI):

```sh
uvx --from ./python ijuka-mcp --help
uv tool install --from ./python ijuka-mcp
```

All arguments are passed through, so tier/profile flags still work:

```sh
ijuka-mcp --help
ijuka-mcp --profile work
```

### Troubleshooting: `uvx` timeout or `Waiting to acquire lock`

If several AI clients launch `uvx ijuka-mcp` at once and one times out, either switch that client to the persistent `ijuka-mcp` command or re-run the failing `uvx` once - `uv cache` is shared and `uvx` retains a shared lock for the server lifetime. `uv tool install` avoids the lock entirely.
