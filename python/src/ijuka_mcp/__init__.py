from __future__ import annotations

import os
import sys


def _real_home() -> str:
    # Inside the app sandbox NSHomeDirectory() is the container, but the
    # helper lives in the real home. For the Python shim we just want the
    # actual user home — $HOME is correct even sandboxed for a child.
    return os.path.expanduser("~")


def _candidate_paths() -> list[str]:
    real_home = _real_home()
    # App Store helpers inherit their containing app's sandbox and cannot
    # be launched directly by an external MCP client.
    return [
        os.path.join(real_home, "bin/ijuka-mcp"),
        "/usr/local/bin/ijuka-mcp",
    ]


def _is_launchable_helper(path: str) -> bool:
    if not os.path.isfile(path) or not os.access(path, os.X_OK):
        return False
    if sys.platform != "darwin":
        return True

    import plistlib
    import subprocess

    # A copied or modified helper may exist yet have a broken signature.
    # Also reject sandbox-inheriting binaries supplied as an override.
    try:
        verified = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", path],
            capture_output=True, timeout=5,
        )
        if verified.returncode != 0:
            return False
        signature = subprocess.run(
            ["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", path],
            capture_output=True, timeout=5,
        )
        if signature.returncode != 0:
            return False
        entitlements = plistlib.loads(signature.stdout) if signature.stdout.strip() else {}
        return not entitlements.get("com.apple.security.inherit", False)
    except (OSError, ValueError, subprocess.TimeoutExpired, plistlib.InvalidFileException):
        return False


def _find_helper() -> str | None:
    # Env override wins, like the Swift helper's candidate logic.
    override = os.environ.get("IJUKA_MCP_HELPER_PATH") or os.environ.get("ijuka.mcp.helperPath")
    if override and _is_launchable_helper(override):
        return override

    for pattern in _candidate_paths():
        if _is_launchable_helper(pattern):
            return pattern
    return None


def main() -> None:
    helper = _find_helper()
    if helper is None:
        print(
            "ijuka-mcp: helper not found. Install the standalone helper with scripts/install-mcp-helper.sh or set IJUKA_MCP_HELPER_PATH to a standalone build.",
            file=sys.stderr,
        )
        print(f"Looked in: {', '.join(_candidate_paths())}", file=sys.stderr)
        sys.exit(1)

    # Replace this Python process with the Swift helper — same pid, same stdio.
    # This is what makes `uvx ijuka-mcp` behave exactly like invoking the
    # helper directly.
    try:
        os.execv(helper, [helper, *sys.argv[1:]])
    except Exception as e:
        print(f"ijuka-mcp: failed to exec {helper}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
