#!/usr/bin/env python3
"""Regression check for MCP client initialization. Defaults to uvx ijuka-mcp.

Supply a helper command as arguments to check a standalone or bundled build.
Uses a temporary read-only configuration and never opens the real collection.
"""
import json
import queue
import subprocess
import sys
import tempfile
import threading
from pathlib import Path


def check(command, capabilities, root, expect_error=False):
    process = subprocess.Popen(
        [*command, '--root', str(root), '--config', str(root / 'mcp.json')],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True,
    )
    responses = queue.Queue()

    def receive():
        for line in process.stdout:
            responses.put(json.loads(line))
        responses.put(None)

    threading.Thread(target=receive, daemon=True).start()

    def request(identifier, method, params):
        process.stdin.write(json.dumps({
            'jsonrpc': '2.0', 'id': identifier, 'method': method, 'params': params,
        }) + '\n')
        process.stdin.flush()
        while True:
            response = responses.get(timeout=15)
            assert response is not None, 'server closed before responding'
            if response.get('id') == identifier:
                return response

    try:
        initialized = request(1, 'initialize', {
            'protocolVersion': '2025-11-25', 'capabilities': capabilities,
            'clientInfo': {'name': 'client-compatibility-check', 'version': '1'},
        })
        if expect_error:
            assert 'error' in initialized, 'malformed standard capabilities were accepted'
            return
        assert 'error' not in initialized, initialized
        process.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        process.stdin.flush()
        tools = request(2, 'tools/list', {})
        assert 'error' not in tools, tools
        assert tools['result']['tools'], 'no tools discovered'
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=5)


if __name__ == '__main__':
    command = sys.argv[1:] or ['uvx', 'ijuka-mcp']
    with tempfile.TemporaryDirectory(prefix='ijuka-mcp-regression-') as directory:
        root = Path(directory)
        (root / 'mcp.json').write_text(json.dumps({
            'enabled': True, 'tier': 'readOnly', 'blockWritesWhileAppRunning': True,
            'snapshotsBeforeDestructive': True,
        }))
        for capabilities in [
            {},
            {'experimental': {'feature': {}}},
            {'experimental': {'feature': {'nested': [True, 1, None]}}},
            {'experimental': {'feature': False}, 'roots': {'listChanged': True}},
            {'experimental': {'feature': 'legacy'}, 'sampling': {}},
        ]:
            check(command, capabilities, root)
        check(command, {'roots': 'invalid'}, root, expect_error=True)
    print('Five client handshake variants and malformed-capability rejection passed.')
