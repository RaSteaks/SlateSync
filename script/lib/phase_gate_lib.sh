#!/bin/zsh

# Pure Gate helpers live separately so result classification can be tested
# without building or launching the macOS application.

slatesync_command_matches_executable() {
  local process_command="$1"
  local expected_executable="$2"
  [[ "$process_command" == "$expected_executable" || \
     "$process_command" == "${expected_executable} "* ]]
}

slatesync_process_ids_for_executable() {
  local process_name="$1"
  local expected_executable="$2"
  local candidates
  local candidate_pid
  local process_command

  candidates="$(pgrep -x "$process_name" 2>/dev/null || true)"
  for candidate_pid in ${(f)candidates}; do
    process_command="$(ps -p "$candidate_pid" -o command= 2>/dev/null | sed 's/^[[:space:]]*//')"
    if slatesync_command_matches_executable "$process_command" "$expected_executable"; then
      print -r -- "$candidate_pid"
    fi
  done
}

slatesync_stop_executable() {
  local process_name="$1"
  local expected_executable="$2"
  local process_id
  local attempt

  # Restrict termination to this repository's built executable; another installed
  # SlateSync instance may legitimately share the same process name.
  for process_id in ${(f)"$(slatesync_process_ids_for_executable "$process_name" "$expected_executable")"}; do
    [[ -n "$process_id" ]] && kill "$process_id" 2>/dev/null || true
  done
  for (( attempt = 1; attempt <= 20; attempt += 1 )); do
    [[ -z "$(slatesync_process_ids_for_executable "$process_name" "$expected_executable")" ]] && return 0
    sleep 0.1
  done
  return 1
}

gate_valid_phase() {
  [[ "${1:-}" =~ '^SM-0[0-9]$' ]]
}

gate_classify_failure() {
  local log_path="$1"
  local exit_status="$2"

  # Real assertions, crashes, and failed tests outrank every marker. A runner
  # can emit environment text after an application has already failed.
  if rg -qi \
    'XCTAssert[A-Za-z0-9_]*[[:space:]]+failed|assertion[[:space:]]+(failed|failure)|failedTests[[:space:]]*=[[:space:]]*[1-9]|test(s)?[[:space:]]+(failed|failure)|application code (crashed|failed)|uncaught exception|fatal error|EXC_CRASH|signal[[:space:]]+[0-9]+' \
    "$log_path"; then
    print -r -- "FAIL"
    return 0
  fi

  # xcode_test_plan_check emits an explicit result marker after inspecting the
  # xcresult. It must outrank textual environment hints so a real assertion
  # failure cannot be hidden by an incidental Testing.framework line.
  if rg -q 'SLATESYNC_XCODE_TEST_CLASSIFICATION=FAIL' "$log_path"; then
    print -r -- "FAIL"
    return 0
  fi
  if rg -q 'SLATESYNC_XCODE_TEST_CLASSIFICATION=BLOCKED_ENV' "$log_path"; then
    print -r -- "BLOCKED_ENV"
    return 0
  fi

  if (( exit_status == 126 || exit_status == 127 )); then
    print -r -- "BLOCKED_ENV"
    return 0
  fi

  # Xcode may fail while copying its signed Testing.framework or cancel the
  # UI runner before assertions execute; both are environment blocks, not code
  # regressions, and must remain visible as BLOCKED_ENV in Gate artifacts.
  if rg -qi \
    'operation not permitted|permission denied|not accessible or not writable|missing required tool|xcode license|unable to load standard library|cannot open file .+ for diagnostics emission|no graphical login session|not authorized to send apple events|requires a development team|no signing certificate|core simulator service connection became invalid|testing was (canceled|cancelled)|sandbox_apply|sandbox-exec|the following command failed with exit code 0|((copy|copying|copied|install|sign|codesign).{0,120}Testing[.]framework.{0,120}(fail|error|unable))|((fail|error|unable).{0,120}(copy|copying|copied|install|sign).{0,120}Testing[.]framework)' \
    "$log_path"; then
    print -r -- "BLOCKED_ENV"
  else
    print -r -- "FAIL"
  fi
}

