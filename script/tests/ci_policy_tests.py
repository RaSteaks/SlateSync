#!/usr/bin/env python3
"""Exercise CI policy boundaries with synthetic evidence and no external services."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

native = load('native_contract', 'script/tests/sm09_native_contract.py')
release = load('release_contract', 'script/tests/sm09_release_contract.py')
report = load('performance_report', 'script/performance_report.py')


class CIPolicyTests(unittest.TestCase):
    def setUp(self):
        self.budget = json.loads((ROOT / 'Tests/SlateSyncUIUnitTests/Fixtures/SM08/performance-budget.json').read_text())
        self.list_metrics = dict(projects=500, tasks=1000, warmups=1, samples=5,
                                 projectSelectionMs=[500]*5, taskSelectionMs=[500]*5,
                                 projectVisibleRows=[10]*5, taskVisibleRows=[10]*5)

    def test_only_timing_is_advisory_in_functional_scope(self):
        with self.assertRaises(AssertionError):
            native.validate_metrics('native-project-task-scale.json', self.list_metrics, self.budget)
        native.validate_metrics('native-project-task-scale.json', self.list_metrics, self.budget, enforce_timing=False)
        self.list_metrics['projectVisibleRows'] = [1000]*5
        with self.assertRaises(AssertionError):
            native.validate_metrics('native-project-task-scale.json', self.list_metrics, self.budget, enforce_timing=False)

    def test_functional_evidence_does_not_claim_full_acceptance(self):
        contract = native.document(native.MANIFESTS / 'sm09-native-contract.json')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            swift = '\n'.join(f"Test Case '-[{ref.replace('/', ' ')}]' passed" for ref in contract['requiredSwiftTests'] if ref not in native.PERFORMANCE_ONLY_TESTS)
            swift += '\nSM06_RESOURCES active=0 pending=0 processes=0\nSM06_VISION_SMOKE revision=3\n'
            plan = native.document(ROOT / 'Tests/SlateSyncUIUnitTests/Fixtures/SM09/sm09-native-evidence-plan.json')
            # Supplement every existing plan reference, while deliberately omitting FPS.
            for item in plan.values():
                if item['runner'] != 'xcode':
                    for ref in item['tests']:
                        if ref not in native.PERFORMANCE_ONLY_TESTS:
                            swift += f"Test Case '-[{ref.replace('/', ' ')}]' passed\n"
            swift += "Test Case '-[SlateSyncPersistenceTests.SM09LegacyPackageTests testFrozenLegacyPackagesImportEditReopenAndExportWithoutSourceMutation]' passed\n"
            xcode = "Test Case '-[SlateSyncUITests.SlateSyncUITests testLegacyLibraryCSVExportAndReopenInDeliveredApp]' passed\n"
            for item in plan.values():
                if item['runner'] == 'xcode':
                    xcode += '\n'.join(f"Test Case '-[{ref.replace('/', ' ')}]' passed" for ref in item['tests']) + '\n'
            (root/'swift_test.log').write_text(swift)
            (root/'xcode_test_plan_xcodebuild.log').write_text(xcode)
            (root/'xcode_test_summary.json').write_text(json.dumps(dict(result='Passed', failedTests=0, passedTests=99)))
            metrics = root/'sm08-metrics'
            metrics.mkdir()
            values = {
                'native-project-task-scale.json': self.list_metrics,
                'real-sqlite-scale.json': dict(projects=500, tasks=1000, warmups=1, samples=5, projectLoadMs=[9999]*5, taskLoadMs=[9999]*5),
                'native-csv-scale.json': dict(fixtureRows=10000, warmups=1, samples=5, snapshotMs=[9999]*5, farRowEditMs=[9999]*5, visibleCellCounts=[10]*5, residentDeltaBytes=[0]*5, retainedResidentBytes=0),
            }
            for name, value in values.items():
                (metrics/name).write_text(json.dumps(value))
            native.validate_execution(root, contract, functional=True)
            result = json.loads((root/'native-evidence.json').read_text())
            self.assertFalse(result['completeAcceptance'])
            self.assertEqual(result['performancePolicy'], 'advisory')
            self.assertTrue(any(item['deferredTests'] for item in result['acceptance'].values()))
            with self.assertRaises(AssertionError):
                native.validate_execution(root, contract)
            # Functional coverage cannot silently omit an ordinary test.
            (root/'swift_test.log').write_text('')
            with self.assertRaises(AssertionError):
                native.validate_execution(root, contract, functional=True)

    def test_report_preserves_failure_and_overrides_functional_environment(self):
        captured = {}
        def failing(command, **kwargs):
            captured.update(kwargs['env'])
            return type('Completed', (), {'returncode': 7})()
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {'SLATESYNC_PERFORMANCE_POLICY': 'functional', 'GITHUB_STEP_SUMMARY': ''}), patch.object(report.subprocess, 'run', failing):
            root = Path(directory)
            self.assertEqual(report.run(root), 1)
            value = json.loads((root/'result.json').read_text())
            self.assertFalse(value['passed'])
            self.assertEqual(value['exitCode'], 7)
            self.assertEqual(captured['SLATESYNC_PERFORMANCE_POLICY'], 'strict')
            self.assertIn('non-blocking', (root/'SUMMARY.md').read_text())

    def test_existing_reports_are_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/"result.json").write_text("previous")
            with self.assertRaises(ValueError):
                report.run(root)
            self.assertEqual((root/"result.json").read_text(), "previous")

    def test_zero_exit_without_executed_benchmarks_is_failure(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': ''}), patch.object(report.subprocess, 'run', return_value=type('Completed', (), {'returncode': 0})()):
            self.assertEqual(report.run(Path(directory)), 1)

    def test_gate_scope_metadata_and_exit_codes(self):
        source = (ROOT/'script/phase_gate.sh').read_text()
        function = source[source.index('write_result_artifacts() {'):source.index('\nwhile (( $# > 0 ))')]
        ending = source[source.index('if [[ "$overall_result" == "FAIL" ]]; then'):]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'functions.zsh').write_text(function)
            (root/'checks.tsv').write_text('core\ttrue\tPASS\tfunctional tests passed\t\n')
            command = 'source "$1"; result_dir="$2"; checks_tsv="$2/checks.tsv"; phase=SM-09; review_commit=fixture; approvable=false; allow_dirty=0; functional_only=1; write_result_artifacts PASS'
            native.subprocess.run(['zsh', '-c', command, '--', str(root/'functions.zsh'), str(root)], check=True)
            value = json.loads((root/'result.json').read_text())
            self.assertEqual(value['scope'], 'functional')
            self.assertEqual(value['performancePolicy'], 'advisory')
            self.assertFalse(value['approvable'])
            for outcome, functional, dirty, expected in [('PASS', 1, 0, 0), ('FAIL', 1, 0, 1), ('BLOCKED_ENV', 1, 0, 2), ('PASS', 1, 1, 3), ('PASS', 0, 0, 3)]:
                setup = f'overall_result={outcome}; functional_only={functional}; allow_dirty={dirty}; approvable=false; exit_fail=1; exit_blocked_environment=2; exit_diagnostic_only=3;\n'
                result = native.subprocess.run(['zsh', '-c', setup + ending], check=False)
                self.assertEqual(result.returncode, expected)

    def test_required_job_and_release_cannot_become_advisory(self):
        ci = (ROOT/'.github/workflows/ci.yml').read_text()
        rel = (ROOT/'.github/workflows/release.yml').read_text()
        release.validate_workflows(ci, rel)
        with self.assertRaises(AssertionError):
            release.validate_workflows(ci.replace('  native-test:', '  native-test:\n    continue-on-error: true'), rel)
        with self.assertRaises(AssertionError):
            release.validate_workflows(ci, rel.replace('./script/phase_gate.sh SM-09', './script/phase_gate.sh SM-09 --functional'))


if __name__ == '__main__':
    unittest.main()
