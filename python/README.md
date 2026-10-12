# ijuka-mcp (Python shim for `uvx`)

This is a tiny Python wrapper that makes the Ijuka MCP server runnable via [`uvx`](https://docs.astral.sh/uv/guides/tools/#running-tools-with-uvx) — the pattern many MCP clients expect:

```
Command: uvx
Parameters: ijuka-mcp
```

The Swift helper is the real server. Install its standalone build from the repository with `./scripts/install-mcp-helper.sh` first. This package finds it in `~/bin` or `/usr/local/bin` and `exec`s it, forwarding stdio. `IJUKA_MCP_HELPER_PATH` can select another standalone build.

Updating the native helper does not require clearing uv’s cache: the launcher discovers the helper on every new connection. Restart already-running MCP clients after upgrading the helper. To refresh the Python launcher itself, quit its clients first, then run `uvx --refresh-package ijuka-mcp ijuka-mcp --help`. A persistent `uv tool install` is upgraded separately with `uv tool upgrade ijuka-mcp`.

The App Store binary inside `Contents/Helpers` inherits the app's sandbox. External MCP clients cannot launch it directly; installing the app alone does not install a standalone MCP server.

Multiple clients can use `uvx ijuka-mcp` simultaneously. While Ijuka is open, requests use its live engine through the local bridge; while it is closed, helpers take turns opening the collection and release it after each tool call. Keep “Allow changes while Ijuka is open” enabled in Agent settings to permit writes in both modes.

## Install / run

```sh
# One-off / trial — no install, uses cached env after first run:
uvx ijuka-mcp --help
# Pin for reproducibility:
uvx ijuka-mcp==1.2.1 --help

# Optional persistent launcher:
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

### Troubleshooting

For connection problems, run `uvx ijuka-mcp --help`, then restart the client. The native helper must be a standalone build with a valid signature and its Rust framework alongside it; a sandbox-inheriting App Store helper cannot be launched by an external client.

If reads work but writes fail only while Ijuka is open, check “Allow changes while Ijuka is open” in Agent settings. Older app builds reversed this toggle; updating Ijuka corrects its meaning. The underlying `blockWritesWhileAppRunning` setting must be `false` to allow simultaneous writes.

Avoid running `uv cache clean` while uvx servers are alive. uv retains a shared cache lock for their lifetime, so cleanup can wait for those processes to exit ([uv PR #15990](https://github.com/astral-sh/uv/pull/15990)); this is different from a collection lock.

Development regression checks:

```sh
python3 scripts/check-mcp-handshake.py
# With Ijuka running:
uv run --with mcp python scripts/check-mcp-access.py --mode bridged
# With Ijuka quit:
uv run --with mcp python scripts/check-mcp-access.py --mode direct
```

The SDK check runs two concurrent uvx clients. It reads only by default; `--write-key <existing-config-key>` also rewrites that value unchanged and verifies read-back.
