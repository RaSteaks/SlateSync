#!/usr/bin/env python3
"""Validate retained provenance and executed native acceptance after cutover.

Historical sources are read from the verified Git object, never executed.
Retained copies permit only the pinned privacy projection of those bytes.
The baseline test list is a minimum: new tests still run in the full suite.
"""
import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
from functools import lru_cache
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
MANIFESTS = ROOT / '.codex/swift-migration/manifests'
CURRENT_ACCEPTANCE = ROOT / 'script/fixtures/sm09-current-acceptance.json'
HISTORICAL_PLAN = ROOT / 'Tests/SlateSyncUIUnitTests/Fixtures/SM09/sm09-native-evidence-plan.json'
PERFORMANCE_ONLY_TESTS = frozenset({'SlateSyncUIUnitTests.SM08NativeSurfaceTests/testForegroundCSVMeetsDisplayCadenceBudget'})

BASE = '52b2a78f6619145b0999bdccf588d83a95349e7c'
# Pin the reviewed byte-range projection independently of the historical seal.
# Neither original personal values nor a general-purpose redaction exemption
# belongs in the current tree; all non-redacted evidence remains byte-exact.
PRIVACY_PROJECTION_SHA256 = 'efd4368626e48888a5afe60e14d43f556cadb77071b1514c8b481d67ade65395'


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


def project_private_evidence(original, entry):
    verify_bytes(original, entry['sourceSha256'], 'privacy source')
    # Ranges address original UTF-8 bytes; earlier replacements never shift
    # later ranges, and the output hash forbids incidental normalization.
    parts = []
    cursor = 0
    for edit in entry['edits']:
        start, end = edit['offset'], edit['offset'] + edit['length']
        require(cursor <= start < end <= len(original), 'invalid privacy byte range')
        parts.extend([original[cursor:start], edit['replacement'].encode('utf-8')])
        cursor = end
    projected = b''.join(parts + [original[cursor:]])
    verify_bytes(projected, entry['sanitizedSha256'], 'privacy projection')
    return projected


def history_entries(reference):
    entries = {}
    for record in git('ls-tree', '-r', '-z', reference, '--', '.codex/refactor').split(b'\0'):
        if not record:
            continue
        metadata, path = record.decode().split('\t', 1)
        mode, kind, oid = metadata.split()
        require(kind == 'blob', 'non-file historical entry')
        entries[path] = (mode, oid)
    return entries


def validate_retained_evidence(contract, cutover):
    projection_bytes = (MANIFESTS / 'sm09-privacy-projection.json').read_bytes()
    verify_bytes(projection_bytes, PRIVACY_PROJECTION_SHA256, 'privacy policy')
    projection = json.loads(projection_bytes)
    source = projection['sourceCommit']
    require(git('rev-parse', f'{source}:.codex/refactor').decode().strip() == contract['historyTree'],
            'rewritten historical source tree')

    seal_bytes = (MANIFESTS / 'sm09-final-pre-cutover.json').read_bytes()
    seal = json.loads(seal_bytes)
    verify_bytes(seal_bytes, cutover['preCutoverManifestSha256'], 'pre-cutover seal')
    require(seal_bytes == git('show', '1f28a36:.codex/swift-migration/manifests/sm09-final-pre-cutover.json'),
            'rewritten seal')
    result_path = '.codex/swift-migration/manifests/sm09-final-pre-cutover-result.json'
    original_result = git('show', f'{source}:{result_path}')
    verify_bytes(original_result, seal['resultSha256'], 'pre-cutover raw result')
    result_bytes = (ROOT / result_path).read_bytes()
    require(result_bytes == project_private_evidence(original_result, projection['files'][result_path]),
            'rewritten projected result')

    # Check every original file, including binaries and modes. Only the five
    # pinned privacy edits may differ; additions/deletions remain failures.
    original_entries = history_entries(source)
    allowed = {}
    for path, (mode, oid) in original_entries.items():
        original = git('cat-file', 'blob', oid)
        entry = projection['files'].get(path)
        expected = project_private_evidence(original, entry) if entry else original
        file = ROOT / path
        require(not file.is_symlink() and file.is_file(), f'missing historical file: {path}')
        require(file.read_bytes() == expected, f'rewritten historical file: {path}')
        require(bool(file.stat().st_mode & 0o111) == (mode == '100755'), f'historical mode drift: {path}')
        expected_oid = subprocess.check_output(['git', 'hash-object', '--stdin'], input=expected).decode().strip() if entry else oid
        allowed[path] = (mode, {oid, expected_oid})

    paths = set(filter(None, git('ls-files', '--cached', '--others', '--exclude-standard', '-z',
                                '--', '.codex/refactor').decode().split('\0')))
    require(paths == set(original_entries), 'historical file set drift')
    index = {}
    for record in git('ls-files', '--stage', '-z', '--', '.codex/refactor').split(b'\0'):
        if record:
            metadata, path = record.decode().split('\t', 1)
            mode, oid, stage = metadata.split()
            require(stage == '0', 'unmerged historical entry')
            index[path] = (mode, oid)
    # HEAD/index can retain the original during this uncommitted migration, or
    # contain its exact projection after staging/commit. A dirty working copy
    # must never conceal unrelated changes in either Git snapshot.
    for label, snapshot in [('HEAD', history_entries('HEAD')), ('index', index)]:
        require(set(snapshot) == set(allowed), f'{label} historical file set drift')
        for path, (mode, oid) in snapshot.items():
            expected_mode, expected_oids = allowed[path]
            require(mode == expected_mode and oid in expected_oids, f'{label} historical drift: {path}')
    return seal, json.loads(result_bytes)


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


