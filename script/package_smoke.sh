#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
project_root="${script_dir:h}"
source "${script_dir}/lib/phase_gate_lib.sh"
(( $# == 1 )) || { print -u2 'usage: package_smoke.sh <Gate result directory>'; exit 64; }
result_dir="${1:A}"
smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/slatesync-package-smoke.XXXXXX")"
# macOS reports the executable under /private/var even when TMPDIR uses
# /var or a doubled slash. Canonicalize before matching a process for cleanup.
smoke_root="${smoke_root:A}"
app="${smoke_root}/consumer/SlateSync.app"
cleanup() {
  # Stop only the tested bundle before removing its isolated consumer install.
  slatesync_stop_executable SlateSync "${app}/Contents/MacOS/SlateSync" || {
    print -u2 "Packaged application still running; retaining ${smoke_root}"
    return 1
  }
  rm -rf "$smoke_root"
}
trap cleanup EXIT INT TERM
mkdir "${smoke_root}/consumer"
ditto -x -k "${result_dir}/artifacts/SlateSync-1.0.0-macOS-universal.zip" "${smoke_root}/consumer"
"${script_dir}/verify_bundle.sh" "$app" 1.0.0 1 adhoc
# Build only the test harness. XCUIApplication(url:) explicitly launches the
# extracted app, so XCTest cannot silently substitute the development build.
xcodebuild -quiet -project "${project_root}/SlateSync.xcodeproj" -scheme SlateSync \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "${smoke_root}/DerivedData" build-for-testing
python3 - "${smoke_root}/DerivedData/Build/Products" "$app" <<'PY'
import pathlib,plistlib,sys
products=pathlib.Path(sys.argv[1]); paths=list(products.glob('*.xctestrun'))
if len(paths)!=1: raise RuntimeError('expected one test harness')
p=paths[0]; value=plistlib.loads(p.read_bytes()); updated=0
for config in value['TestConfigurations']:
    for target in config['TestTargets']:
        if target.get('BlueprintName')=='SlateSyncUITests':
            target.setdefault('EnvironmentVariables',{})['SLATESYNC_PACKAGED_APP']=sys.argv[2]
            # Register the shipped bundle as XCTest's target too. A URL-only
            # launch leaves the harness associated with the Debug app.
            prior=target['UITargetAppPath']
            target['UITargetAppPath']=sys.argv[2]
            target['DependentProductPaths']=[sys.argv[2] if p==prior else p for p in target.get('DependentProductPaths',[])]
            updated+=1
if updated!=1: raise RuntimeError('packaged app injection failed')
p.write_bytes(plistlib.dumps(value))
PY
xctestrun=("${smoke_root}"/DerivedData/Build/Products/*.xctestrun)
smoke_status=0
xcodebuild -quiet test-without-building -xctestrun "$xctestrun[1]" \
  -destination 'platform=macOS' -only-testing:SlateSyncUITests \
  -resultBundlePath "${smoke_root}/Packaged.xcresult" \
  > "${result_dir}/packaged_ui_xcodebuild.log" 2>&1 || smoke_status=$?
ditto "${smoke_root}/Packaged.xcresult" "${result_dir}/Packaged.xcresult"
xcrun xcresulttool get test-results summary --path "${smoke_root}/Packaged.xcresult" \
  --format json > "${result_dir}/packaged_ui_summary.json"
# Quiet xcodebuild can hide an assertion behind unrelated environment logging.
# Surface XCTest's actual failure text before classification or early exit.
python3 - "${result_dir}/packaged_ui_summary.json" <<'PY'
import json,sys
for failure in json.load(open(sys.argv[1])).get('testFailures', []):
    print('Packaged XCTest failure: '+failure['failureText'])
PY
gate_validate_xcode_test_summary "${result_dir}/packaged_ui_summary.json"
(( smoke_status == 0 )) || exit "$smoke_status"
# Parallel XCTest keeps stdout inside xcresult even when xcodebuild is quiet.
# Read its runner output rather than accepting the harness build as evidence.
xcrun xcresulttool export diagnostics --path "${smoke_root}/Packaged.xcresult" \
  --output-path "${smoke_root}/diagnostics"
python3 - "${result_dir}/packaged_ui_summary.json" "${smoke_root}/diagnostics" "$app" <<'PY'
import json,pathlib,sys
value=json.load(open(sys.argv[1]))
log='\n'.join(p.read_text(errors='replace') for p in pathlib.Path(sys.argv[2]).rglob('StandardOutputAndStandardError.txt'))
assert log.count('SM09_PACKAGED_APP '+sys.argv[3])>=9, 'packaged app URL witness missing'
assert value['passedTests']>=9 and value['failedTests']==0 and value['skippedTests']==0
print('Packaged Release app: nine isolated UI, settings/help/log, task and quit/reopen scenarios passed')
PY
# Cleanup is part of the success contract, not just an ignored EXIT trap.
slatesync_stop_executable SlateSync "${app}/Contents/MacOS/SlateSync"
print 'Packaged application process cleanup: PASS'
