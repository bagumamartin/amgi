from __future__ import annotations

import os
import pathlib
import sys


def _real_home() -> str:
    # Inside the Amgi sandbox NSHomeDirectory() is the container, but the
    # helper lives in the real home. For the Python shim we just want the
    # actual user home — $HOME is correct even sandboxed for a child.
    return os.path.expanduser("~")


def _candidate_paths() -> list[str]:
    real_home = _real_home()
    return [
        "/Applications/AmgiApp.app/Contents/Helpers/amgi-mcp",
        os.path.join(real_home, "Applications/AmgiApp.app/Contents/Helpers/amgi-mcp"),
        os.path.join(real_home, "bin/amgi-mcp"),
        "/usr/local/bin/amgi-mcp",
        # Dev fallback: allow running the shim against a DerivedData build
        # without having copied to /Applications. Best-effort glob.
        os.path.expanduser("~/Library/Developer/Xcode/DerivedData/AmgiApp-*/Build/Products/Debug/AmgiApp.app/Contents/Helpers/amgi-mcp"),
    ]


def _find_helper() -> str | None:
    # Env override wins, like the Swift helper's candidate logic.
    override = os.environ.get("AMGI_MCP_HELPER_PATH") or os.environ.get("amgi.mcp.helperPath")
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
            "amgi-mcp: helper not found. Install Amgi to /Applications or set AMGI_MCP_HELPER_PATH.",
            file=sys.stderr,
        )
        # Also hint at the SwiftPM fallback for developers
        dev_fallback = pathlib.Path.home() / "Library/Developer/Xcode/DerivedData"
        print(f"Looked in: {', '.join(_candidate_paths())}", file=sys.stderr)
        sys.exit(1)

    # Replace this Python process with the Swift helper — same pid, same stdio.
    # This is what makes `uvx amgi-mcp` behave exactly like invoking the
    # helper directly.
    try:
        os.execv(helper, [helper, *sys.argv[1:]])
    except Exception as e:
        print(f"amgi-mcp: failed to exec {helper}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
