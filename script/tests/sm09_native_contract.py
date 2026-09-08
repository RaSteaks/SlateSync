#!/usr/bin/env python3
"""Validate retained provenance and executed native acceptance after cutover.

Historical sources are read from the verified Git object, never executed.
The baseline test list is a minimum: new tests still run in the full suite.
"""
import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MANIFESTS = ROOT / '.codex/swift-migration/manifests'
BASE = '52b2a78f6619145b0999bdccf588d83a95349e7c'


def require(value, message):
    if not value:
        raise AssertionError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    return (ROOT / path).read_text()


def document(path):
    return json.loads(Path(path).read_bytes())


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])


def verify_bytes(data, expected, label):
    require(digest(data) == expected, f'hash drift: {label}')


def validate_provenance(cutover, seal, result):
    require(cutover['preCutoverCommit'] == seal['commit'] == result['reviewCommit'] == BASE,
            'pre-cutover commit mismatch')
    require(seal['status'] == result['overallResult'] == 'PASS', 'baseline is not PASS')
    require(seal['approvable'] is True and result['approvable'] is True,
            'diagnostic evidence cannot authorize cutover')
    required = {'sm09_node_compatibility', 'sm09_modern_compatibility', 'sm09_native_abi',
                'sm09_static_checks', 'sm09_typecheck', 'sm09_modern_build',
                'swift_test', 'xcode_test_plan', 'sm09_archive_bundle_audit', 'sm09_package_artifacts'}
    passed = {entry['id'] for entry in result['checks'] if entry['result'] == 'PASS'}
    require(required <= passed, 'missing compatibility evidence')
    require(all(e['result'] in ('PASS', 'NOT_APPLICABLE') for e in result['checks']), 'failed baseline check')
    paths = [e['path'] for e in cutover['removed']]
    require(len(paths) == len(set(paths)) == 239, 'incomplete or duplicate removal mapping')
    for entry in cutover['removed']:
        require(entry['replacement'] and entry['acceptanceIDs'] and entry['reason'], 'unowned removal')


def validate_fixtures(contract):
    for path, expected in contract['fixtureSha256'].items():
        verify_bytes((ROOT / path).read_bytes(), expected, path)
    # Provenance records remain unchanged, including removed paths. Resolve
    # their original bytes from Git so an absent oracle cannot bypass a check.
    for name, keys in [
        ('Tests/SlateSyncMediaTests/Fixtures/SM06/manifest.json', ['sources', 'workflowFiles']),
        ('Tests/SlateSyncWorkflowTests/Fixtures/SM07/sm07-manifest.json', ['sources']),
        ('Tests/SlateSyncUIUnitTests/Fixtures/SM08/source-manifest.json', ['sources']),
    ]:
        manifest = json.loads(read(name))
        for key in keys:
            for item in manifest.get(key, []):
                data = git('show', f"{BASE}:{item['path']}")
                verify_bytes(data, item['sha256'], item['path'])
                if 'bytes' in item:
                    require(len(data) == item['bytes'], f"source length drift: {item['path']}")


def validate_oracles(source=None):
    source = source if source is not None else read('Sources/SlateSyncWorkflow/RecognitionPrompts.swift')
    oracle = json.loads(read('Tests/SlateSyncWorkflowTests/Fixtures/SM07/sm07-manifest.json'))['canonicalOracles']
    def raw(name):
        match = re.search(r'public static let ' + name + r' = #"""([\s\S]*?)"""#', source)
        require(match, f'missing prompt {name}')
        return match[1][1:-1]
    review = re.search(r'public static let review = audit \+ "\\n\\n" \+ #"""([\s\S]*?)"""#', source)
    require(review, 'missing review prompt')
    for name, value in [('systemPrompt', raw('system')), ('auditPrompt', raw('audit')),
                        ('reviewPrompt', raw('audit') + '\n\n' + review[1][1:-1])]:
        verify_bytes(value.encode(), oracle[name]['sha256'], name)
    probe = read('Sources/SlateSyncWorkflow/ModelCapabilityProbeService.swift')
    value = re.search(r'syntheticProbePNGBase64 = "([A-Za-z0-9+/=]+)"', probe)
    require(value, 'missing probe image')
    verify_bytes(base64.b64decode(value[1]), oracle['syntheticProbePNG']['sha256'], 'probe image')
    require(oracle['syntheticProbePNG']['marker'] in probe, 'probe marker drift')