gate_classify_xcode_test_summary() {
  local summary_path="$1"
  python3 - "$summary_path" <<'PY'
import json
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    summary = json.load(handle)

result = str(summary.get("result", "")).strip().lower()
try:
    failed = int(summary.get("failedTests", 0) or 0)
except (TypeError, ValueError):
    failed = 1

# Only these fields are diagnostics/failure evidence. In particular, do not
# scan arbitrary summary metadata: a passing run may mention environment words
# in an informational message without being blocked.
diagnostic_keys = {
    "failureText",
    "failureReason",
    "testFailures",
    "failures",
    "errors",
    "error",
    "diagnostics",
}
diagnostic_values = [summary.get(key) for key in diagnostic_keys if key in summary]
diagnostic_text = json.dumps(diagnostic_values, ensure_ascii=False).lower()

code_failure = re.search(
    r"xctassert|assertion|application code (crashed|failed)|uncaught exception|"
    r"fatal error|exc_crash|test(?:s)?[\s_-]+(?:failed|failure)",
    diagnostic_text,
)
environment_failure = re.search(
    r"testing was (canceled|cancelled)|runner[\s_-]+(canceled|cancelled)|"
    r"test runner failed to initialize for ui testing|"
    r"timed out while enabling automation mode|"
    r"sandbox_apply|sandbox-exec|operation not permitted|permission denied|"
    r"no graphical login session|not authorized to send apple events|"
    r"testing[.]framework.*(?:copy|fail|error|unable)|"
    r"(?:copy|fail|error|unable).*testing[.]framework",
    diagnostic_text,
)
if code_failure:
    print("FAIL")
elif environment_failure:
    print("BLOCKED_ENV")
elif failed > 0:
    # A failed count without infrastructure diagnostics remains fail-closed.
    print("FAIL")
elif result in {"passed", "success"} and failed == 0:
    print("PASS")
else:
    print("FAIL")
PY
}

gate_validate_xcode_test_summary() {
  local summary_path="$1"
  if [[ "$(gate_classify_xcode_test_summary "$summary_path")" != "PASS" ]]; then
    print -u2 -r -- "Xcode test result is not passing"
    return 1
  fi
}

gate_xcode_test_plan_check() {
  local project_root="$1"
  local result_dir="$2"
  local result_bundle="${result_dir}/SlateSync.xcresult"
  local summary_path="${result_dir}/xcode_test_summary.json"
  local xcodebuild_log="${result_dir}/xcode_test_plan_xcodebuild.log"
  local test_workspace
  local ephemeral_result_bundle
  local command_status=0
  local artifact_status=0
  local summary_status=0

  # Keep the UI test runner outside a repository that may itself live below a
  # macOS protected Desktop/Documents folder. Otherwise TCC can interrupt XCUI
  # with a folder-access prompt even though SlateSync only uses its test root.
  test_workspace="$(mktemp -d "${TMPDIR:-/tmp}/slatesync-xcode-test.XXXXXX")" || return 1
  ephemeral_result_bundle="${test_workspace}/SlateSync.xcresult"
  (
    cd "$project_root" &&
    xcodebuild -quiet \
      -project SlateSync.xcodeproj \
      -scheme SlateSync \
      -testPlan SlateSync \
      -destination 'platform=macOS' \
      -derivedDataPath "${test_workspace}/DerivedData" \
      -resultBundlePath "$ephemeral_result_bundle" \
      test
  ) > "$xcodebuild_log" 2>&1 || command_status=$?
  cat "$xcodebuild_log"

  # The parent Gate process materializes immutable evidence after the runner has
  # exited, so xcresult inspection remains available without giving the runner a
  # reason to access the protected repository directory.
  if [[ -e "$ephemeral_result_bundle" ]]; then
    mv "$ephemeral_result_bundle" "$result_bundle" || artifact_status=$?
  fi
  rm -rf -- "$test_workspace"
  if (( artifact_status != 0 )); then
    print -u2 -r -- "Unable to materialize the Xcode test result bundle"
    return "$artifact_status"
  fi

  # An xcresult is useful even when xcodebuild exits non-zero. Inspect it before
  # falling back to log classification so assertion failures and environment
  # cancellation remain distinct instead of treating every exit code alike.
  if [[ ! -e "$result_bundle" ]]; then
    (( command_status == 0 )) || return "$command_status"
    print -u2 -r -- "xcodebuild returned success without a result bundle"
    return 1
  fi

  # Keep the wrapper and summary statuses separate: a non-zero xcodebuild
  # status must not prevent a readable result bundle from being classified.
  (
    cd "$project_root" &&
    xcrun xcresulttool get test-results summary \
      --path "$result_bundle" \
      --format json
  ) > "$summary_path" 2>&1 || summary_status=$?
  if (( summary_status != 0 )); then
    cat "$summary_path"
    return "$summary_status"
  fi
  cat "$summary_path"
  local summary_classification
  summary_classification="$(gate_classify_xcode_test_summary "$summary_path")"
  if [[ "$summary_classification" != "PASS" ]]; then
    print -r -- "SLATESYNC_XCODE_TEST_CLASSIFICATION=${summary_classification}"
    return 1
  fi
  if (( command_status != 0 )); then
    # A passing summary with a non-zero wrapper status is still not a PASS.
    # Classify the wrapper log narrowly so signed-framework copy/setup errors
    # remain BLOCKED_ENV while a build/test regression remains FAIL.
    local wrapper_classification
    wrapper_classification="$(gate_classify_failure "$xcodebuild_log" "$command_status")"
    print -r -- "SLATESYNC_XCODE_TEST_CLASSIFICATION=${wrapper_classification}"
    return "$command_status"
  fi
}

gate_validate_architectures() {
  local architecture_output="$1"
  [[ "$architecture_output" == *"arm64"* && "$architecture_output" == *"x86_64"* ]]
}

