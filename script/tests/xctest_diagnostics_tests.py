"""Offline tests for per-test evidence export; no XCTest runner is launched."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from export_failed_test_attachments import export_failures


class DiagnosticsTests(unittest.TestCase):
    def test_teardown_attachments_export_by_test_without_manifest_collisions(self):
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            def run(command, check):
                self.assertTrue(check)
                self.assertNotIn("--only-failures", command)
                calls.append(command)
                output = Path(command[command.index("--output-path") + 1])
                (output / "manifest.json").write_text('[{"attachments": ["teardown.png"]}]')
            summary = {"testFailures": [{"testIdentifierString": name} for name in ["Suite/testA()", "Suite/testB()", "Suite/testA()"]]}
            export_failures(Path("result.xcresult"), summary, Path(directory), run)
            self.assertEqual(len(calls), 2)
            self.assertEqual(len(list(Path(directory).glob("*/manifest.json"))), 2)
            self.assertEqual({p.read_text().strip() for p in Path(directory).glob("*/test-id.txt")},
                             {"Suite/testA()", "Suite/testB()"})

    def test_one_export_failure_does_not_discard_other_test_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            def run(command, check):
                calls.append(command)
                if command[-1] == "Suite/testA()":
                    raise subprocess.CalledProcessError(1, command)
            with self.assertRaises(RuntimeError):
                export_failures(Path("result.xcresult"), {"testFailures": [
                    {"testIdentifierString": "Suite/testA()"}, {"testIdentifierString": "Suite/testB()"}]}, Path(directory), run)
            self.assertEqual(len(calls), 2)

    def test_initialization_failure_without_identifier_does_not_invent_a_test(self):
        export_failures(Path("result.xcresult"), {"testFailures": [{"failureText": "Runner unavailable"}]},
                        Path("unused"), lambda *args, **kwargs: self.fail("no named test to export"))


if __name__ == "__main__":
    unittest.main()