def validate_source_boundaries():
    # Preserve ownership restrictions formerly checked by the phase contracts.
    for path in (ROOT / 'Sources/SlateSyncMedia').glob('*.swift'):
        require(not re.search(r'@unchecked\s+Sendable|try!|as!|import SlateSyncPersistence|import SQLite3|URLSession|homeDirectoryForCurrentUser', path.read_text()), str(path))
    ui_files = list((ROOT / 'Sources/SlateSyncUI').rglob('*.swift'))
    ui = '\n'.join(p.read_text() for p in ui_files)
    require(not re.search(r'URLSession|import SQLite3|import SlateSyncPersistence|Process\s*\(', ui), 'UI ownership violation')
    bridges = sorted(str(p.relative_to(ROOT)) for p in ui_files if re.search(r':\s*NSViewRepresentable', p.read_text()))
    require(bridges == ['Sources/SlateSyncUI/App/WindowLifecycleBridge.swift',
                        'Sources/SlateSyncUI/CSV/EditableCSVTableRepresentable.swift'], 'AppKit bridge allowlist drift')
    commands = read('Sources/SlateSyncUI/App/FocusedActions.swift')
    require('NSApp.keyWindow?.performClose(nil)' in commands, 'current-window close missing')
    require(commands.count('.keyboardShortcut("s"') == 1, 'Save command ownership drift')
    app = read('SlateSyncApp/App/SlateSyncApp.swift')
    for token in ['WindowGroup', 'Settings {', '.frame(minWidth: 960, minHeight: 600)',
                  'guard let termination else { return .terminateCancel }']:
        require(token in app, f'App contract missing: {token}')
    logs = read('Sources/SlateSyncPersistence/LocalLogStore.swift')
    for token in ['retentionDays = 7', 'defaultReadLimit = 500', 'maximumReadLimit = 2_000', 'LOCK_EX', '0o700', '0o600']:
        require(token in logs, f'log boundary missing: {token}')
    installer = read('Sources/SlateSyncWorkflow/PaddleOCRInstallerService.swift')
    for token in ['3.3.1', '3.7.0', '30 * 60', '.detectPython, 5', '.createEnvironment, 20',
                  '.installDependencies, 35', '.verify, 90', '.completed, 100', 'SIGTERM', 'SIGKILL', 'lstat(requirementsURL.path']:
        require(token in installer, f'installer boundary missing: {token}')
    schema = read('Sources/SlateSyncPersistence/SQLiteSchema.swift')
    require('ON DELETE SET NULL' in schema, 'schema foreign key drift')
    db = read('Sources/SlateSyncPersistence/SQLiteDatabase.swift')
    for token in ['PRAGMA journal_mode = WAL', 'PRAGMA foreign_keys = ON', 'PRAGMA busy_timeout = 5000']:
        require(token in db, f'SQLite contract missing: {token}')


def validate_tree(cutover):
    git('merge-base', '--is-ancestor', BASE, 'HEAD')
    for entry in cutover['removed']:
        require(not (ROOT / entry['path']).exists(), f"removed input still exists: {entry['path']}")
        verify_bytes(git('show', f"{BASE}:{entry['path']}"), entry['preCutoverSha256'], entry['path'])
        require(any((ROOT / p).exists() for p in entry['replacement']), 'missing native replacement')
    paths = git('ls-files', '--cached', '--others', '--exclude-standard', '-z').decode().split('\0')
    for path in paths:
        if not path or not (ROOT / path).is_file():
            continue
        if path.startswith(('.codex/', 'Tests/')) or path in ('DESIGN.md', 'UX-CONTRACT.md'):
            continue
        require(not re.search(r'\.(mjs|cjs|js|jsx|ts|tsx)$', path), f'production script residue: {path}')
        require(not path.startswith(('electron/', 'src/', 'lib/', 'public/', 'test/', 'test-support/', '.storybook/')),
                f'legacy path residue: {path}')
        if path.endswith(('.sh', '.zsh')):
            executable_lines = '\n'.join(line for line in (ROOT / path).read_text().splitlines()
                                         if not line.lstrip().startswith('#'))
            require(not re.search(r'(?m)(?:^|\s)(?:node|npm|npx)\s', executable_lines),
                    f'removed interpreter invoked: {path}')


