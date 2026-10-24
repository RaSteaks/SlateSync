#!/usr/bin/env python3
"""Check Release UI scope and require named Debug/Release execution evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
LIST_PATH = ROOT / "script/tests/packaged-ui-release-tests.txt"
SOURCE_PATH = ROOT / "SlateSyncUITests/SlateSyncUITests.swift"
# Keep the existing Provider acceptance floor when deriving any newly added
# fixture cases. Removing a method cannot silently shrink Debug coverage.
REQUIRED_DEBUG_FIXTURES = frozenset({
    "testProviderSetupPersistsDefaultWithoutSecondSave",
    "testBuiltinProviderSetupUsesSameVerificationFlow",
    "testOpenRouterCuratedModelsAndManualVerification",
    "testProviderAuthenticationFailureOffersCredentialRepair",
    "testManualModelFallbackAndSearchPreserveSelection",
    "testProviderCancellationDoesNotEnableUnverifiedModel",
    "testProviderPartialVerificationKeepsSuccessfulModelUsable",
    "testProviderBackupOrderAndDeletionCommitImmediately",
    "testOfflineRefreshReplacesOldProbeFeedbackWithoutRevokingProof",
})


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def validate_scope(source: str, names: list[str]) -> list[str]:
    """A new non-fixture test cannot silently disappear from packaged coverage."""

    require(names and all(re.fullmatch(r"test[A-Za-z0-9_]+", name) for name in names), "invalid packaged UI test list")
    require(len(names) == len(set(names)), "duplicate packaged UI test")
    functions = list(re.finditer(r"^    (?:(?:private|static)\s+)*func (\w+)\([^)]*\)[^{]*\{", source, re.MULTILINE))
    tests, fixtures = [], []
    for index, function in enumerate(functions):
        name = function.group(1)
        if not name.startswith("test"):
            continue
        tests.append(name)
        end = functions[index + 1].start() if index + 1 < len(functions) else len(source)
        if re.search(r"launchIsolatedApp\(\s*providerFixture:\s*true\s*\)", source[function.end():end]):
            fixtures.append(name)
    require(len(tests) == len(set(tests)), "duplicate Swift UI test method")
    expected = set(tests) - set(fixtures)
    require(set(names) == expected,
            f"packaged scope drift: missing={sorted(expected - set(names))}, inapplicable={sorted(set(names) - expected)}")
    require(REQUIRED_DEBUG_FIXTURES <= set(fixtures),
            f"Debug fixture coverage shrank: {sorted(REQUIRED_DEBUG_FIXTURES - set(fixtures))}")
    return sorted(fixtures)


def load_scope() -> tuple[list[str], list[str]]:
    names = [line.split("#", 1)[0].strip() for line in LIST_PATH.read_text().splitlines()]
    names = [name for name in names if name]
    return names, validate_scope(SOURCE_PATH.read_text(), names)


def validate_debug_output(output: str, fixtures: list[str]) -> None:
    # The test harness's DEBUG flag says nothing about the delivered app. Keep
    # every synthetic Provider case mandatory in the ordinary Debug Test Plan.
    for name in fixtures:
        require(f"Test Case '-[SlateSyncUITests.SlateSyncUITests {name}]' passed" in output,
                f"missing executed Debug fixture PASS: {name}")


def test_cases(value: object):
    if isinstance(value, dict):
        if value.get("nodeType") == "Test Case":
            yield value
        for child in value.values():
            yield from test_cases(child)
    elif isinstance(value, list):
        for child in value:
            yield from test_cases(child)


def validate_packaged_results(names: list[str], summary: dict, tree: dict) -> list[str]:
    """Matching counts alone can accept a different set of passing tests."""

    require(summary.get("result", "").lower() == "passed" and summary.get("failedTests") == 0,
            "packaged UI result is not passing")
    require(summary.get("skippedTests") == 0, "packaged UI tests were skipped")
    require(summary.get("passedTests") == summary.get("totalTestCount") == len(names),
            "packaged executed count differs from required scope")
    executed = []
    for case in test_cases(tree):
        identifier = case.get("nodeIdentifier", "")
        match = re.fullmatch(r"SlateSyncUITests/(test[A-Za-z0-9_]+)\(\)", identifier)
        require(match is not None and case.get("result", "").lower() == "passed",
                f"unexpected or non-passing packaged test: {identifier}")
        executed.append(match.group(1))
    require(len(executed) == len(set(executed)), "duplicate packaged test execution")
    require(set(executed) == set(names),
            f"packaged execution drift: missing={sorted(set(names) - set(executed))}, unexpected={sorted(set(executed) - set(names))}")
    return sorted(executed)


def validate_debug_results(names: list[str], fixtures: list[str], summary: dict, tree: dict) -> list[str]:
    # The shared Test Plan must execute every UI case and both app-hosted unit
    # tests. A passing subset or a skipped non-Provider case is not acceptance.
    unit_source = (ROOT / "SlateSyncTests/SlateSyncTests.swift").read_text()
    units = re.findall(r"^    func (test\w+)\(", unit_source, re.MULTILINE)
    require(units, "no app-hosted unit tests declared")
    expected = {f"SlateSyncUITests/{name}()" for name in names + fixtures}
    expected.update(f"SlateSyncTests/{name}()" for name in units)
    require(summary.get("result", "").lower() == "passed" and summary.get("failedTests") == 0,
            "Debug Test Plan result is not passing")
    require(summary.get("skippedTests") == 0, "Debug Test Plan tests were skipped")
    require(summary.get("passedTests") == summary.get("totalTestCount") == len(expected),
            "Debug executed count differs from required scope")
    cases = list(test_cases(tree))
    identifiers = [case.get("nodeIdentifier", "") for case in cases]
    require(len(identifiers) == len(set(identifiers)), "duplicate Debug test execution")
    require(set(identifiers) == expected and all(case.get("result", "").lower() == "passed" for case in cases),
            "Debug named execution coverage differs from required scope")
    return sorted(identifiers)


def verify_results(root: Path, names: list[str], fixtures: list[str], commit: str) -> None:
    validate_debug_output((root / "xcode_test_plan_xcodebuild.log").read_text(), fixtures)
    trees = {}
    # Retain both named execution trees before validating. The Gate itself,
    # including local/full-release invocations, owns coverage, not only CI YAML.
    for bundle, name in [("SlateSync", "xcode_test_plan_tests"), ("Packaged", "packaged_ui_tests")]:
        completed = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests",
                                    "--path", str(root / f"{bundle}.xcresult"), "--format", "json"],
                                   capture_output=True, text=True, check=True)
        (root / f"{name}.json").write_text(completed.stdout)
        trees[bundle] = json.loads(completed.stdout)
    debug = validate_debug_results(names, fixtures, json.loads((root / "xcode_test_summary.json").read_text()),
                                   trees["SlateSync"])
    executed = validate_packaged_results(names, json.loads((root / "packaged_ui_summary.json").read_text()),
                                        trees["Packaged"])
    evidence = {"reviewCommit": commit, "debugTests": debug, "debugFixtureTests": fixtures,
                "packagedReleaseTests": executed, "scopeSha256": hashlib.sha256(LIST_PATH.read_bytes()).hexdigest(),
                "uiTestSourceSha256": hashlib.sha256(SOURCE_PATH.read_bytes()).hexdigest()}
    (root / "ui-scope-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"UI execution coverage: {len(debug)} Debug tests and {len(executed)} packaged Release tests passed")


def verify_gate(gate_root: Path, names: list[str], fixtures: list[str]) -> None:
    results = list(gate_root.glob("*/result.json"))
    require(len(results) == 1, "expected exactly one current Gate result")
    root = results[0].parent
    result = json.loads(results[0].read_text())
    require(result.get("overallResult") == "PASS", "Gate is not passing")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    require(result.get("reviewCommit") == commit, "Gate evidence belongs to a different commit")
    verify_results(root, names, fixtures, commit)


def self_tests(names: list[str], fixtures: list[str]) -> None:
    source = SOURCE_PATH.read_text()
    summary = dict(result="Passed", failedTests=0, skippedTests=0, passedTests=len(names), totalTestCount=len(names))
    tree = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": f"SlateSyncUITests/{name}()", "result": "Passed"} for name in names]}
    debug = "\n".join(f"Test Case '-[SlateSyncUITests.SlateSyncUITests {name}]' passed" for name in fixtures)
    validate_scope(source, names)
    validate_packaged_results(names, summary, tree)
    validate_debug_output(debug, fixtures)
    unit_names = re.findall(r"^    func (test\w+)\(", (ROOT / "SlateSyncTests/SlateSyncTests.swift").read_text(), re.MULTILINE)
    debug_ids = [f"SlateSyncUITests/{name}()" for name in names + fixtures] + [f"SlateSyncTests/{name}()" for name in unit_names]
    debug_tree = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": name, "result": "Passed"} for name in debug_ids]}
    debug_summary = {**summary, "passedTests": len(debug_ids), "totalTestCount": len(debug_ids)}
    validate_debug_results(names, fixtures, debug_summary, debug_tree)
    cases = [
        lambda: validate_debug_results(names, fixtures, {**debug_summary, "skippedTests": 1}, debug_tree),
        lambda: validate_debug_results(names, fixtures, {**debug_summary, "passedTests": 0, "totalTestCount": 0}, {"testNodes": []}),
        lambda: validate_debug_results(names, fixtures, debug_summary, {"testNodes": debug_tree["testNodes"][1:]}),
        lambda: validate_debug_results(names, fixtures, debug_summary, {"testNodes": debug_tree["testNodes"] + [debug_tree["testNodes"][0]]}),
        lambda: validate_debug_results(names, fixtures, debug_summary, {"testNodes": [{**debug_tree["testNodes"][0], "result": "Skipped"}] + debug_tree["testNodes"][1:]}),
        lambda: validate_scope(source, names[1:]),
        lambda: validate_scope(source, names + [names[0]]),
        lambda: validate_scope(source, names + [fixtures[0]]),
        lambda: validate_scope(source + "\n    func testNewDeliveryCase() {}\n", names),
        lambda: validate_scope(source.replace("func " + fixtures[0] + "(", "func removedAcceptanceCase(", 1), names),
        lambda: validate_packaged_results(names, {**summary, "skippedTests": 1}, tree),
        lambda: validate_packaged_results(names, {**summary, "failedTests": 1}, tree),
        lambda: validate_packaged_results(names, {**summary, "passedTests": len(names) - 1}, tree),
        lambda: validate_packaged_results(names, summary, {"testNodes": tree["testNodes"][1:]}),
        lambda: validate_packaged_results(names, summary, {"testNodes": tree["testNodes"] + [tree["testNodes"][0]]}),
        lambda: validate_packaged_results(names, summary, {"testNodes": tree["testNodes"][1:] + [
            {"nodeType": "Test Case", "nodeIdentifier": "SlateSyncUITests/testDifferentPassingCase()", "result": "Passed"}]}),
        lambda: validate_debug_output(debug.replace(f"Test Case '-[SlateSyncUITests.SlateSyncUITests {fixtures[0]}]' passed", ""), fixtures),
    ]
    for index, case in enumerate(cases, 1):
        try:
            case()
        except AssertionError:
            continue
        raise AssertionError(f"UI coverage negative fixture {index} unexpectedly passed")
    print(f"UI coverage contract self-tests: {len(cases)} negative cases passed; positive coverage passed")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--gate-root", type=Path)
    source.add_argument("--result-dir", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    names, fixtures = load_scope()
    if args.self_test:
        self_tests(names, fixtures)
    if args.gate_root:
        verify_gate(args.gate_root, names, fixtures)
    elif args.result_dir:
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        verify_results(args.result_dir, names, fixtures, commit)
    else:
        print(f"UI scope: {len(fixtures)} Debug fixtures; {len(names)} packaged Release tests")


if __name__ == "__main__":
    main()