gate_validate_minimum_system() {
  [[ "$1" == "15.0" ]]
}

gate_validate_phase_state() {
  local state_path="$1"
  local requested_phase="$2"

  python3 - "$state_path" "$requested_phase" <<'PY'
import json
import re
import sys

state_path, requested_phase = sys.argv[1:]
phase_pattern = re.compile(r"SM-(\d{2})$")
requested_match = phase_pattern.fullmatch(requested_phase)
if requested_match is None:
    raise SystemExit(1)

with open(state_path, encoding="utf-8") as handle:
    state = json.load(handle)

state_phase = state.get("phase")
state_match = phase_pattern.fullmatch(state_phase or "")
if state_match is None or state.get("lifecycleState") != "COMPLETE":
    raise SystemExit(1)

requested_number = int(requested_match.group(1))
state_number = int(state_match.group(1))
if state_number not in {requested_number - 1, requested_number}:
    raise SystemExit(1)

expected_active = f".codex/swift-migration/packages/{state_phase}.md"
expected_next_number = state_number + 1
expected_next = f".codex/swift-migration/packages/SM-{expected_next_number:02d}.md"
if state.get("activePackage") != expected_active or state.get("nextPackage") != expected_next:
    raise SystemExit(1)

# Before admission, the previous COMPLETE phase must point at the requested
# package. After admission, the requested phase itself must point at its successor.
if state_number == requested_number - 1 and expected_next != f".codex/swift-migration/packages/{requested_phase}.md":
    raise SystemExit(1)
raise SystemExit(0)
PY
}

gate_validate_approval_state() {
  local state_path="$1"
  local expected_commit="$2"
  local repository_root="${3:-}"
  local phase="${4:-SM-01}"

  python3 - "$state_path" "$expected_commit" "$repository_root" "$phase" <<'PY'
import json
import subprocess
import sys

state_path, expected_commit, repository_root, phase = sys.argv[1:]
with open(state_path, encoding="utf-8") as handle:
    state = json.load(handle)

gate = state.get("gate", {})
metadata_valid = (
    state.get("lifecycleState") == "COMPLETE"
    and gate.get("conclusion") == "PASS"
    and bool(gate.get("owner"))
    and bool(gate.get("approvedAt"))
    and bool(gate.get("evidenceReport"))
    and not gate.get("blockers")
)
if not metadata_valid:
    raise SystemExit(1)

review_commit = gate.get("reviewCommit")
if review_commit == expected_commit:
    raise SystemExit(0)

# Recording tracked approval metadata necessarily creates a new commit. Permit
# that commit only when every post-review path is governance metadata.
if not repository_root or not review_commit:
    raise SystemExit(1)
ancestor = subprocess.run(
    ["git", "-C", repository_root, "merge-base", "--is-ancestor", review_commit, expected_commit],
    check=False,
).returncode == 0
if not ancestor:
    raise SystemExit(1)
changed = subprocess.run(
    ["git", "-C", repository_root, "diff", "--name-only", f"{review_commit}..{expected_commit}"],
    check=True,
    capture_output=True,
    text=True,
).stdout.splitlines()
allowed = {
    ".codex/swift-migration/CURRENT_STATE.json",
    f".codex/swift-migration/reviews/{phase}.md",
}
raise SystemExit(0 if changed and set(changed) <= allowed else 1)
PY
}

gate_evidence_replacement() {
  local evidence_path="$1"
  local phase="$2"
  local review_commit="$3"
  local check_id="$4"
  local critical="$5"

  python3 - "$evidence_path" "$phase" "$review_commit" "$check_id" "$critical" <<'PY'
from datetime import datetime, timezone
import json
import sys

path, phase, review_commit, check_id, critical_text = sys.argv[1:]
critical = critical_text == "true"

with open(path, encoding="utf-8") as handle:
    evidence = json.load(handle)

if evidence.get("phase") != phase or evidence.get("reviewCommit") != review_commit:
    raise SystemExit(1)

entry = evidence.get("checks", {}).get(check_id)
if not isinstance(entry, dict) or entry.get("result") != "PASS":
    raise SystemExit(1)

source_type = entry.get("sourceType")
if source_type in {"ci", "qualified-mac"}:
    required = ("command", "artifact", "recordedAt")
    if not all(entry.get(field) for field in required):
        raise SystemExit(1)
    print(f"equivalent {source_type} evidence: {entry['artifact']}")
    raise SystemExit(0)

# Owner waivers are deliberately limited to non-critical environmental blocks.
if source_type != "owner-waiver" or critical:
    raise SystemExit(1)

required = ("owner", "reason", "expiresAt", "revalidateByPhase")
if not all(entry.get(field) for field in required):
    raise SystemExit(1)

expires_at = entry["expiresAt"].replace("Z", "+00:00")
if datetime.fromisoformat(expires_at) <= datetime.now(timezone.utc):
    raise SystemExit(1)

print(
    "owner waiver until "
    f"{entry['expiresAt']}; revalidate by {entry['revalidateByPhase']}"
)
PY
}
