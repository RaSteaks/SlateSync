#!/bin/zsh
set -uo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h:h}"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/slatesync-release-tests.XXXXXX")"
fake_bin="${fixture_root}/bin"
passed=0
failed=0
trap 'rm -rf "$fixture_root"' EXIT INT TERM
mkdir -p "$fake_bin"

assert_success() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    print "PASS: $label"
    (( passed += 1 ))
  else
    print -u2 "FAIL: $label"
    (( failed += 1 ))
  fi
}

assert_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    print -u2 "FAIL: $label"
    (( failed += 1 ))
  else
    print "PASS: $label"
    (( passed += 1 ))
  fi
}

create_app() {
  local app="$1"
  mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources/PaddleOCR"
  cat > "${app}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>SlateSync</string>
<key>CFBundleIdentifier</key><string>com.slatesync.app</string>
<key>CFBundleName</key><string>SlateSync</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
  print '#!/bin/zsh' > "${app}/Contents/MacOS/SlateSync"
  chmod +x "${app}/Contents/MacOS/SlateSync"
  cp "${project_root}/SlateSyncApp/Resources/PaddleOCR/paddleocr_runner.py" \
    "${app}/Contents/Resources/PaddleOCR/paddleocr_runner.py"
  cp "${project_root}/SlateSyncApp/Resources/PaddleOCR/requirements-ocr.txt" \
    "${app}/Contents/Resources/PaddleOCR/requirements-ocr.txt"
}

# Fake only platform inspection/signing tools. Real filesystem, plist, hashing,
# ZIP, and ditto operations keep package cleanup and lineage tests meaningful.
cat > "${fake_bin}/lipo" <<'SH'
#!/bin/zsh
print "${MOCK_ARCHS:-arm64 x86_64}"
SH
cat > "${fake_bin}/codesign" <<'SH'
#!/bin/zsh
if [[ "$*" == *--verify* && "${MOCK_SIGNATURE_FAIL:-0}" == 1 ]]; then exit 1; fi
if [[ "$1" == -dvvv ]]; then
  [[ "${MOCK_HARDENED_MISSING:-0}" == 1 ]] || print -u2 'CodeDirectory flags=0x10000(runtime)'
  print -u2 'Signature=adhoc'
elif [[ "$1" == -d && "$2" == --entitlements ]]; then
  print -u2 'Executable=fixture'
fi
SH
cat > "${fake_bin}/file" <<'SH'
#!/bin/zsh
path="${@[-1]}"
if [[ "${path:t}" == SlateSync ]]; then print "${path}: Mach-O 64-bit executable"; else print "${path}: data"; fi
SH
cat > "${fake_bin}/otool" <<'SH'
#!/bin/zsh
print "${@[-1]}:"
print '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)'
SH
cat > "${fake_bin}/xcodebuild" <<'SH'
#!/bin/zsh
print 'Xcode 26.3'
print 'Build version 17C529'
SH
cat > "${fake_bin}/xcrun" <<'SH'
#!/bin/zsh
print '26.2'
SH
cat > "${fake_bin}/hdiutil" <<'SH'
#!/bin/zsh
case "$1" in
  create)
    [[ "${MOCK_CREATE_FAIL:-0}" == 1 ]] && exit 1
    : > "${@[-1]}"
    ;;
  attach)
    [[ "${MOCK_MOUNT_FAIL:-0}" == 1 ]] && exit 1
    mount_point=""
    for (( index = 1; index <= $#; index += 1 )); do
      if [[ "${@[index]}" == -mountpoint ]]; then mount_point="${@[index + 1]}"; fi
    done
    /usr/bin/ditto "$MOCK_SOURCE_APP" "${mount_point}/SlateSync.app"
    ;;
  detach) ;;
  *) exit 1 ;;
esac
SH
chmod +x "$fake_bin"/*
export PATH="${fake_bin}:${PATH}"

app="${fixture_root}/valid/SlateSync.app"
create_app "$app"
export MOCK_SOURCE_APP="$app"
assert_success "valid audited bundle" "${project_root}/script/verify_bundle.sh" "$app" 1.0.0 1 adhoc

assert_failure "single architecture is rejected" env MOCK_ARCHS=arm64 \
  "${project_root}/script/verify_bundle.sh" "$app" 1.0.0 1 adhoc
assert_failure "signature failure is rejected" env MOCK_SIGNATURE_FAIL=1 \
  "${project_root}/script/verify_bundle.sh" "$app" 1.0.0 1 adhoc
assert_failure "missing hardened runtime is rejected" env MOCK_HARDENED_MISSING=1 \
  "${project_root}/script/verify_bundle.sh" "$app" 1.0.0 1 adhoc

bad_resource="${fixture_root}/bad-resource/SlateSync.app"
/usr/bin/ditto "$app" "$bad_resource"
print 'drift' >> "${bad_resource}/Contents/Resources/PaddleOCR/requirements-ocr.txt"
assert_failure "resource drift is rejected" "${project_root}/script/verify_bundle.sh" "$bad_resource" 1.0.0 1 adhoc

symlink_app="${fixture_root}/symlink/SlateSync.app"
/usr/bin/ditto "$app" "$symlink_app"
ln -s /tmp "${symlink_app}/Contents/Resources/escape"
assert_failure "bundle symlink is rejected" "${project_root}/script/verify_bundle.sh" "$symlink_app" 1.0.0 1 adhoc

renderer_app="${fixture_root}/renderer/SlateSync.app"
/usr/bin/ditto "$app" "$renderer_app"
print '<html></html>' > "${renderer_app}/Contents/Resources/index.html"
assert_failure "renderer residue is rejected" "${project_root}/script/verify_bundle.sh" "$renderer_app" 1.0.0 1 adhoc

package_output="${fixture_root}/artifacts"
assert_success "ZIP and DMG round-trip" \
  "${project_root}/script/package_release.sh" "$app" "$package_output" 1.0.0 1
assert_success "package manifest and checksums are complete" test -s "${package_output}/SlateSync-1.0.0-manifest.json"
assert_success "package notes are bilingual" rg -q '本地验证候选包' "${package_output}/SlateSync-1.0.0-release-notes.md"
assert_failure "concurrent output is rejected" \
  "${project_root}/script/package_release.sh" "$app" "$package_output" 1.0.0 1
assert_failure "empty version is rejected" \
  "${project_root}/script/package_release.sh" "$app" "${fixture_root}/empty-version" '' 1

mount_failure="${fixture_root}/mount-failure"
assert_failure "mount failure propagates" env MOCK_MOUNT_FAIL=1 \
  "${project_root}/script/package_release.sh" "$app" "$mount_failure" 1.0.0 1
assert_success "mount failure removes partial output" test ! -e "$mount_failure"

create_failure="${fixture_root}/create-failure"
assert_failure "DMG creation failure propagates" env MOCK_CREATE_FAIL=1 \
  "${project_root}/script/package_release.sh" "$app" "$create_failure" 1.0.0 1
assert_success "DMG failure removes partial output" test ! -e "$create_failure"

print "Release pipeline tests: ${passed} passed, ${failed} failed"
(( failed == 0 ))
