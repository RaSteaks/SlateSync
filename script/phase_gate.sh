#!/bin/zsh
set -uo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
source "${script_dir}/lib/phase_gate_lib.sh"

readonly exit_fail=1
readonly exit_blocked_environment=2
readonly exit_diagnostic_only=3
readonly exit_usage=64

phase=""
evidence_path=""
allow_dirty=0
results_root="${SLATESYNC_GATE_RESULTS_DIR:-${project_root}/.codex/gate-results}"
overall_failures=0
overall_environment_blocks=0
approvable=true

usage() {
  print -r -- "用法: ./script/phase_gate.sh SM-XX [--evidence FILE] [--results-dir DIR] [--allow-dirty]"
}

sanitize_field() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

record_check() {
  local check_id="$1"
  local critical="$2"
  local result="$3"
  local message
  message="$(sanitize_field "$4")"
  local log_path="${5:-}"

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$check_id" "$critical" "$result" "$message" "$log_path" >> "$checks_tsv"

  case "$result" in
    FAIL) (( overall_failures += 1 )) ;;
    BLOCKED_ENV) (( overall_environment_blocks += 1 )) ;;
  esac
  print -r -- "[${result}] ${check_id} — ${message}"
}

run_check() {
  local check_id="$1"
  local critical="$2"
  local description="$3"
  shift 3
  local -a command=("$@")
  local log_path="${result_dir}/${check_id}.log"
  local command_status=0

  {
    print -r -- "Check: ${check_id}"
    print -r -- "Description: ${description}"
    print -r -- "Command: ${command[*]}"
    print -r -- "Started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$log_path"

  (
    cd "$project_root"
    "${command[@]}"
  ) >> "$log_path" 2>&1 || command_status=$?

  if (( command_status == 0 )); then
    record_check "$check_id" "$critical" "PASS" "$description" "$log_path"
    return
  fi

  local result
  result="$(gate_classify_failure "$log_path" "$command_status")"
  if [[ "$result" == "BLOCKED_ENV" && -n "$evidence_path" ]]; then
    local replacement
    if replacement="$(gate_evidence_replacement \
      "$evidence_path" "$phase" "$review_commit" "$check_id" "$critical" 2>/dev/null)"; then
      record_check "$check_id" "$critical" "PASS" "${description}; ${replacement}" "$log_path"
      return
    fi
  fi

  record_check "$check_id" "$critical" "$result" \
    "${description}; exit=${command_status}，详见日志" "$log_path"
}

workspace_layout_check() {
  local required
  for required in \
    Package.swift \
    SlateSync.xcodeproj/project.pbxproj \
    SlateSync.xcodeproj/xcshareddata/xcschemes/SlateSync.xcscheme \
    SlateSync.xctestplan \
    SlateSyncApp/App/SlateSyncApp.swift \
    script/build_and_run.sh \
    .codex/swift-migration/CURRENT_STATE.json; do
    [[ -e "$required" ]] || {
      print -u2 -r -- "missing required workspace file: ${required}"
      return 1
    }
  done
  [[ -x script/build_and_run.sh ]] || {
    print -u2 -r -- "script/build_and_run.sh is not executable"
    return 1
  }
}

required_tools_check() {
  local tool
  for tool in git rg python3 swift xcodebuild lipo codesign open pgrep ps /usr/libexec/PlistBuddy; do
    command -v "$tool" >/dev/null 2>&1 || {
      print -u2 -r -- "missing required tool: ${tool}"
      return 127
    }
  done
}

sm01_foundation_contract_check() {
  python3 - Package.swift SlateSync.xcodeproj/project.pbxproj \
    SlateSync.xcodeproj/xcshareddata/xcschemes/SlateSync.xcscheme \
    SlateSync.xctestplan <<'PY'
import json
import re
import sys

package_path, project_path, scheme_path, test_plan_path = sys.argv[1:]
package = open(package_path, encoding="utf-8").read()
project = open(project_path, encoding="utf-8").read()
scheme = open(scheme_path, encoding="utf-8").read()
test_plan = json.load(open(test_plan_path, encoding="utf-8"))

expected_products = {
    "SlateSyncDomain", "SlateSyncPersistence", "SlateSyncMedia",
    "SlateSyncWorkflow", "SlateSyncUI",
}
products = set(re.findall(r'\.library\(name: "([^"]+)"', package))
assert products == expected_products, (products, expected_products)
assert 'platforms: [.macOS(.v15)]' in package
assert 'swiftLanguageModes: [.v6]' in package
for setting in (
    'MACOSX_DEPLOYMENT_TARGET = 15.0;',
    'SWIFT_STRICT_CONCURRENCY = complete;',
    'SWIFT_VERSION = 6.0;',
    'ONLY_ACTIVE_ARCH = YES;',
    'ONLY_ACTIVE_ARCH = NO;',
    'CODE_SIGN_IDENTITY = "-";',
):
    assert setting in project, setting
for target in ("SlateSync", "SlateSyncTests", "SlateSyncUITests"):
    assert f'name = {target};' in project, target
assert 'buildConfiguration="Debug"' in scheme
assert '<ProfileAction buildConfiguration="Release"' in scheme
assert '<ArchiveAction buildConfiguration="Release"' in scheme
test_targets = {entry["target"]["name"] for entry in test_plan["testTargets"]}
assert test_targets == {"SlateSyncTests", "SlateSyncUITests"}, test_targets
print("five SwiftPM libraries, macOS 15, Swift 6, Xcode targets, scheme and test plan verified")
PY
}

sm01_scope_contract_check() {
  local baseline_parent
  local changed_paths
  local forbidden_tracked
  local sensitive_content
  baseline_parent="$(git rev-parse 1f82c1645a6afac5ffdf453da1dcc44a49449b88^ 2>/dev/null)" || return 1

  # Historical evidence and CI are outside SM-01's authorized implementation scope.
  git diff --quiet "${baseline_parent}..${review_commit}" -- .github .codex/refactor || {
    print -u2 "SM-01 changed .github or protected .codex/refactor history"
    return 1
  }
  [[ -z "$(git status --porcelain=v1 --untracked-files=all -- .github .codex/refactor)" ]] || {
    print -u2 "working tree changes .github or protected .codex/refactor history"
    return 1
  }
  local legacy_path
  for legacy_path in electron src public lib package.json package-lock.json electron-builder.yml .github; do
    [[ -e "$legacy_path" ]] || {
      print -u2 "missing legacy compatibility baseline: $legacy_path"
      return 1
    }
  done
  rg -q '"phase"[[:space:]]*:[[:space:]]*"SM-01"' \
    .codex/swift-migration/CURRENT_STATE.json || return 1
  rg -q '"nextPackage"[[:space:]]*:[[:space:]]*"\.codex/swift-migration/packages/SM-02\.md"' \
    .codex/swift-migration/CURRENT_STATE.json || return 1

  forbidden_tracked="$(git ls-files | rg \
    '(^|/)(\.build|DerivedData|\.swiftpm/xcode|\.codex/gate-results)(/|$)|premium-audit\.json$|\.xcarchive(/|$)|\.xcresult(/|$)|\.log$' || true)"
  if [[ -n "$forbidden_tracked" ]]; then
    print -u2 -r -- "$forbidden_tracked"
    print -u2 "generated artifacts are tracked"
    return 1
  fi
  changed_paths="$(git diff --name-only "${baseline_parent}..${review_commit}")"
  if print -r -- "$changed_paths" | rg -q \
    '(^|/)(\.env$|id_rsa|id_ed25519|.*\.(pem|p12|key|sqlite|sqlite-shm|sqlite-wal)$|Application Support)(/|$)'; then
    print -u2 "SM-01 commit contains a credential or user-data path"
    return 1
  fi
  sensitive_content="$(git grep -n -I -E \
    'BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,}|sk-[A-Za-z0-9]{20,}' \
    "$review_commit" -- . ':!.env.example' 2>/dev/null || true)"
  if [[ -n "$sensitive_content" ]]; then
    print -u2 -r -- "$sensitive_content"
    print -u2 "tracked source contains a credential-like value"
    return 1
  fi
  print "scope protected; SM-02 not started; legacy baseline present; generated artifacts untracked"
}

sm01_real_app_launch_check() {
  local isolated_root
  local launch_output
  local launch_status=0
  local verified_pid=""
  local database_path
  local attempt

  isolated_root="$(mktemp -d "${TMPDIR:-/tmp}/slatesync-sm01-launch.XXXXXX")" || return 1
  database_path="${isolated_root}/Local SlateSync Library/library.sqlite"
  print -r -- "Isolated SLATESYNC_TEST_ROOT=${isolated_root}"

  # The environment override is owned by the Gate so a plain formal invocation
  # cannot reach the user's default Application Support directory.
  launch_output="$(SLATESYNC_TEST_ROOT="$isolated_root" \
    ./script/build_and_run.sh --debug --verify 2>&1)" || launch_status=$?
  print -r -- "$launch_output"
  verified_pid="$(print -r -- "$launch_output" | \
    sed -n 's/.*pid=\([0-9][0-9]*\), executable=.*/\1/p' | tail -n 1)"

  if (( launch_status == 0 )); then
    if [[ -z "$verified_pid" ]]; then
      print -u2 "verified executable PID was not recorded"
      launch_status=1
    else
      print -r -- "Verified executable PID=${verified_pid}"
    fi
  fi
  if (( launch_status == 0 )); then
    for (( attempt = 1; attempt <= 40; attempt += 1 )); do
      [[ -f "$database_path" ]] && break
      sleep 0.1
    done
    if [[ ! -f "$database_path" ]]; then
      print -u2 "isolated Project Library database was not created"
      launch_status=1
    else
      print -r -- "Verified isolated Project Library database: ${database_path}"
    fi
  fi

  # Stop only the executable verified above before removing its temporary data root.
  slatesync_stop_executable SlateSync \
    "${project_root}/DerivedData/SlateSync/Build/Products/Debug/SlateSync.app/Contents/MacOS/SlateSync" || \
    launch_status=1
  rm -rf "$isolated_root"
  return "$launch_status"
}

clean_workspace_check() {
  local changes
  changes="$(git status --porcelain=v1 --untracked-files=all)"
  if [[ -z "$changes" ]]; then
    return 0
  fi
  print -r -- "$changes"
  if (( allow_dirty )); then
    print -r -- "dirty workspace accepted for diagnostic execution only"
    return 0
  fi
  print -u2 -r -- "formal phase admission requires a clean, committed review target"
  return 1
}

forbidden_items_check() {
  local -a swift_roots=(Package.swift SlateSyncApp Sources SlateSyncTests SlateSyncUITests Tests)
  if rg -n \
    'fatalError\(|preconditionFailure\(|try!|as!|@unchecked[[:space:]]+Sendable' \
    "${swift_roots[@]}"; then
    print -u2 -r -- "forbidden unsafe Swift construct found"
    return 1
  fi
  # Keep the marker expression different from the literal marker text so this
  # Gate can safely audit its own shell sources.
  if rg -n '^(<{7}|={7}|>{7})' "${swift_roots[@]}" script; then
    print -u2 -r -- "unresolved merge marker found"
    return 1
  fi
  return 0
}

sm01_debug_settings_check() {
  local settings
  settings="$(xcodebuild \
    -project SlateSync.xcodeproj \
    -scheme SlateSync \
    -configuration Debug \
    -showBuildSettings)" || return $?
  print -r -- "$settings"
  print -r -- "$settings" | rg -q 'ARCHS = (arm64|x86_64)' || return 1
  print -r -- "$settings" | rg -q 'MACOSX_DEPLOYMENT_TARGET = 15\.0' || return 1
  print -r -- "$settings" | rg -q 'ONLY_ACTIVE_ARCH = YES' || return 1
  print -r -- "$settings" | rg -q 'SWIFT_OPTIMIZATION_LEVEL = -Onone' || return 1
  print -r -- "$settings" | rg -q 'SWIFT_STRICT_CONCURRENCY = complete' || return 1
}

sm01_release_artifact_check() {
  local app_path="${result_dir}/DerivedData/Release/Build/Products/Release/SlateSync.app"
  local executable="${app_path}/Contents/MacOS/SlateSync"
  [[ -x "$executable" ]] || return 1
  local architectures
  architectures="$(lipo -info "$executable")" || return $?
  print -r -- "$architectures"
  gate_validate_architectures "$architectures" || return 1
  local minimum_system
  minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
    "${app_path}/Contents/Info.plist")" || return $?
  print -r -- "LSMinimumSystemVersion=${minimum_system}"
  gate_validate_minimum_system "$minimum_system" || return 1
  codesign --verify --deep --strict --verbose=2 "$app_path" || return $?
  local signing_details
  signing_details="$(codesign -dvvv "$app_path" 2>&1)" || return $?
  print -r -- "$signing_details"
  [[ "$signing_details" == *"Signature=adhoc"* ]]
}

