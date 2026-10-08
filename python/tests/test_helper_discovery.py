import os
import plistlib
import subprocess
import unittest
from unittest.mock import patch

import ijuka_mcp


class HelperDiscoveryTests(unittest.TestCase):
    def check_signature(self, verify_code=0, entitlements=None):
        results = [
            subprocess.CompletedProcess([], verify_code, b"", b""),
            subprocess.CompletedProcess([], 0, plistlib.dumps(entitlements or {}), b""),
        ]
        with patch.object(ijuka_mcp.sys, "platform", "darwin"), \
             patch.object(os.path, "isfile", return_value=True), \
             patch.object(os, "access", return_value=True), \
             patch.object(subprocess, "run", side_effect=results) as run:
            launchable = ijuka_mcp._is_launchable_helper("/helper")
            if verify_code == 0:
                self.assertIn("--xml", run.call_args.args[0])
            return launchable

    def test_rejects_invalid_signature(self):
        self.assertFalse(self.check_signature(verify_code=1))

    def test_rejects_sandbox_inheritance(self):
        self.assertFalse(self.check_signature(entitlements={
            "com.apple.security.app-sandbox": True,
            "com.apple.security.inherit": True,
        }))

    def test_accepts_signed_standalone_helper(self):
        self.assertTrue(self.check_signature())

    def test_invalid_override_falls_back_to_standalone_install(self):
        with patch.dict(os.environ, {"IJUKA_MCP_HELPER_PATH": "/app/helper"}), \
             patch.object(ijuka_mcp, "_candidate_paths", return_value=["/standalone/helper"]), \
             patch.object(ijuka_mcp, "_is_launchable_helper", side_effect=[False, True]):
            self.assertEqual(ijuka_mcp._find_helper(), "/standalone/helper")

    def test_does_not_discover_app_bundle_helpers(self):
        self.assertFalse(any(".app/" in path for path in ijuka_mcp._candidate_paths()))


if __name__ == "__main__":
    unittest.main()