def pass_line(log, reference):
    suite, method = reference.split('/')
    prefix = f"Test Case '-[{suite} {method}]' passed"
    lines = [line.strip() for line in log.splitlines() if prefix in line]
    require(lines, f'missing executed PASS: {reference}')
    return lines[-1]


def validate_metrics(name, value, budget):
    require(value.get('fixtureRows', 10000) == 10000, 'CSV fixture size drift')
    if name == 'native-csv-foreground.json':
        require(value['displayBacked'] is True, 'offscreen cadence is not display evidence')
        require(value['scrollFramesPerSecond'] >= budget['csv10000']['minimumScrollFPS'], 'scroll FPS budget')
        return
    require(value['warmups'] == budget['warmups'] and value['samples'] == budget['samples'], 'sample count drift')
    pairs = {
        'real-sqlite-scale.json': [('projectLoadMs', 'projects500', 'coldLoadMsP95'), ('taskLoadMs', 'tasks1000', 'warmLoadMsP95')],
        'native-project-task-scale.json': [('projectSelectionMs','projects500','selectionRenderMsP95'), ('taskSelectionMs','tasks1000','selectionRenderMsP95'), ('projectVisibleRows','projects500','visibleRowsMax'), ('taskVisibleRows','tasks1000','visibleRowsMax')],
        'native-csv-scale.json': [('snapshotMs','csv10000','snapshotMsP95'), ('farRowEditMs','csv10000','farRowEditMsP95'), ('visibleCellCounts','csv10000','visibleViewsMax'), ('residentDeltaBytes','csv10000','maximumResidentDeltaBytes')],
    }
    require(name in pairs, 'unknown metric')
    if name != 'native-csv-scale.json':
        require(value['projects'] == 500 and value['tasks'] == 1000, 'scale fixture drift')
    for key, group, bound in pairs[name]:
        require(len(value[key]) == budget['samples'], f'missing samples: {key}')
        require(max(value[key]) <= budget[group][bound], f'budget exceeded: {key}')
    if name == 'native-csv-scale.json':
        require(value['retainedResidentBytes'] <= budget['csv10000']['retainedResidentDeltaBytes'], 'retained memory budget')


def validate_execution(result_dir, contract):
    swift = (result_dir / 'swift_test.log').read_text()
    xcode = (result_dir / 'xcode_test_plan_xcodebuild.log').read_text()
    summary = document(result_dir / 'xcode_test_summary.json')
    require(summary['result'].lower() == 'passed' and summary['failedTests'] == 0, 'Xcode failure')
    require(summary['passedTests'] >= contract['requiredXcodeTests'], 'Xcode test coverage shrank')
    # Closure adds a real application path beyond the frozen minimum suite:
    # opening a legacy Library and exporting CSV must execute, not only compile.
    pass_line(xcode, 'SlateSyncUITests.SlateSyncUITests/testLegacyLibraryCSVExportAndReopenInDeliveredApp')
    pass_line(swift, 'SlateSyncPersistenceTests.SM09LegacyPackageTests/testFrozenLegacyPackagesImportEditReopenAndExportWithoutSourceMutation')
    for reference in contract['requiredSwiftTests']:
        pass_line(swift, reference)
    require(re.search(r'SM06_RESOURCES .*active=0 pending=0 processes=0', swift), 'media owners did not drain')
    require(re.search(r'SM06_VISION_SMOKE .*revision=[1-9]', swift), 'native Vision evidence missing')
    plan = json.loads(read('Tests/SlateSyncUIUnitTests/Fixtures/SM09/sm09-native-evidence-plan.json'))
    coverage = json.loads(read('Tests/SlateSyncUIUnitTests/Fixtures/SM08/sm08-coverage.json'))
    require(set(plan) == set(coverage['manualOrGate']) - {'GOV-01'}, 'UI acceptance coverage gap')
    budget = json.loads(read('Tests/SlateSyncUIUnitTests/Fixtures/SM08/performance-budget.json'))
    artifacts = {}
    for name in ['real-sqlite-scale.json', 'native-project-task-scale.json', 'native-csv-scale.json', 'native-csv-foreground.json']:
        value = document(result_dir / 'sm08-metrics' / name)
        validate_metrics(name, value, budget)
        artifacts[name] = value
    # Each acceptance owns its observations and source hashes, preserving all
    # 45 interaction/measurement mappings rather than only static ID names.
    inputs = {p.name: digest(p.read_bytes()) for p in [result_dir/'swift_test.log', result_dir/'xcode_test_plan_xcodebuild.log', result_dir/'xcode_test_summary.json']}
    acceptance = {}
    for key, item in plan.items():
        log = xcode if item['runner'] == 'xcode' else swift
        acceptance[key] = {'result': 'PASS', 'expected': item['expected'],
                           'executedTests': {ref: pass_line(log, ref) for ref in item['tests']},
                           'metrics': {name: artifacts[name] for name in item.get('metrics', [])}}
    report = {'schemaVersion': 1, 'phase': 'SM-09', 'commit': git('rev-parse','HEAD').decode().strip(),
              'sourceInputs': inputs, 'acceptance': acceptance}
    (result_dir / 'native-evidence.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')


