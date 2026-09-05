#!/bin/zsh
set -uo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h:h}"
source "${project_root}/script/lib/phase_gate_lib.sh"

passed=0
failed=0
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/slatesync-phase-gate-tests.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

assert_success() {
  local name="$1"
  shift
  if "$@"; then
    print -r -- "PASS: ${name}"
    (( passed += 1 ))
  else
    print -u2 -r -- "FAIL: ${name}"
    (( failed += 1 ))
  fi
}

assert_failure() {
  local name="$1"
  shift
  if "$@"; then
    print -u2 -r -- "FAIL: ${name}"
    (( failed += 1 ))
  else
    print -r -- "PASS: ${name}"
    (( passed += 1 ))
  fi
}

assert_equal() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    print -r -- "PASS: ${name}"
    (( passed += 1 ))
  else
    print -u2 -r -- "FAIL: ${name}; expected=${expected}; actual=${actual}"
    (( failed += 1 ))
  fi
}

assert_exit_status() {
  local name="$1"
  local expected="$2"
  shift 2
  "$@" >/dev/null 2>&1
  local actual=$?
  assert_equal "$name" "$expected" "$actual"
}

assert_no_failure_marker() {
  ! rg -q 'SLATESYNC_XCODE_TEST_CLASSIFICATION=' "$1"
}

