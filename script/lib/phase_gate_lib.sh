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

  if (( exit_status == 126 || exit_status == 127 )); then
    print -r -- "BLOCKED_ENV"
    return 0
  fi

  if rg -qi \
    'operation not permitted|permission denied|not accessible or not writable|missing required tool|xcode license|unable to load standard library|cannot open file .+ for diagnostics emission|no graphical login session|not authorized to send apple events|requires a development team|no signing certificate|core simulator service connection became invalid' \
    "$log_path"; then
    print -r -- "BLOCKED_ENV"
  else
    print -r -- "FAIL"
  fi
}

gate_validate_architectures() {
  local architecture_output="$1"
  [[ "$architecture_output" == *"arm64"* && "$architecture_output" == *"x86_64"* ]]
}

gate_validate_minimum_system() {
  [[ "$1" == "15.0" ]]
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
