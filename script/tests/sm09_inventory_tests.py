#!/usr/bin/env python3
"""Exercise inventory trust boundaries without touching product/user data."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "inventory", Path(__file__).resolve().parents[1] / "sm09_inventory.py"
)
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)


class InventoryTests(unittest.TestCase):
    def test_reference_scan_keeps_all_unicode_and_newline_paths(self):
        # More than twelve references catches the former silent truncation.
        refs = {f"文档/{index}\nreference.md" for index in range(20)}
        result = subprocess.CompletedProcess([], 0, "\0".join(refs) + "\0")
        with patch.object(inventory.subprocess, "run", return_value=result):
            self.assertEqual(inventory.referencers_of("source", refs), sorted(refs))

    def test_reference_scan_fails_closed(self):
        for code in (2, 127):
            with self.subTest(code=code), patch.object(
                inventory.subprocess, "run",
                return_value=subprocess.CompletedProcess([], code, ""),
            ):
                with self.assertRaises(RuntimeError):
                    inventory.referencers_of("source", set())

    def test_no_match_is_valid(self):
        with patch.object(inventory.subprocess, "run", return_value=
                          subprocess.CompletedProcess([], 1, "")):
            self.assertEqual(inventory.referencers_of("source", set()), [])

    def test_self_hash_is_explicitly_excluded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "manifest.json"
            output.write_text("previous generation")
            with patch.object(inventory, "REPO", root), \
                 patch.object(inventory, "OUTPUT", output), \
                 patch.object(inventory, "referencers_of", return_value=[]):
                entry = inventory.audit_entry("manifest.json", set())
            self.assertIn("hashDisposition", entry)
            self.assertNotIn("sha256", entry)
            self.assertNotIn("bytes", entry)

    def test_native_audit_tools_are_retained(self):
        self.assertEqual(inventory.classify("script/sm09_inventory.py")[0], "release-input")
        self.assertEqual(inventory.classify("script/tests/sm09_inventory_tests.py")[0], "native-test")


if __name__ == "__main__":
    unittest.main()