# These six Owner decisions have distinct destinations; a generic existing
# file cannot stand in for an archive, configuration store or OCR service.
DECISION_REPLACEMENTS = {'.env.example': (['Sources/SlateSyncPersistence/GlobalConfigStore.swift',
                   'Tests/SlateSyncPersistenceTests/ConfigurationStoreTests.swift'],
                  ['CUT-01', 'CUT-02']),
 'build/entitlements.mac.plist': (['SlateSyncApp/SlateSync.entitlements',
                                   'script/verify_bundle.sh'],
                                  ['CUT-01', 'CUT-02', 'SIG-01']),
 'premium-ui.json': (['.codex/swift-migration/manifests/sm09-premium-ui-history.json'],
                     ['CUT-01', 'CUT-02']),
 'scripts/setup-paddleocr.sh': (['Sources/SlateSyncWorkflow/PaddleOCRInstallerService.swift',
                                 'Tests/SlateSyncUIUnitTests/SM08OwnershipTests.swift'],
                                ['CUT-01', 'CUT-02', 'CUT-05']),
 'scripts/vision_ocr.swift': (['Sources/SlateSyncMedia/VisionOCRService.swift',
                               'Tests/SlateSyncMediaTests/OCRContractTests.swift'],
                              ['CUT-01', 'CUT-02']),
 'slatesync.config.json': (['Sources/SlateSyncPersistence/ConfigurationResolver.swift',
                            'Tests/SlateSyncPersistenceTests/ConfigurationStoreTests.swift'],
                           ['CUT-01', 'CUT-02'])}


def validate_decisions(cutover):
    entries = {e['path']: e for e in cutover['removed']}
    for path, (replacements, acceptance) in DECISION_REPLACEMENTS.items():
        entry = entries[path]
        require(entry['replacement'] == replacements, f'incorrect decision replacement: {path}')
        require(entry['acceptanceIDs'] == acceptance, f'incorrect decision acceptance: {path}')
        require(all((ROOT / p).is_file() for p in replacements), f'missing decision destination: {path}')
        require(not re.search('待引用|需决策|需 Owner|确认后|确认是否|确认归档', entry['reason']), 'unresolved decision')
    archive = entries['premium-ui.json']
    verify_bytes((ROOT / archive['replacement'][0]).read_bytes(), archive['preCutoverSha256'], 'archived premium UI')


def validate_coverage(attestation, seal, coverage_bytes):
    require(attestation['status'] == seal['status'] == 'PASS', 'coverage not attested')
    require(attestation['commit'] == seal['commit'] == BASE, 'coverage commit drift')
    require(attestation['coverageSha256'] == seal['coverageSha256'], 'coverage seal mismatch')
    require(attestation['coveragePath'] == '.codex/swift-migration/manifests/sm09-coverage.json', 'coverage path drift')
    verify_bytes(coverage_bytes, seal['coverageSha256'], 'final coverage snapshot')


