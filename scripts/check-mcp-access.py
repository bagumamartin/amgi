#!/usr/bin/env python3
"""Exercise uvx with two real MCP SDK clients against the current collection.

Run with: uv run --with mcp python scripts/check-mcp-access.py --mode bridged
Use --mode direct with Ijuka quit. Reads only unless --write-key is supplied;
that option rewrites an existing config value unchanged and checks read-back.
"""
import argparse
import asyncio
import json

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


def result_text(result):
    assert not result.is_error, result
    return "\n".join(item.text for item in result.content if item.type == "text")


async def check_client(options):
    parameters = StdioServerParameters(
        command="uvx", args=["ijuka-mcp"],
        env={"IJUKA_MCP_HELPER_PATH": options.helper} if options.helper else None,
    )
    async with stdio_client(parameters) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            assert tools.tools, "No tools discovered"
            for _ in range(10):
                status = result_text(await session.call_tool("collection_status", {}))
                assert f"mode: {options.mode}" in status, status
                result_text(await session.call_tool("deck_tree", {}))
            if options.write_key:
                arguments = {"key": options.write_key}
                original = result_text(await session.call_tool("get_config_json", arguments))
                assert original != "(unset)", "Choose an existing key for an unchanged write"
                json.loads(original)
                result_text(await session.call_tool("set_config_json", {
                    "key": options.write_key, "value_json": original,
                }))
                after = result_text(await session.call_tool("get_config_json", arguments))
                assert json.loads(after) == json.loads(original), "Config changed during the check"
            # Keep both uvx clients alive while the other performs requests.
            await asyncio.sleep(1)


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["bridged", "direct"], required=True)
    parser.add_argument("--write-key", help="Existing config key to rewrite unchanged")
    parser.add_argument("--helper", help="Staged standalone helper to test through uvx before installation")
    options = parser.parse_args()
    await asyncio.wait_for(asyncio.gather(check_client(options), check_client(options)), timeout=60)
    print(f"Two concurrent uvx MCP clients passed discovery, reads"
          f"{' and unchanged writes' if options.write_key else ''} in {options.mode} mode.")


if __name__ == "__main__":
    asyncio.run(main())