def run(result_dir=None, before_removal=False):
    contract = document(MANIFESTS / 'sm09-native-contract.json')
    cutover = document(MANIFESTS / 'sm09-cutover.json')
    seal_bytes = (MANIFESTS/'sm09-final-pre-cutover.json').read_bytes()
    seal = json.loads(seal_bytes)
    result_bytes = (MANIFESTS/'sm09-final-pre-cutover-result.json').read_bytes()
    validate_provenance(cutover, seal, json.loads(result_bytes))
    verify_bytes(seal_bytes, cutover['preCutoverManifestSha256'], 'pre-cutover seal')
    verify_bytes(result_bytes, seal['resultSha256'], 'pre-cutover raw result')
    # The seal itself was committed before removal; changes after that point
    # cannot manufacture new compatibility evidence for the same cutover.
    require(seal_bytes == git('show','1f28a36:.codex/swift-migration/manifests/sm09-final-pre-cutover.json'), 'rewritten seal')
    require(git('rev-parse','HEAD:.codex/refactor').decode().strip() == contract['historyTree'], 'rewritten historical tree')
    require(not git('status','--porcelain','--','.codex/refactor').strip(), 'dirty immutable history')
    validate_fixtures(contract)
    validate_oracles()
    validate_source_boundaries()
    if not before_removal:
        validate_tree(cutover)
    if result_dir:
        validate_execution(result_dir, contract)
    print('SM-09 native provenance, fixtures, ownership and acceptance: PASS')


class ContractTests(unittest.TestCase):
    def test_absent_execution_rejected(self):
        with self.assertRaises(AssertionError):
            pass_line('', 'Suite/testMissing')

    def test_prompt_mutation_rejected(self):
        with self.assertRaises(AssertionError):
            validate_oracles(read('Sources/SlateSyncWorkflow/RecognitionPrompts.swift').replace('影视制作场记单','影视制作场记表'))

    def test_fixture_mutation_rejected(self):
        with self.assertRaises(AssertionError):
            verify_bytes(b'changed', digest(b'original'), 'fixture')

    def test_baseline_failures_and_removal_gaps_rejected(self):
        original = [document(MANIFESTS / name) for name in ['sm09-cutover.json','sm09-final-pre-cutover.json','sm09-final-pre-cutover-result.json']]
        validate_provenance(*original)
        for index, mutate in [
            (0, lambda d: d['removed'].pop()),
            (0, lambda d: d['removed'][0].update(acceptanceIDs=[])),
            (1, lambda d: d.update(commit='0'*40)),
            (1, lambda d: d.update(approvable=False)),
            (2, lambda d: d.update(overallResult='FAIL')),
            (2, lambda d: d.update(checks=[])),
        ]:
            args = copy.deepcopy(original)
            mutate(args[index])
            with self.assertRaises(AssertionError):
                validate_provenance(*args)

    def test_offscreen_or_slow_frame_evidence_rejected(self):
        budget = json.loads(read('Tests/SlateSyncUIUnitTests/Fixtures/SM08/performance-budget.json'))
        for value in [{'fixtureRows':10000,'displayBacked':False,'scrollFramesPerSecond':60},
                      {'fixtureRows':10000,'displayBacked':True,'scrollFramesPerSecond':1}]:
            with self.assertRaises(AssertionError):
                validate_metrics('native-csv-foreground.json', value, budget)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--result-dir', type=Path)
    parser.add_argument('--before-removal', action='store_true')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(ContractTests))
        raise SystemExit(0 if result.wasSuccessful() else 1)
    run(args.result_dir, args.before_removal)