sm01_archive_artifact_check() {
  local app_path="${result_dir}/SlateSync.xcarchive/Products/Applications/SlateSync.app"
  local executable="${app_path}/Contents/MacOS/SlateSync"
  [[ -x "$executable" ]] || return 1
  local architectures
  architectures="$(lipo -info "$executable")" || return $?
  print -r -- "$architectures"
  gate_validate_architectures "$architectures" || return 1
  local minimum_system
  minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
    "${app_path}/Contents/Info.plist")" || return $?
  print -r -- "LSMinimumSystemVersion=${minimum_system}"
  gate_validate_minimum_system "$minimum_system" || return 1
  codesign --verify --deep --strict --verbose=2 "$app_path" || return $?
  local signing_details
  signing_details="$(codesign -dvvv "$app_path" 2>&1)" || return $?
  print -r -- "$signing_details"
  [[ "$signing_details" == *"Signature=adhoc"* ]]
}

phase_specific_gate_missing() {
  print -u2 -r -- "phase-specific Gate is not implemented for ${phase}; add it only when that phase begins"
  return 1
}

write_result_artifacts() {
  local overall_result="$1"
  local generated_at
  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  python3 - "$checks_tsv" "${result_dir}/result.json" \
    "$phase" "$review_commit" "$generated_at" "$overall_result" "$approvable" "$allow_dirty" <<'PY'
import csv
import json
import sys

checks_path, output_path, phase, commit, generated_at, overall, approvable, allow_dirty = sys.argv[1:]
checks = []
with open(checks_path, encoding="utf-8", newline="") as handle:
    for row in csv.reader(handle, delimiter="\t"):
        check_id, critical, result, message, log_path = row
        checks.append({
            "id": check_id,
            "critical": critical == "true",
            "result": result,
            "message": message,
            "log": log_path or None,
        })

payload = {
    "schemaVersion": 1,
    "phase": phase,
    "reviewCommit": commit,
    "generatedAt": generated_at,
    "overallResult": overall,
    "approvable": approvable == "true",
    "diagnosticDirtyWorkspace": allow_dirty == "1",
    "checks": checks,
}
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
  (( $? == 0 )) || return 1

  {
    print -r -- "# ${phase} local Gate result"
    print -r -- ""
    print -r -- "- Commit: \`${review_commit}\`"
    print -r -- "- Generated: ${generated_at}"
    print -r -- "- Result: **${overall_result}**"
    print -r -- "- Approvable: **${approvable}**"
    print -r -- ""
    print -r -- "Raw check logs and result.json are local artifacts and must not be committed."
  } > "${result_dir}/SUMMARY.md"
  (( $? == 0 )) || return 1
}

