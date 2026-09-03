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

assert_success "Universal architectures" gate_validate_architectures \
  "Architectures in the fat file are: x86_64 arm64"
assert_failure "missing Universal architecture" gate_validate_architectures "arm64"
assert_success "minimum macOS 15" gate_validate_minimum_system "15.0"
assert_failure "incorrect minimum macOS" gate_validate_minimum_system "14.0"

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

print -r -- "Gate helper tests: ${passed} passed, ${failed} failed"
(( failed == 0 ))
