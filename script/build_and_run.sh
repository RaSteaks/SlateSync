#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
derived_data="${project_root}/DerivedData/SlateSync"
configuration="Debug"
show_logs=0
show_telemetry=0
verify_only=0
verification_timeout=10

for argument in "$@"; do
  case "$argument" in
    --debug) configuration="Debug" ;;
    --release) configuration="Release" ;;
    --logs) show_logs=1 ;;
    --telemetry) show_telemetry=1 ;;
    --verify) verify_only=1 ;;
    *) print -u2 "未知参数: $argument"; exit 64 ;;
  esac
done

cd "$project_root"
# Stop only the app bundle produced by this repository before rebuilding it.
pkill -x SlateSync 2>/dev/null || true
for (( attempt = 1; attempt <= 20; attempt += 1 )); do
  pgrep -x SlateSync >/dev/null 2>&1 || break
  sleep 0.1
done
if pgrep -x SlateSync >/dev/null 2>&1; then
  print -u2 "无法停止旧的 SlateSync 进程"
  exit 70
fi
xcodebuild \
  -project SlateSync.xcodeproj \
  -scheme SlateSync \
  -configuration "$configuration" \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  build

app_path="${derived_data}/Build/Products/${configuration}/SlateSync.app"
test -d "$app_path"
/usr/bin/open -n "$app_path"

# `open` returns before LaunchServices finishes spawning the process. Polling
# gives Gate automation a deterministic launch result instead of a bundle-only check.
if (( verify_only )); then
  for (( attempt = 1; attempt <= verification_timeout * 4; attempt += 1 )); do
    if process_id="$(pgrep -x SlateSync | head -n 1)"; then
      print "已验证启动: $app_path (pid=$process_id)"
      exit 0
    fi
    sleep 0.25
  done
  print -u2 "启动验证失败: ${verification_timeout} 秒内未发现 SlateSync 进程"
  exit 70
fi

if (( show_logs )); then
  log stream --style compact --predicate 'process == "SlateSync"'
elif (( show_telemetry )); then
  log stream --style json --predicate 'process == "SlateSync"'
fi