path_is_within() {
  [[ "$1" == "$2"/* ]]
}

assert_success "known phase" gate_valid_phase SM-01
assert_failure "unknown phase" gate_valid_phase SM-10
assert_exit_status "unknown phase CLI status" 64 \
  "${project_root}/script/phase_gate.sh" SM-10
assert_failure "missing required tool" command -v slatesync-tool-that-does-not-exist

print -r -- "Swift compiler error" > "${fixture_root}/code-failure.log"
assert_equal "command failure classification" FAIL \
  "$(gate_classify_failure "${fixture_root}/code-failure.log" 1)"

print -r -- "ModuleCache: Operation not permitted" > "${fixture_root}/environment.log"
assert_equal "environment block classification" BLOCKED_ENV \
  "$(gate_classify_failure "${fixture_root}/environment.log" 1)"

print -r -- '{"result":"Passed","failedTests":0,"testsCount":2}' > "${fixture_root}/xcode-passed.json"
assert_success "passing Xcode result summary" gate_validate_xcode_test_summary \
  "${fixture_root}/xcode-passed.json"
print -r -- '{"result":"Passed","failedTests":0,"testsCount":2,"message":"permission denied is documented setup text"}' > \
  "${fixture_root}/xcode-passed-environment-word.json"
assert_success "passing summary ignores non-diagnostic environment text" gate_validate_xcode_test_summary \
  "${fixture_root}/xcode-passed-environment-word.json"
assert_equal "passing summary classification ignores non-diagnostic environment text" PASS \
  "$(gate_classify_xcode_test_summary "${fixture_root}/xcode-passed-environment-word.json")"

print -r -- '{"result":"Failed","failedTests":1,"testsCount":2}' > "${fixture_root}/xcode-assertion-failure.json"
# This validator is called after an exit-zero xcodebuild invocation, so a
# failed xcresult must still prevent the wrapper from reporting PASS.
assert_failure "exit-zero Xcode result summary failure" gate_validate_xcode_test_summary \
  "${fixture_root}/xcode-assertion-failure.json"
assert_equal "failed Xcode summary is a product failure" FAIL \
  "$(gate_classify_xcode_test_summary "${fixture_root}/xcode-assertion-failure.json")"
print -r -- '{"result":"Failed","failedTests":0,"testsCount":2,"failureText":"Testing was canceled by Testing.framework"}' > \
  "${fixture_root}/xcode-canceled-summary.json"
assert_equal "canceled Xcode summary is an environment block" BLOCKED_ENV \
  "$(gate_classify_xcode_test_summary "${fixture_root}/xcode-canceled-summary.json")"
print -r -- '{"result":"Failed","failedTests":1,"testsCount":1,"failureText":"Test runner failed to initialize for UI testing: Timed out while enabling automation mode"}' > \
  "${fixture_root}/xcode-ui-automation-timeout.json"
assert_equal "UI automation initialization timeout overrides failed count" BLOCKED_ENV \
  "$(gate_classify_xcode_test_summary "${fixture_root}/xcode-ui-automation-timeout.json")"
print -r -- '{"result":"Failed","failedTests":1,"testsCount":2,"failureText":["Timed out while enabling automation mode","XCTAssertEqual failed"]}' > \
  "${fixture_root}/xcode-ui-timeout-with-assertion.json"
assert_equal "product assertion wins over UI automation timeout" FAIL \
  "$(gate_classify_xcode_test_summary "${fixture_root}/xcode-ui-timeout-with-assertion.json")"
print -r -- 'result=Failed failureText=Testing was canceled by Testing.framework' > \
  "${fixture_root}/xcode-environment-failure.log"
assert_equal "Xcode runner cancellation classification" BLOCKED_ENV \
  "$(gate_classify_failure "${fixture_root}/xcode-environment-failure.log" 1)"
print -r -- 'error: Copy Testing.framework failed with exit code 0' > \
  "${fixture_root}/xcode-framework-copy-failure.log"
assert_equal "Xcode Testing.framework copy classification" BLOCKED_ENV \
  "$(gate_classify_failure "${fixture_root}/xcode-framework-copy-failure.log" 65)"
print -r -- 'error: the following command failed with exit code 0 but produced no further output' > \
  "${fixture_root}/xcode-signed-framework-copy-failure.log"
assert_equal "Xcode signed-framework wrapper classification" BLOCKED_ENV \
  "$(gate_classify_failure "${fixture_root}/xcode-signed-framework-copy-failure.log" 65)"
print -r -- 'result=Failed failureText=XCTAssertEqual failed' > \
  "${fixture_root}/xcode-test-failure.log"
assert_equal "Xcode assertion classification" FAIL \
  "$(gate_classify_failure "${fixture_root}/xcode-test-failure.log" 1)"
print -r -- 'result=Failed failureText=XCTAssertEqual failed; copy Testing.framework failed' > \
  "${fixture_root}/xcode-mixed-failure.log"
assert_equal "assertion takes precedence over framework setup text" FAIL \
  "$(gate_classify_failure "${fixture_root}/xcode-mixed-failure.log" 1)"
print -r -- 'application code crashed / encountered an error' > \
  "${fixture_root}/xcode-application-error.log"
assert_equal "application error is not an environment waiver" FAIL \
  "$(gate_classify_failure "${fixture_root}/xcode-application-error.log" 1)"
print -r -- 'SLATESYNC_XCODE_TEST_CLASSIFICATION=FAIL Testing.framework' > \
  "${fixture_root}/xcode-failure-marker.log"
assert_equal "result-bundle failure marker takes precedence" FAIL \
  "$(gate_classify_failure "${fixture_root}/xcode-failure-marker.log" 1)"
print -r -- 'SLATESYNC_XCODE_TEST_CLASSIFICATION=BLOCKED_ENV XCTest XCTAssertEqual failed' > \
  "${fixture_root}/xcode-blocked-assertion-mixed.log"
assert_equal "assertion takes precedence over blocked environment marker" FAIL \
  "$(gate_classify_failure "${fixture_root}/xcode-blocked-assertion-mixed.log" 1)"
print -r -- '** TEST FAILED **
SLATESYNC_XCODE_TEST_CLASSIFICATION=BLOCKED_ENV' > "${fixture_root}/xcode-blocked-banner.log"
assert_equal "generic Xcode banner respects parsed environment evidence" BLOCKED_ENV \
  "$(gate_classify_failure "${fixture_root}/xcode-blocked-banner.log" 1)"
print -r -- 'Test Case smoke failed' >> "${fixture_root}/xcode-blocked-banner.log"
assert_equal "executed test failure still outranks environment evidence" FAIL \
  "$(gate_classify_failure "${fixture_root}/xcode-blocked-banner.log" 1)"

# Exercise the complete xcodebuild -> xcresult summary path with command
# fixtures. This catches status-handling regressions that pure classifier tests
# cannot see, including a readable result bundle after xcodebuild exits non-zero.
run_xcode_test_plan_fixture() {
  local name="$1"
  local xcodebuild_status="$2"
  local summary_json="$3"
  local expected_command_status="$4"
  local expected_classification="$5"
  local fixture_dir="${fixture_root}/${name}"
  local bin_dir="${fixture_dir}/bin"
  local result_dir="${fixture_dir}/results"
  local command_status=0

  mkdir -p "$bin_dir" "$result_dir"
  print -r -- "$summary_json" > "${fixture_dir}/summary.json"
  print -r -- '#!/bin/zsh
result_bundle=""
derived_data=""
while (( $# > 0 )); do
  case "$1" in
    -derivedDataPath)
      derived_data="$2"
      shift 2
      ;;
    -resultBundlePath)
      result_bundle="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
print -r -- "$derived_data" > "$SLATESYNC_XCODE_FIXTURE_ARGUMENTS_PATH"
print -r -- "$result_bundle" >> "$SLATESYNC_XCODE_FIXTURE_ARGUMENTS_PATH"
mkdir -p "$result_bundle"
print -r -- "fixture xcodebuild status=${SLATESYNC_XCODE_FIXTURE_XCODEBUILD_STATUS}"
if (( SLATESYNC_XCODE_FIXTURE_XCODEBUILD_STATUS != 0 )); then
  print -r -- "** TEST FAILED **"
fi
exit "$SLATESYNC_XCODE_FIXTURE_XCODEBUILD_STATUS"
' > "${bin_dir}/xcodebuild"
  print -r -- '#!/bin/zsh
/bin/cat "$SLATESYNC_XCODE_FIXTURE_SUMMARY_PATH"
' > "${bin_dir}/xcrun"
  chmod +x "${bin_dir}/xcodebuild" "${bin_dir}/xcrun"

  (
    cd "$fixture_dir" || exit 1
    export PATH="${bin_dir}:${PATH}"
    export SLATESYNC_XCODE_FIXTURE_SUMMARY_PATH="${fixture_dir}/summary.json"
    export SLATESYNC_XCODE_FIXTURE_XCODEBUILD_STATUS="$xcodebuild_status"
    export SLATESYNC_XCODE_FIXTURE_ARGUMENTS_PATH="${fixture_dir}/xcodebuild-arguments.txt"
    gate_xcode_test_plan_check "$fixture_dir" "$result_dir"
  ) > "${fixture_dir}/output.log" 2>&1 || command_status=$?

  assert_equal "${name} wrapper status" "$expected_command_status" "$command_status"
  local recorded_derived_data
  local recorded_result_bundle
  recorded_derived_data="$(sed -n '1p' "${fixture_dir}/xcodebuild-arguments.txt")"
  recorded_result_bundle="$(sed -n '2p' "${fixture_dir}/xcodebuild-arguments.txt")"
  # XCUI executables and their live result bundle must not be hosted below a
  # protected repository; only the completed evidence is moved into results.
  assert_failure "${name} DerivedData is outside repository" \
    path_is_within "$recorded_derived_data" "$fixture_dir"
  assert_failure "${name} live xcresult is outside repository" \
    path_is_within "$recorded_result_bundle" "$fixture_dir"
  assert_success "${name} materializes xcresult evidence" \
    test -d "${result_dir}/SlateSync.xcresult"
  if [[ "$expected_classification" == "PASS" ]]; then
    # A genuine passing result bundle and an exit-zero xcodebuild invocation
    # must return cleanly without manufacturing a failure marker.
    assert_success "${name} has no failure marker" \
      assert_no_failure_marker "${fixture_dir}/output.log"
  else
    assert_equal "${name} result classification" "$expected_classification" \
      "$(gate_classify_failure "${fixture_dir}/output.log" "$command_status")"
  fi
}

run_xcode_test_plan_fixture \
  xcode-exit-zero-result-failure \
  0 \
  '{"result":"Failed","failedTests":1,"testsCount":2,"failureText":"XCTAssertEqual failed"}' \
  1 \
  FAIL
run_xcode_test_plan_fixture \
  xcode-nonzero-readable-result-failure \
  42 \
  '{"result":"Failed","failedTests":1,"testsCount":2,"failureText":"XCTAssertEqual failed"}' \
  1 \
  FAIL
run_xcode_test_plan_fixture \
  xcode-nonzero-readable-result-canceled \
  42 \
  '{"result":"Failed","failedTests":0,"testsCount":2,"failureText":"Testing was canceled by Testing.framework"}' \
  1 \
  BLOCKED_ENV
run_xcode_test_plan_fixture \
  xcode-nonzero-ui-automation-timeout \
  42 \
  '{"result":"Failed","failedTests":1,"testsCount":1,"failureText":"Test runner failed to initialize for UI testing: Timed out while enabling automation mode"}' \
  1 \
  BLOCKED_ENV
run_xcode_test_plan_fixture \
  xcode-exit-zero-result-pass \
  0 \
  '{"result":"Passed","failedTests":0,"testsCount":2}' \
  0 \
  PASS

assert_success "Universal architectures" gate_validate_architectures \
  "Architectures in the fat file are: x86_64 arm64"
assert_failure "missing Universal architecture" gate_validate_architectures "arm64"
assert_success "minimum macOS 15" gate_validate_minimum_system "15.0"
assert_failure "incorrect minimum macOS" gate_validate_minimum_system "14.0"

cat > "${fixture_root}/phase-state.json" <<'JSON'
{
  "phase": "SM-01",
  "lifecycleState": "COMPLETE",
  "activePackage": ".codex/swift-migration/packages/SM-01.md",
  "nextPackage": ".codex/swift-migration/packages/SM-02.md"
}
JSON
assert_success "SM-02 pre-admission state" gate_validate_phase_state \
  "${fixture_root}/phase-state.json" SM-02
cat > "${fixture_root}/phase-state.json" <<'JSON'
{
  "phase": "SM-02",
  "lifecycleState": "COMPLETE",
  "activePackage": ".codex/swift-migration/packages/SM-02.md",
  "nextPackage": ".codex/swift-migration/packages/SM-03.md"
}
JSON
assert_success "SM-02 post-admission state" gate_validate_phase_state \
  "${fixture_root}/phase-state.json" SM-02
assert_success "SM-03 pre-admission state" gate_validate_phase_state \
  "${fixture_root}/phase-state.json" SM-03
assert_failure "stale phase cannot skip to SM-04" gate_validate_phase_state \
  "${fixture_root}/phase-state.json" SM-04
cat > "${fixture_root}/phase-state.json" <<'JSON'
{
  "phase": "SM-03",
  "lifecycleState": "IN_PROGRESS",
  "activePackage": ".codex/swift-migration/packages/SM-03.md",
  "nextPackage": ".codex/swift-migration/packages/SM-04.md"
}
JSON
assert_failure "SM-03 implementation state cannot self-admit" gate_validate_phase_state \
  "${fixture_root}/phase-state.json" SM-03
cat > "${fixture_root}/phase-state.json" <<'JSON'
{
  "phase": "SM-03",
  "lifecycleState": "COMPLETE",
  "activePackage": ".codex/swift-migration/packages/SM-03.md",
  "nextPackage": ".codex/swift-migration/packages/SM-04.md"
}
JSON
assert_success "SM-03 completed state admits same package" gate_validate_phase_state \
  "${fixture_root}/phase-state.json" SM-03
assert_success "SM-03 completed state admits SM-04" gate_validate_phase_state \
  "${fixture_root}/phase-state.json" SM-04
cat > "${fixture_root}/phase-state.json" <<'JSON'
{
  "phase": "SM-02",
  "lifecycleState": "COMPLETE",
  "activePackage": ".codex/swift-migration/packages/SM-02.md",
  "nextPackage": ".codex/swift-migration/packages/SM-04.md"
}
JSON
assert_failure "incorrect next package" gate_validate_phase_state \
  "${fixture_root}/phase-state.json" SM-02

assert_success "exact built executable command" slatesync_command_matches_executable \
  "/tmp/SlateSync.app/Contents/MacOS/SlateSync" \
  "/tmp/SlateSync.app/Contents/MacOS/SlateSync"
assert_success "built executable command with arguments" slatesync_command_matches_executable \
  "/tmp/SlateSync.app/Contents/MacOS/SlateSync --diagnostic" \
  "/tmp/SlateSync.app/Contents/MacOS/SlateSync"
assert_success "built executable path containing spaces" slatesync_command_matches_executable \
  "/tmp/Slate Sync/SlateSync.app/Contents/MacOS/SlateSync" \
  "/tmp/Slate Sync/SlateSync.app/Contents/MacOS/SlateSync"
assert_failure "same-name executable from another bundle" slatesync_command_matches_executable \
  "/Applications/SlateSync.app/Contents/MacOS/SlateSync" \
  "/tmp/SlateSync.app/Contents/MacOS/SlateSync"

cat > "${fixture_root}/state.json" <<'JSON'
{
  "lifecycleState": "COMPLETE",
  "gate": {
    "conclusion": "PASS",
    "reviewCommit": "reviewed-sha",
    "owner": "Repository Owner",
    "approvedAt": "2026-09-03T00:00:00Z",
    "evidenceReport": ".codex/swift-migration/reviews/SM-01.md",
    "blockers": []
  }
}
JSON
assert_success "fresh approval SHA" gate_validate_approval_state \
  "${fixture_root}/state.json" "reviewed-sha"
assert_failure "stale approval SHA" gate_validate_approval_state \
  "${fixture_root}/state.json" "different-sha"

approval_repo="${fixture_root}/approval-repo"
mkdir -p \
  "${approval_repo}/.codex/swift-migration/reviews" \
  "${approval_repo}/Sources"
git -C "$approval_repo" init -q
git -C "$approval_repo" config user.name "Gate Test"
git -C "$approval_repo" config user.email "gate-test@example.invalid"
print -r -- "reviewed source" > "${approval_repo}/Sources/App.swift"
git -C "$approval_repo" add Sources/App.swift
git -C "$approval_repo" commit -qm "review target"
review_sha="$(git -C "$approval_repo" rev-parse HEAD)"
cat > "${approval_repo}/.codex/swift-migration/CURRENT_STATE.json" <<JSON
{
  "lifecycleState": "COMPLETE",
  "gate": {
    "conclusion": "PASS",
    "reviewCommit": "${review_sha}",
    "owner": "Repository Owner",
    "approvedAt": "2026-09-03T00:00:00Z",
    "evidenceReport": ".codex/swift-migration/reviews/SM-01.md",
    "blockers": []
  }
}
JSON
print -r -- "Owner approved" > \
  "${approval_repo}/.codex/swift-migration/reviews/SM-01.md"
git -C "$approval_repo" add .codex
git -C "$approval_repo" commit -qm "record approval"
approval_sha="$(git -C "$approval_repo" rev-parse HEAD)"
assert_success "governance-only approval commit" gate_validate_approval_state \
  "${approval_repo}/.codex/swift-migration/CURRENT_STATE.json" \
  "$approval_sha" "$approval_repo" SM-01
print -r -- "unreviewed change" >> "${approval_repo}/Sources/App.swift"
git -C "$approval_repo" add Sources/App.swift
git -C "$approval_repo" commit -qm "change source after review"
assert_failure "post-review source commit invalidates approval" gate_validate_approval_state \
  "${approval_repo}/.codex/swift-migration/CURRENT_STATE.json" \
  "$(git -C "$approval_repo" rev-parse HEAD)" "$approval_repo" SM-01

cat > "${fixture_root}/evidence.json" <<'JSON'
{
  "schemaVersion": 1,
  "phase": "SM-01",
  "reviewCommit": "reviewed-sha",
  "checks": {
    "swift_test": {
      "result": "PASS",
      "sourceType": "ci",
      "command": "swift test",
      "artifact": "https://ci.example.invalid/runs/1",
      "recordedAt": "2026-09-03T00:00:00Z"
    },
    "xcode_test_plan": {
      "result": "PASS",
      "sourceType": "owner-waiver",
      "owner": "Repository Owner",
      "reason": "Temporary runner outage",
      "expiresAt": "2099-01-01T00:00:00Z",
      "revalidateByPhase": "SM-02"
    }
  }
}
JSON
assert_success "equivalent CI evidence" gate_evidence_replacement \
  "${fixture_root}/evidence.json" SM-01 reviewed-sha swift_test true
assert_failure "evidence from stale SHA" gate_evidence_replacement \
  "${fixture_root}/evidence.json" SM-01 different-sha swift_test true
assert_failure "critical check cannot use Owner waiver" gate_evidence_replacement \
  "${fixture_root}/evidence.json" SM-01 reviewed-sha xcode_test_plan true
assert_success "non-critical check may use bounded Owner waiver" gate_evidence_replacement \
  "${fixture_root}/evidence.json" SM-01 reviewed-sha xcode_test_plan false

# New phase boundaries augment the old negative state tests; they do not relax
# SM-05's own admission assertions when its technical lane is reused by SM-06.
for completed_phase in SM-05 SM-06; do
  next_phase=SM-06
  [[ "$completed_phase" == SM-06 ]] && next_phase=SM-07
  python3 - "${fixture_root}/sm06-state.json" "$completed_phase" "$next_phase" <<'PY'
import json,sys
path,phase,next_phase=sys.argv[1:]
with open(path,'w') as f:
    json.dump({'phase':phase,'lifecycleState':'COMPLETE','activePackage':f'.codex/swift-migration/packages/{phase}.md','nextPackage':f'.codex/swift-migration/packages/{next_phase}.md'},f)
PY
  assert_success "${completed_phase} admits SM-06 boundary" gate_validate_phase_state "${fixture_root}/sm06-state.json" SM-06
done
assert_failure "SM-06 cannot skip directly to SM-09" gate_validate_phase_state "${fixture_root}/sm06-state.json" SM-09
assert_success "SM-06 fixture and executed-evidence negative tests" node "${project_root}/script/tests/sm06_contract.mjs" --self-test
assert_success "SM-05 retains negative admission assertions" node --input-type=module -e '
  import assert from "node:assert/strict";
  process.argv.push("--technical-only");
  const {assertAdmissionBoundary} = await import("./script/tests/sm05_contract.mjs");
  assert.throws(()=>assertAdmissionBoundary({phase:"SM-06",lifecycleState:"COMPLETE"}));
  assert.throws(()=>assertAdmissionBoundary({phase:"SM-05",lifecycleState:"IN_PROGRESS"}));
'
print -r -- "Gate helper tests: ${passed} passed, ${failed} failed"
(( failed == 0 ))
