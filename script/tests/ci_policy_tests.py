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
        baseline = native.document(native.MANIFESTS / 'sm09-native-contract.json')
        contract, plan, _ = native.current_acceptance(baseline)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            swift = '\n'.join(f"Test Case '-[{ref.replace('/', ' ')}]' passed" for ref in contract['requiredSwiftTests'] if ref not in native.PERFORMANCE_ONLY_TESTS)
            swift += '\nSM06_RESOURCES active=0 pending=0 processes=0\nSM06_VISION_SMOKE revision=3\n'
            # Supplement the effective current plan, while deliberately omitting FPS.
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
            native.validate_execution(root, baseline, functional=True)
            result = json.loads((root/'native-evidence.json').read_text())
            self.assertFalse(result['completeAcceptance'])
            self.assertEqual(result['performancePolicy'], 'advisory')
            self.assertTrue(any(item['deferredTests'] for item in result['acceptance'].values()))
            self.assertEqual(result['executionMode'], 'native-gate')
            self.assertEqual(len(result['testTransitions']), 16)
            # Historical evidence is useful for a replay but cannot certify a
            # new commit or a full release, even when every functional check passes.
            evidence_commit = 'c4111fed1a46289b3b002090d295fe3684547884'
            (root/'result.json').write_text(json.dumps({'reviewCommit': evidence_commit}))
            native.validate_execution(root, baseline, functional=True, replay_commit=evidence_commit)
            replay = json.loads((root/'native-evidence.json').read_text())
            self.assertEqual(replay['evidenceCommit'], evidence_commit)
            self.assertEqual(replay['executionMode'], 'offline-replay')
            self.assertFalse(replay['completeAcceptance'])
            with self.assertRaisesRegex(AssertionError, 'source commit mismatch'):
                native.validate_execution(root, baseline, functional=True, replay_commit='0'*40)
            with self.assertRaises(AssertionError):
                native.validate_execution(root, baseline)
            # Removing any new credential PASS must fail rather than merely
            # relying on the old suite or overall executed test count.
            for ref in native.document(native.CURRENT_ACCEPTANCE)['requiredAdditionalTests']:
                (root/'swift_test.log').write_text(swift.replace(f"Test Case '-[{ref.replace('/', ' ')}]' passed", ''))
                with self.assertRaisesRegex(AssertionError, 'missing executed PASS'):
                    native.validate_execution(root, baseline, functional=True)
            # Functional coverage cannot silently omit an ordinary test.
            (root/'swift_test.log').write_text('')
            with self.assertRaises(AssertionError):
                native.validate_execution(root, baseline, functional=True)

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

    def test_report_distinguishes_failed_skipped_incomplete_and_missing(self):
        names = report.BENCHMARKS
        log = "\n".join([
            f"Test Case '-[Suite {names[0]}]' passed (0.1 seconds).",
            f"Test Case '-[Suite {names[1]}]' failed (0.1 seconds).",
            f"Test Case '-[Suite {names[1]}]' passed (0.1 seconds).",
            f"Test Case '-[Suite {names[2]}]' skipped (0.1 seconds).",
            f"Test Case '-[Suite {names[3]}]' started.",
        ])
        self.assertEqual(list(report.benchmark_results(log).values()),
                         ['passed', 'failed', 'skipped', 'incomplete', 'missing'])

    def test_dependency_failure_is_not_execution_or_a_pass(self):
        source = (ROOT/'script/phase_gate.sh').read_text()
        function = source[source.index('run_dependent_check() {'):source.index('\nrun_check() {')]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'dependency.zsh'
            path.write_text(function)
            command = ('source "$1"; typeset -A check_results; '
                       '[[ "$2" == MISSING ]] || check_results[parent]="$2"; '
                       'record_check() { print -r -- "$1 $3"; }; '
                       'run_check() { print EXECUTED; }; '
                       'run_dependent_check parent child true description true')
            for state, expected in [('PASS', 'EXECUTED'), ('FAIL', 'child NOT_RUN'),
                                    ('BLOCKED_ENV', 'child NOT_RUN'), ('NOT_RUN', 'child NOT_RUN'),
                                    ('MISSING', 'child FAIL')]:
                value = native.subprocess.run(['zsh', '-c', command, '--', str(path), state],
                                              check=True, capture_output=True, text=True)
                self.assertEqual(value.stdout.strip(), expected)

    def test_final_review_target_rejects_head_dirty_and_observation_drift(self):
        source = (ROOT/'script/phase_gate.sh').read_text()
        function = source[source.index('clean_workspace_check() {'):source.index('# forbidden_items_check 已移入')]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'target.zsh'
            path.write_text(function)
            command = ("source \"$1\"; review_commit=before; allow_dirty=0; mode=\"$2\"; "
                       "git() { if [[ \"$1\" == rev-parse ]]; then "
                       "if [[ $mode == head ]]; then print after; else print before; fi; "
                       "else [[ $mode == error ]] && return 128; "
                       "[[ $mode == dirty ]] && print modified; fi; return 0; }; "
                       "review_target_unchanged_check")
            for mode in ['clean', 'head', 'dirty', 'error']:
                value = native.subprocess.run(['zsh', '-c', command, '--', str(path), mode],
                                              check=False, capture_output=True)
                self.assertEqual(value.returncode == 0, mode == 'clean')

    def test_gate_scope_metadata_and_exit_codes(self):
        source = (ROOT/'script/phase_gate.sh').read_text()
        function = source[source.index('write_result_artifacts() {'):source.index('\nwhile (( $# > 0 ))')]
        ending = source[source.index('if [[ "$overall_result" == "FAIL" ]]; then'):]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'functions.zsh').write_text(function)
            (root/'checks.tsv').write_text('core\ttrue\tPASS\tfunctional tests passed\t\n')
            command = 'source "$1"; result_dir="$2"; checks_tsv="$2/checks.tsv"; phase=SM-09; review_commit=fixture; approvable=false; allow_dirty=0; functional_only=1; write_result_artifacts PASS'
            native.subprocess.run(['zsh', '-c', command, '--', str(root/'functions.zsh'), str(root)], check=True,
                                  env=dict(os.environ, GITHUB_STEP_SUMMARY=""))
            value = json.loads((root/'result.json').read_text())
            self.assertEqual(value['scope'], 'functional')
            self.assertEqual(value['performancePolicy'], 'advisory')
            self.assertFalse(value['approvable'])
            self.assertEqual(value['acceptancePolicyVersion'], 2)
            self.assertTrue(value['completionEligible'])
            self.assertFalse(value['fullAcceptancePassed'])
            # Migration completion and strict release acceptance have different
            # scopes. No dirty, incomplete, blocked or unexecuted run qualifies.
            for outcome, dirty, functional, checks, completion, full in [
                ('PASS', 0, 0, 'core\ttrue\tPASS\tcore passed\t\n', True, True),
                ('PASS', 1, 0, 'core\ttrue\tPASS\tcore passed\t\n', False, False),
                ('FAIL', 0, 1, 'core\ttrue\tFAIL\tfailed\t\n', False, False),
                ('BLOCKED_ENV', 0, 1, 'core\ttrue\tBLOCKED_ENV\tunavailable\t\n', False, False),
                ('PASS', 0, 1, 'core\ttrue\tNOT_RUN\tmissing prerequisite\t\n', False, False),
                ('PASS', 0, 1, 'core\ttrue\tNOT_APPLICABLE\tnot applicable\t\n', False, False),
                ('PASS', 0, 1, '', False, False),
            ]:
                with self.subTest(outcome=outcome, dirty=dirty, functional=functional, checks=checks):
                    (root/'checks.tsv').write_text(checks)
                    scoped = command.replace('allow_dirty=0; functional_only=1;',
                                             f'allow_dirty={dirty}; functional_only={functional};')
                    scoped = scoped.replace('approvable=false;', 'approvable=true;')
                    scoped = scoped.replace('write_result_artifacts PASS', f'write_result_artifacts {outcome}')
                    native.subprocess.run(['zsh', '-c', scoped, '--', str(root/'functions.zsh'), str(root)],
                                          check=True, env=dict(os.environ, GITHUB_STEP_SUMMARY=""))
                    result = json.loads((root/'result.json').read_text())
                    self.assertEqual(result['completionEligible'], completion)
                    self.assertEqual(result['fullAcceptancePassed'], full)
            (root/'checks.tsv').write_text('core\ttrue\tPASS\tfunctional tests passed\t\n')
            # Provisional progress must survive cancellation without certifying
            # the candidate, even when the intended final lane is approvable.
            progress = command.replace('write_result_artifacts PASS',
                                       'active_check=mock_build; approvable=true; write_result_artifacts IN_PROGRESS')
            native.subprocess.run(['zsh', '-c', progress, '--', str(root/'functions.zsh'), str(root)],
                                  check=True, env=dict(os.environ, GITHUB_STEP_SUMMARY=""))
            snapshot = json.loads((root/'result.json').read_text())
            self.assertFalse(snapshot['executionComplete'])
            self.assertFalse(snapshot['approvable'])
            self.assertFalse(snapshot['completionEligible'])
            self.assertFalse(snapshot['fullAcceptancePassed'])
            self.assertEqual(snapshot['activeCheck'], 'mock_build')
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
