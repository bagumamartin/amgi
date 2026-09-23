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
    return [
        "/Applications/*.app/Contents/Helpers/ijuka-mcp",
        os.path.join(real_home, "Applications/*.app/Contents/Helpers/ijuka-mcp"),
        os.path.join(real_home, "bin/ijuka-mcp"),
        "/usr/local/bin/ijuka-mcp",
        # Dev fallback: allow running the shim against a DerivedData build
        # without having copied to /Applications. Best-effort glob.
        os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/*/*.app/Contents/Helpers/ijuka-mcp"),
    ]


def _find_helper() -> str | None:
    # Env override wins, like the Swift helper's candidate logic.
    override = os.environ.get("IJUKA_MCP_HELPER_PATH") or os.environ.get("ijuka.mcp.helperPath")
    if override and os.path.isfile(override) and os.access(override, os.X_OK):
        return override

    import glob

    for pattern in _candidate_paths():
        # Support glob for DerivedData fallback
        if "*" in pattern:
            for path in glob.glob(pattern):
                if os.path.isfile(path) and os.access(path, os.X_OK):
                    return path
            continue
        if os.path.isfile(pattern) and os.access(pattern, os.X_OK):
            return pattern
    return None


def main() -> None:
    helper = _find_helper()
    if helper is None:
        print(
            "ijuka-mcp: helper not found. Install Ijuka to /Applications or set IJUKA_MCP_HELPER_PATH.",
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
