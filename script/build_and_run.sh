#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
derived_data="${project_root}/DerivedData/SlateSync"
source "${script_dir}/lib/phase_gate_lib.sh"

# This is the native app's current run entry; fail before invoking Xcode when
# it is accidentally called from a non-macOS host.
if [[ "$(uname -s)" != "Darwin" ]]; then
  print -u2 "[SlateSync] 当前产品仅支持在 macOS 主机上运行 macOS 应用。"
  exit 1
fi

configuration="Debug"
show_logs=0
show_telemetry=0
verify_only=0
background_launch=0
verification_timeout=10

for argument in "$@"; do
  case "$argument" in
    --debug) configuration="Debug" ;;
    --release) configuration="Release" ;;
    --logs) show_logs=1 ;;
    --telemetry) show_telemetry=1 ;;
    --verify) verify_only=1 ;;
    --background) background_launch=1 ;;
    *) print -u2 "未知参数: $argument"; exit 64 ;;
  esac
done

cd "$project_root"
app_path="${derived_data}/Build/Products/${configuration}/SlateSync.app"
app_executable="${app_path}/Contents/MacOS/SlateSync"
# Process ownership is determined by the full executable path, not the shared
# process name, so development runs never terminate another SlateSync install.
if ! slatesync_stop_executable SlateSync "$app_executable"; then
  print -u2 "无法停止本仓库构建的旧 SlateSync 进程: $app_executable"
  exit 70
fi
xcodebuild \
  -project SlateSync.xcodeproj \
  -scheme SlateSync \
  -configuration "$configuration" \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  build

test -d "$app_path"
test -x "$app_executable"
# Automated Gate runs launch without activating the app, while the normal Run
# action preserves the expected foreground development experience.
if (( background_launch )); then
  /usr/bin/open -g -n "$app_path"
else
  /usr/bin/open -n "$app_path"
fi

# `open` returns before LaunchServices finishes spawning the process. Polling
# gives Gate automation a deterministic launch result instead of a bundle-only check.
if (( verify_only )); then
  for (( attempt = 1; attempt <= verification_timeout * 4; attempt += 1 )); do
    process_id="$(slatesync_process_ids_for_executable SlateSync "$app_executable" | head -n 1)"
    if [[ -n "$process_id" ]]; then
      print "已验证启动: $app_path (pid=$process_id, executable=$app_executable)"
      exit 0
    fi
    sleep 0.25
  done
  print -u2 "启动验证失败: ${verification_timeout} 秒内未发现本次构建的 SlateSync 进程"
  exit 70
fi

if (( show_logs )); then
  log stream --style compact --predicate 'process == "SlateSync"'
elif (( show_telemetry )); then
  log stream --style json --predicate 'process == "SlateSync"'
fi