def validate_fixtures(contract):
    require(set(contract['fixtureSourceCommits']) == set(contract['fixtureSha256']), 'fixture provenance gap')
    for path, expected in contract['fixtureSha256'].items():
        commit = contract['fixtureSourceCommits'][path]
        git('merge-base', '--is-ancestor', commit, 'HEAD')
        verify_bytes(git('show', f'{commit}:{path}'), expected, f'fixture origin: {path}')
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
    # Window/editor probes and the prepared-JPEG display are narrow AppKit
    # boundaries. Appearance reveal only snapshots this window and masks its
    # old pixels; content reveal instead clips two live pages and uses a clear
    # native input shield, without pixel capture or duplicate toolbar ownership.
    # The image layer owns no media parsing. Keep this allowlist exact so new
    # bridges require review.
    require(bridges == ['Sources/SlateSyncUI/App/WindowLifecycleBridge.swift',
                        'Sources/SlateSyncUI/CSV/EditableCSVTableRepresentable.swift',
                        'Sources/SlateSyncUI/Components/AppearanceTransition.swift',
                        'Sources/SlateSyncUI/Components/ContentMotion.swift',
                        'Sources/SlateSyncUI/Components/WindowMinimumSize.swift',
                        'Sources/SlateSyncUI/Workspace/MediaPreviewView.swift',
                        'Sources/SlateSyncUI/Workspace/WorkspaceEditorBoundary.swift'], 'AppKit bridge allowlist drift')
    commands = read('Sources/SlateSyncUI/App/FocusedActions.swift')
    require('NSApp.keyWindow?.performClose(nil)' in commands, 'current-window close missing')
    require(commands.count('.keyboardShortcut("s"') == 1, 'Save command ownership drift')
    app = read('SlateSyncApp/App/SlateSyncApp.swift')
    # The minimum now includes measured native chrome instead of adding it to
    # 600 points of content; assert the public outer-window contract.
    for token in ['WindowGroup', 'Settings {', '.slateWindowMinimumSize(width: 960, height: 600)',
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


def test_source_path(reference):
    require(re.fullmatch(r'\w+\.\w+/test\w+', reference), f'invalid test reference: {reference}')
    target, suite = reference.split('/')[0].split('.')
    folder = ROOT / target if target == 'SlateSyncUITests' else ROOT / 'Tests' / target
    return folder / f'{suite}.swift'


def source_has_test(source, reference):
    suite, method = reference.split('/')[0].split('.')[1], reference.split('/')[1]
    # This is a fast source-presence check, not execution evidence. The actual
    # log must still contain each named PASS, including in functional mode.
    source = re.sub(r'/\*.*?\*/|//[^\n]*', '', source, flags=re.DOTALL)
    return (re.search(r'\bclass\s+' + re.escape(suite) + r'\s*:\s*XCTestCase\b', source) is not None
            and re.search(r'^\s*func\s+' + re.escape(method) + r'\s*\(\s*\)', source, re.MULTILINE) is not None)


@lru_cache(maxsize=None)
def historical_test_source(commit, path):
    # A deleted file is expected after an approved retirement; other Git errors
    # must remain fatal. The parent proves the old test existed at the decision.
    if not git('ls-tree', '--name-only', commit, '--', path).strip():
        return ''
    return git('show', f'{commit}:{path}').decode()


def current_acceptance(contract, evolution=None):
    """Apply explicit decisions without rewriting sealed fixtures or history."""
    evolution = document(CURRENT_ACCEPTANCE) if evolution is None else evolution
    require(evolution.get('schemaVersion') == 1, 'unsupported current acceptance schema')
    plan = document(HISTORICAL_PLAN)
    baseline = contract['requiredSwiftTests']
    transitions = evolution['testTransitions']
    require(set(transitions) <= set(baseline), 'transition outside baseline')
    decisions = set()
    for reference, change in transitions.items():
        commit = change.get('decisionCommit', '')
        require(re.fullmatch(r'[0-9a-f]{40}', commit) and change.get('reason', '').strip(),
                f'missing decision evidence: {reference}')
        if commit not in decisions:
            git('merge-base', '--is-ancestor', commit, 'HEAD')
            decisions.add(commit)
        path = str(test_source_path(reference).relative_to(ROOT))
        require(source_has_test(historical_test_source(commit + '^', path), reference),
                f'decision did not own original test: {reference}')
        require(not source_has_test(historical_test_source(commit, path), reference),
                f'decision did not remove original test: {reference}')
        status, replacement = change.get('status'), change.get('replacement')
        require(status in ('moved', 'revised', 'retired'), f'invalid transition: {reference}')
        if status == 'retired':
            # Retirement is narrowly authorized for the removed Provider import
            # path; unrelated tests cannot be waived by adding an empty mapping.
            require(commit == '41fa10bf54c2ca111ab43b7888c0f8c85ec8efe8' and replacement is None
                    and (reference.startswith('SlateSyncPersistenceTests.KeychainMigrationTests/')
                         or reference in {
                             'SlateSyncPersistenceTests.SlateSyncRuntimeTests/testBootstrapMigratesLegacyCredentialsThroughTheInjectedBackend',
                             'SlateSyncPersistenceTests.SlateSyncRuntimeTests/testMigrationFailureIsNonBlockingSecretFreeAndRetryable'}),
                    f'unauthorized retirement: {reference}')
            require(not reference.endswith(('testConditionalDeletePreservesAValueChangedByAnotherWriter',
                                            'testCreateIfAbsentReturnsOwnershipAndRejectsWrongOwnerCompensation')),
                    'shared Keychain ownership cannot retire')
        else:
            require(isinstance(replacement, str) and replacement != reference, f'missing successor: {reference}')
            replacement_path = str(test_source_path(replacement).relative_to(ROOT))
            require(source_has_test(historical_test_source(commit, replacement_path), replacement),
                    f'successor absent from decision: {replacement}')

    additional = evolution['requiredAdditionalTests']
    require(additional and len(additional) == len(set(additional)), 'empty or duplicate current credential coverage')
    # Keep the current storage safety floor even if an acceptance entry is edited.
    credential_floor = {
        'SlateSyncPersistenceTests.EncryptedFileCredentialStoreTests/' + name for name in (
            'testRoundTripRestartNoncePermissionsAndDeletion', 'testTamperingAndMissingKeyNeverOverwriteVault',
            'testIndependentStoresSerializeReadModifyWrite', 'testSymlinkAndUnsafeFileRejection',
            'testFailedPayloadWritePreservesPreviousCredentials', 'testCancellationWhileWaitingForLockPreservesVault',
            'testQueuedCancellationAndCancellationAfterCommitBoundary', 'testMissingMasterKeyAndAccessFailuresRemainDistinct',
            'testBatchUsesOneSnapshotAndPreservesMissingProviders', 'testLockTimeoutIsTransientAndBatchWaitsOnlyOnce',
            'testAnotherProcessHoldingLockCanRecoverWithoutReset')}
    credential_floor.add('SlateSyncPersistenceTests.SlateSyncRuntimeTests/testProviderFileStorageNeverReadsOrMigratesOldSecrets')
    require(credential_floor <= set(additional), 'current credential coverage shrank')
    required = [transitions.get(ref, {}).get('replacement', ref) for ref in baseline]
    required = [ref for ref in required if ref is not None] + additional
    require(len(required) == len(set(required)), 'duplicate effective required test')
    for key, item in plan.items():
        item['tests'] = [transitions.get(ref, {}).get('replacement', ref) for ref in item['tests']]
        item['tests'] = [ref for ref in item['tests'] if ref is not None]
    for key, update in evolution['acceptanceUpdates'].items():
        require(key in plan and update.get('decisionCommit') in decisions and update.get('expected', '').strip(),
                f'invalid acceptance decision: {key}')
        require(set(update) <= {'decisionCommit', 'expected', 'tests'}, f'unsupported acceptance override: {key}')
        plan[key].update({k: v for k, v in update.items() if k != 'decisionCommit'})
    require(set(additional) <= set(plan['SET-02']['tests']), 'SET-02 omits current credential coverage')
    require('queue' in plan['REC-05']['expected'].lower() and 'fail-fast' not in plan['REC-05']['expected'].lower(),
            'REC-05 still describes retired admission policy')
    coverage = document(ROOT / 'Tests/SlateSyncUIUnitTests/Fixtures/SM08/sm08-coverage.json')
    require(set(plan) == set(coverage['manualOrGate']) - {'GOV-01'}, 'UI acceptance coverage gap')
    references = set(required)
    for key, item in plan.items():
        require(item['runner'] in ('swift', 'xcode') and item['tests'], f'empty acceptance: {key}')
        require(len(item['tests']) == len(set(item['tests'])), f'duplicate acceptance test: {key}')
        require(all(ref.startswith('SlateSyncUITests.') == (item['runner'] == 'xcode') for ref in item['tests']),
                f'wrong acceptance runner: {key}')
        references.update(item['tests'])
    sources, missing = {}, []
    for ref in sorted(references):
        path = test_source_path(ref)
        if path not in sources:
            sources[path] = path.read_text() if path.is_file() else ''
        if not source_has_test(sources[path], ref):
            missing.append(ref)
    require(not missing, 'missing current test declarations:\n' + '\n'.join(missing))
    return {**contract, 'requiredSwiftTests': required}, plan, evolution


def validate_metrics(name, value, budget, enforce_timing=True):
    require(value.get('fixtureRows', 10000) == 10000, 'CSV fixture size drift')
    if name == 'native-csv-foreground.json':
        require(value['displayBacked'] is True, 'offscreen cadence is not display evidence')
        if enforce_timing:
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
        # Functional CI still enforces sample/fixture shape, virtualization and memory.
        if enforce_timing or not bound.endswith('MsP95'):
            require(max(value[key]) <= budget[group][bound], f'budget exceeded: {key}')
    if name == 'native-csv-scale.json':
        require(value['retainedResidentBytes'] <= budget['csv10000']['retainedResidentDeltaBytes'], 'retained memory budget')


def validate_execution(result_dir, contract, functional=False, replay_commit=None):
    contract, plan, evolution = current_acceptance(contract)
    head = git('rev-parse', 'HEAD').decode().strip()
    if replay_commit:
        # Replays consume copies of a recorded run and never claim evidence for
        # the candidate commit. The original run result supplies the source SHA.
        require(re.fullmatch(r'[0-9a-f]{40}', replay_commit), 'invalid replay commit')
        require(document(result_dir / 'result.json')['reviewCommit'] == replay_commit, 'replay source commit mismatch')
        git('merge-base', '--is-ancestor', replay_commit, 'HEAD')
    swift = (result_dir / 'swift_test.log').read_text()
    xcode = (result_dir / 'xcode_test_plan_xcodebuild.log').read_text()
    summary = document(result_dir / 'xcode_test_summary.json')
    require(summary['result'].lower() == 'passed' and summary['failedTests'] == 0, 'Xcode failure')
    require(summary['passedTests'] >= contract['requiredXcodeTests'], 'Xcode test coverage shrank')
    # Closure adds a real application path beyond the frozen minimum suite:
    # opening a legacy Library and exporting CSV must execute, not only compile.
    pass_line(xcode, 'SlateSyncUITests.SlateSyncUITests/testLegacyLibraryCSVExportAndReopenInDeliveredApp')
    pass_line(swift, 'SlateSyncPersistenceTests.SM09LegacyPackageTests/testFrozenLegacyPackagesImportEditReopenAndExportWithoutSourceMutation')
    deferred = PERFORMANCE_ONLY_TESTS if functional else frozenset()
    for reference in contract['requiredSwiftTests']:
        if reference not in deferred:
            pass_line(swift, reference)
    require(re.search(r'SM06_RESOURCES .*active=0 pending=0 processes=0', swift), 'media owners did not drain')
    require(re.search(r'SM06_VISION_SMOKE .*revision=[1-9]', swift), 'native Vision evidence missing')
    budget = json.loads(read('Tests/SlateSyncUIUnitTests/Fixtures/SM08/performance-budget.json'))
    artifacts = {}
    for name in ['real-sqlite-scale.json', 'native-project-task-scale.json', 'native-csv-scale.json', 'native-csv-foreground.json']:
        if functional and name == 'native-csv-foreground.json':
            continue
        value = document(result_dir / 'sm08-metrics' / name)
        validate_metrics(name, value, budget, enforce_timing=not functional)
        artifacts[name] = value
    # Each acceptance owns its observations and source hashes, preserving all
    # 45 interaction/measurement mappings rather than only static ID names.
    inputs = {p.name: digest(p.read_bytes()) for p in [result_dir/'swift_test.log', result_dir/'xcode_test_plan_xcodebuild.log', result_dir/'xcode_test_summary.json']}
    if replay_commit:
        inputs['result.json'] = digest((result_dir / 'result.json').read_bytes())
    acceptance = {}
    for key, item in plan.items():
        log = xcode if item['runner'] == 'xcode' else swift
        deferred_tests = [ref for ref in item['tests'] if ref in deferred]
        acceptance[key] = {
            'result': 'FUNCTIONAL_ONLY' if functional and (deferred_tests or item.get('metrics')) else 'PASS',
            'expected': item['expected'],
            'executedTests': {ref: pass_line(log, ref) for ref in item['tests'] if ref not in deferred},
            'deferredTests': deferred_tests,
            'metrics': {name: artifacts[name] for name in item.get('metrics', [])
                        if not functional or name != 'native-csv-foreground.json'}}
    report = {'schemaVersion': 2, 'phase': 'SM-09', 'commit': head,
              'executionMode': 'offline-replay' if replay_commit else 'native-gate',
              'evidenceCommit': replay_commit or head,
              'scope': 'functional' if functional else 'full',
              'performancePolicy': 'advisory' if functional else 'required',
              'completeAcceptance': not functional and not replay_commit,
              'contractInputs': {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in
                                 [Path(__file__), CURRENT_ACCEPTANCE, HISTORICAL_PLAN, MANIFESTS / 'sm09-native-contract.json']},
              'testTransitions': evolution['testTransitions'],
              'sourceInputs': inputs, 'acceptance': acceptance}
    (result_dir / 'native-evidence.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')


def run(result_dir=None, before_removal=False, functional=False, replay_commit=None):
    contract = document(MANIFESTS / 'sm09-native-contract.json')
    cutover = document(MANIFESTS / 'sm09-cutover.json')
    seal, result = validate_retained_evidence(contract, cutover)
    validate_provenance(cutover, seal, result)
    validate_decisions(cutover)
    validate_coverage(document(MANIFESTS / 'sm09-final-coverage-attestation.json'), seal,
                      (MANIFESTS / 'sm09-coverage.json').read_bytes())
    validate_fixtures(contract)
    validate_oracles()
    validate_source_boundaries()
    # Detect stale references before any Swift build or foreground CI work.
    current_acceptance(contract)
    if not before_removal:
        validate_tree(cutover)
    if result_dir:
        validate_execution(result_dir, contract, functional=functional, replay_commit=replay_commit)
    print('SM-09 offline replay: PASS (not current-commit CI acceptance)' if replay_commit else
          'SM-09 native functional coverage (timing advisory): PASS' if functional else
          'SM-09 native provenance, fixtures, ownership and acceptance: PASS')


class PrivacyProjectionTests(unittest.TestCase):
    def setUp(self):
        # A local shared clone supplies real immutable Git objects and an
        # isolated index. Mutations never touch the developer's worktree.
        temporary = tempfile.TemporaryDirectory(prefix='slatesync-privacy-')
        self.addCleanup(temporary.cleanup)
        fixture = Path(temporary.name) / 'repo'
        subprocess.run(['git', 'clone', '--quiet', '--shared', '--no-checkout', str(ROOT), str(fixture)], check=True)
        subprocess.run(['git', '-C', str(fixture), 'read-tree', 'HEAD'], check=True)
        for relative in filter(None, git('ls-files', '-z', '--', '.codex/refactor').decode().split('\0')):
            destination = fixture / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
            shutil.copymode(ROOT / relative, destination)
        manifests = fixture / '.codex/swift-migration/manifests'
        manifests.mkdir(parents=True)
        for name in ['sm09-native-contract.json', 'sm09-cutover.json', 'sm09-final-pre-cutover.json',
                     'sm09-final-pre-cutover-result.json', 'sm09-privacy-projection.json']:
            shutil.copyfile(MANIFESTS / name, manifests / name)
        for name, value in [('ROOT', fixture), ('MANIFESTS', manifests)]:
            patched = patch(__name__ + '.' + name, value)
            patched.start()
            self.addCleanup(patched.stop)
        self.contract = document(MANIFESTS / 'sm09-native-contract.json')
        self.cutover = document(MANIFESTS / 'sm09-cutover.json')

    def validate(self):
        return validate_retained_evidence(self.contract, self.cutover)

    def test_original_index_and_staged_projection_preserve_baseline(self):
        seal, result = self.validate()
        validate_provenance(self.cutover, seal, result)
        original = json.loads(git('show', document(MANIFESTS / 'sm09-privacy-projection.json')['sourceCommit']
                                  + ':.codex/swift-migration/manifests/sm09-final-pre-cutover-result.json'))
        # Every check result, timing and overall approval is identical. Only
        # the machine-specific prefix of each log locator was removed.
        for check, before in zip(result['checks'], original['checks']):
            self.assertEqual({k: v for k, v in check.items() if k != 'log'},
                             {k: v for k, v in before.items() if k != 'log'})
            if before.get('log'):
                self.assertTrue(before['log'].endswith(check['log']))
        self.assertEqual({k: v for k, v in result.items() if k != 'checks'},
                         {k: v for k, v in original.items() if k != 'checks'})
        git('add', '--', '.codex/refactor')
        self.validate()

    def test_redacted_and_unredacted_history_still_reject_content_drift(self):
        for relative in ['.codex/refactor/DECISION_QUEUE.md', '.codex/refactor/baseline/contracts/environment.json']:
            with self.subTest(path=relative):
                path = ROOT / relative
                original = path.read_bytes()
                path.write_bytes(original + b'\nchanged evidence\n')
                with self.assertRaisesRegex(AssertionError, 'rewritten historical file'):
                    self.validate()
                path.write_bytes(original)

    def test_private_values_cannot_be_restored_to_current_history(self):
        relative = '.codex/refactor/DECISION_QUEUE.md'
        source = document(MANIFESTS / 'sm09-privacy-projection.json')['sourceCommit']
        (ROOT / relative).write_bytes(git('show', f'{source}:{relative}'))
        with self.assertRaisesRegex(AssertionError, 'rewritten historical file'):
            self.validate()

    def test_added_deleted_symlink_and_mode_changes_are_rejected(self):
        added = ROOT / '.codex/refactor/unreviewed.md'
        added.write_text('unreviewed')
        with self.assertRaisesRegex(AssertionError, 'historical file set drift'):
            self.validate()
        added.unlink()
        path = ROOT / '.codex/refactor/DECISION_QUEUE.md'
        original = path.read_bytes()
        path.unlink()
        with self.assertRaisesRegex(AssertionError, 'missing historical file'):
            self.validate()
        path.symlink_to('missing-target')
        with self.assertRaisesRegex(AssertionError, 'missing historical file'):
            self.validate()
        path.unlink()
        path.write_bytes(original)
        path.chmod(0o755)
        with self.assertRaisesRegex(AssertionError, 'historical mode drift'):
            self.validate()

    def test_clean_working_copy_cannot_hide_staged_evidence_changes(self):
        path = ROOT / '.codex/refactor/DECISION_QUEUE.md'
        original = path.read_bytes()
        path.write_bytes(original + b'\nstaged evidence alteration\n')
        git('add', '--', str(path))
        path.write_bytes(original)
        with self.assertRaisesRegex(AssertionError, 'index historical drift'):
            self.validate()

    def test_result_policy_and_seal_changes_remain_failures(self):
        for name, expected in [('sm09-final-pre-cutover-result.json', 'rewritten projected result'),
                               ('sm09-privacy-projection.json', 'hash drift: privacy policy'),
                               ('sm09-final-pre-cutover.json', 'hash drift: pre-cutover seal')]:
            with self.subTest(path=name):
                path = MANIFESTS / name
                original = path.read_bytes()
                path.write_bytes(original + b' ')
                with self.assertRaisesRegex(AssertionError, expected):
                    self.validate()
                path.write_bytes(original)
        path = MANIFESTS / 'sm09-final-pre-cutover-result.json'
        result = document(path)
        result['checks'][0]['result'] = 'FAIL'
        path.write_text(json.dumps(result))
        with self.assertRaisesRegex(AssertionError, 'rewritten projected result'):
            self.validate()


class ContractTests(unittest.TestCase):
    def test_current_mapping_preserves_baseline_and_retirement_evidence(self):
        baseline = document(MANIFESTS / 'sm09-native-contract.json')
        before = copy.deepcopy(baseline)
        effective, plan, evolution = current_acceptance(baseline)
        self.assertEqual(baseline, before)
        self.assertEqual(len(evolution['testTransitions']), 16)
        self.assertEqual(sum(v['status'] == 'retired' for v in evolution['testTransitions'].values()), 12)
        self.assertEqual(len(effective['requiredSwiftTests']), 235)
        self.assertEqual(len(plan), len(document(HISTORICAL_PLAN)))
        untouched = set(baseline['requiredSwiftTests']) - set(evolution['testTransitions'])
        self.assertTrue(untouched <= set(effective['requiredSwiftTests']))

    def test_unresolved_references_report_all_missing_declarations(self):
        baseline = document(MANIFESTS / 'sm09-native-contract.json')
        evolution = document(CURRENT_ACCEPTANCE)
        evolution['testTransitions'] = {}
        # Retain a coherent current plan so the declaration check can report
        # all old baseline references together before any expensive execution.
        evolution['acceptanceUpdates'] = {}
        document_original = document
        plan = document(HISTORICAL_PLAN)
        with patch(__name__ + '.document') as read_document:
            plan['REC-05']['tests'] = ['SlateSyncMediaTests.OCRPolicyTests/testRequiredOptionalDisabledAndCancellationPolicies']
            plan['REC-05']['expected'] = 'queued admission and cancellation'
            plan['SET-02']['tests'] = evolution['requiredAdditionalTests']
            read_document.side_effect = lambda path: plan if path == HISTORICAL_PLAN else document_original(path)
            with self.assertRaisesRegex(AssertionError, 'missing current test declarations') as failure:
                current_acceptance(baseline, evolution)
        self.assertIn('testCancellationCompensatesCreatedItemsAndPreservesLegacySource', str(failure.exception))
        self.assertIn('testFLW05FLW07GlobalFailFastAndProjectCancellationDrain', str(failure.exception))

    def test_invalid_decisions_and_coverage_reductions_rejected(self):
        baseline = document(MANIFESTS / 'sm09-native-contract.json')
        original = document(CURRENT_ACCEPTANCE)
        moved = next(ref for ref, value in original['testTransitions'].items() if value['status'] == 'moved')
        retired = next(ref for ref, value in original['testTransitions'].items() if value['status'] == 'retired')
        mutations = [
            lambda value: value['testTransitions'][retired].update(reason=''),
            lambda value: value['testTransitions'][retired].update(decisionCommit='22e351ff1c03ae9f1821f3581784aa2269862fb4'),
            lambda value: value['testTransitions'][moved].update(status='retired', replacement=None),
            lambda value: value['testTransitions'][moved].update(replacement='SlateSyncPersistenceTests.KeychainBackendTests/testMissing'),
            lambda value: value['requiredAdditionalTests'].pop(),
            lambda value: value['acceptanceUpdates']['SET-02'].update(tests=[]),
            lambda value: value['acceptanceUpdates'].pop('REC-05'),
        ]
        for mutate in mutations:
            value = copy.deepcopy(original)
            mutate(value)
            with self.assertRaises((AssertionError, subprocess.CalledProcessError)):
                current_acceptance(baseline, value)

    def test_deleted_current_successor_is_caught_before_execution(self):
        baseline = document(MANIFESTS / 'sm09-native-contract.json')
        read_text = Path.read_text
        def without_test(path, *args, **kwargs):
            source = read_text(path, *args, **kwargs)
            if path.name == 'KeychainBackendTests.swift':
                return source.replace('func testConditionalDeletePreservesAValueChangedByAnotherWriter(', 'func removedTest(')
            return source
        with patch.object(Path, 'read_text', without_test):
            with self.assertRaisesRegex(AssertionError, 'missing current test declarations'):
                current_acceptance(baseline)

    def test_decision_mapping_mutations_rejected(self):
        original = document(MANIFESTS / 'sm09-cutover.json')
        validate_decisions(original)
        for path in DECISION_REPLACEMENTS:
            for field, value in [('replacement', ['SlateSyncApp/SlateSync.entitlements']),
                                 ('acceptanceIDs', ['CUT-05']), ('reason', '确认后删除')]:
                changed = copy.deepcopy(original)
                next(e for e in changed['removed'] if e['path'] == path)[field] = value
                with self.assertRaises(AssertionError, msg=f'{path}: {field}'):
                    validate_decisions(changed)

    def test_coverage_attestation_mutations_rejected(self):
        attestation = document(MANIFESTS / 'sm09-final-coverage-attestation.json')
        seal = document(MANIFESTS / 'sm09-final-pre-cutover.json')
        data = (MANIFESTS / 'sm09-coverage.json').read_bytes()
        validate_coverage(attestation, seal, data)
        for field, value in [('status', 'PENDING'), ('commit', '0'*40), ('coverageSha256', '0'*64)]:
            changed = dict(attestation, **{field: value})
            with self.assertRaises(AssertionError):
                validate_coverage(changed, seal, data)
        with self.assertRaises(AssertionError):
            validate_coverage(attestation, seal, data + b' ')

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
    parser.add_argument('--functional', action='store_true', help='Validate merge coverage; defer timing budgets explicitly')
    parser.add_argument('--replay-commit', help='Original evidence SHA; replay in a copied result directory without claiming current CI acceptance')
    args = parser.parse_args()
    if args.replay_commit and not args.result_dir:
        parser.error('--replay-commit requires --result-dir')
    if args.self_test:
        suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(case)
                                   for case in [ContractTests, PrivacyProjectionTests])
        result = unittest.TextTestRunner().run(suite)
        raise SystemExit(0 if result.wasSuccessful() else 1)
    run(args.result_dir, args.before_removal, args.functional, args.replay_commit)