while (( $# > 0 )); do
  case "$1" in
    SM-*)
      [[ -z "$phase" ]] || { usage; exit "$exit_usage"; }
      phase="$1"
      shift
      ;;
    --evidence)
      (( $# >= 2 )) || { usage; exit "$exit_usage"; }
      evidence_path="$2"
      shift 2
      ;;
    --results-dir)
      (( $# >= 2 )) || { usage; exit "$exit_usage"; }
      results_root="$2"
      shift 2
      ;;
    --allow-dirty)
      allow_dirty=1
      approvable=false
      shift
      ;;
    *)
      usage
      exit "$exit_usage"
      ;;
  esac
done

gate_valid_phase "$phase" || { usage; exit "$exit_usage"; }
[[ -z "$evidence_path" || -f "$evidence_path" ]] || {
  print -u2 -r -- "找不到等价证据文件: ${evidence_path}"
  exit "$exit_usage"
}

cd "$project_root"
review_commit="$(git rev-parse HEAD 2>/dev/null)" || {
  print -u2 -r -- "当前目录不是有效 Git 工作区"
  exit "$exit_blocked_environment"
}
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
result_dir="${results_root}/${phase}/${timestamp}-${review_commit[1,12]}"
mkdir -p "$result_dir" || {
  print -u2 -r -- "无法创建 Gate 结果目录: ${result_dir}"
  exit "$exit_blocked_environment"
}
checks_tsv="${result_dir}/checks.tsv"
: > "$checks_tsv"

print -r -- "SlateSync ${phase} Gate"
print -r -- "Review commit: ${review_commit}"
print -r -- "Results: ${result_dir}"

run_check workspace_layout true "必需工程、Scheme、Test Plan 与运行入口存在" workspace_layout_check
run_check required_tools true "Swift/Xcode/Git 与产物检查工具可用" required_tools_check
run_check clean_review_target true "审查目标的提交状态符合当前正式/诊断运行模式" clean_workspace_check
run_check forbidden_items true "原生代码不存在冲突标记或禁止的不安全构造" forbidden_items_check
run_check diff_integrity true "Git diff 不含空白错误" git diff --check
run_check gate_self_tests true "Gate 分类、证据替代与批准新鲜度测试通过" \
  ./script/tests/phase_gate_tests.zsh
run_check sm01_foundation_contract true "五模块、macOS 15、Swift 6 与 Xcode 基础契约完整" \
  sm01_foundation_contract_check
run_check sm01_scope_contract true "SM-01 范围、历史基线与生成物边界完整" \
  sm01_scope_contract_check
run_check swift_build true "SwiftPM Debug 构建通过" swift build
run_check swift_test true "SwiftPM 核心测试通过" swift test
run_check xcode_debug_build true "共享 Scheme 的 Xcode Debug 构建通过" \
  xcodebuild -quiet \
  -project SlateSync.xcodeproj \
  -scheme SlateSync \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "${result_dir}/DerivedData/Debug" \
  build
run_check xcode_test_plan true "共享 Test Plan 的 Unit/UI Test 通过" \
  xcodebuild -quiet \
  -project SlateSync.xcodeproj \
  -scheme SlateSync \
  -testPlan SlateSync \
  -destination 'platform=macOS' \
  -derivedDataPath "${result_dir}/DerivedData/Test" \
  test

case "$phase" in
  SM-01)
    run_check sm01_debug_settings true "Debug 为活动架构、-Onone、macOS 15 和完整并发检查" \
      sm01_debug_settings_check
    run_check sm01_real_app_launch true "隔离数据根中启动并确认本次构建的真实 SlateSync 进程" \
      sm01_real_app_launch_check
    run_check sm01_release_build true "Release generic macOS 构建通过" \
      xcodebuild -quiet \
      -project SlateSync.xcodeproj \
      -scheme SlateSync \
      -configuration Release \
      -destination 'generic/platform=macOS' \
      -derivedDataPath "${result_dir}/DerivedData/Release" \
      build
    run_check sm01_release_artifact true "Release 为 Universal、macOS 15.0 且签名有效" \
      sm01_release_artifact_check
    run_check sm01_archive true "共享 Scheme 可生成 Release Archive" \
      xcodebuild -quiet \
      -project SlateSync.xcodeproj \
      -scheme SlateSync \
      -configuration Release \
      -destination 'generic/platform=macOS' \
      -archivePath "${result_dir}/SlateSync.xcarchive" \
      archive
    run_check sm01_archive_artifact true "Archive 为 Universal、macOS 15.0 且签名有效" \
      sm01_archive_artifact_check
    ;;
  *)
    run_check "${phase:l}_specific_gate" true "阶段专用 Gate 已定义" phase_specific_gate_missing
    ;;
