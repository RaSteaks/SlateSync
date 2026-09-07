#!/usr/bin/env python3
"""Verify every legacy removal candidate has one native acceptance owner."""

import importlib.util
import json
from pathlib import Path
import unittest

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("coverage", REPO / "script/sm09_coverage.py")
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)


class CoverageTests(unittest.TestCase):
    def test_every_inventory_removal_is_mapped_once(self):
        inventory = json.loads(coverage.INVENTORY.read_bytes())
        expected = {item["path"] for item in inventory["files"] if item["category"] == "legacy-remove"}
        mapped = [item["path"] for item in json.loads(coverage.OUTPUT.read_bytes())["entries"]]
        self.assertEqual(set(mapped), expected)
        self.assertEqual(len(mapped), len(set(mapped)))

    def test_every_family_has_executable_acceptance_and_replacement(self):
        document = json.loads(coverage.OUTPUT.read_bytes())
        self.assertEqual(document["summary"]["unowned"], 0)
        for entry in document["entries"]:
            self.assertTrue(entry["acceptanceIDs"], entry["path"])
            self.assertTrue(entry["replacement"], entry["path"])
            self.assertEqual(len(entry["preCutoverSha256"]), 64)

    def test_unknown_legacy_path_fails_closed(self):
        with self.assertRaises(ValueError):
            coverage.family_for("unknown/runtime.bin")


if __name__ == "__main__":
    unittest.main()