esac

if rg -q '"lifecycleState"[[:space:]]*:[[:space:]]*"COMPLETE"' \
  .codex/swift-migration/CURRENT_STATE.json; then
  run_check approval_freshness true "COMPLETE 状态包含匹配当前提交的 Owner 批准" \
    gate_validate_approval_state \
    .codex/swift-migration/CURRENT_STATE.json "$review_commit" "$project_root" "$phase"
else
  record_check approval_freshness true NOT_APPLICABLE \
    "Owner 批准在 Gate PASS 后执行；当前状态尚非 COMPLETE" ""
fi

overall_result="PASS"
if (( overall_failures > 0 )); then
  overall_result="FAIL"
  approvable=false
elif (( overall_environment_blocks > 0 )); then
  overall_result="BLOCKED_ENV"
  approvable=false
fi

write_result_artifacts "$overall_result" || {
  print -u2 -r -- "Gate 检查已执行，但结果工件写入失败"
  exit "$exit_blocked_environment"
}
print -r -- "Gate result: ${overall_result}; approvable=${approvable}"

if [[ "$overall_result" == "FAIL" ]]; then
  exit "$exit_fail"
elif [[ "$overall_result" == "BLOCKED_ENV" ]]; then
  exit "$exit_blocked_environment"
elif [[ "$approvable" != "true" ]]; then
  exit "$exit_diagnostic_only"
fi
exit 0
