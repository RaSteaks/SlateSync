#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
source "${script_dir}/lib/phase_gate_lib.sh"

if (( $# < 3 || $# > 4 )); then
  print -u2 "usage: verify_bundle.sh <SlateSync.app> <version> <build> [adhoc|developer-id]"
  exit 64
fi

app_path="${1:A}"
expected_version="$2"
expected_build="$3"
lane="${4:-adhoc}"
executable="${app_path}/Contents/MacOS/SlateSync"
info="${app_path}/Contents/Info.plist"
resources="${app_path}/Contents/Resources"
resource_manifest="${project_root}/.codex/swift-migration/manifests/sm09-native-resources.json"

[[ "$app_path" == /*/SlateSync.app && -d "$app_path" && ! -L "$app_path" ]] || { print -u2 "invalid app path"; exit 65; }
[[ "$expected_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$expected_build" =~ '^[1-9][0-9]*$' ]] || {
  print -u2 "invalid expected version/build"
  exit 64
}
[[ -x "$executable" && -f "$info" ]] || { print -u2 "missing app executable or Info.plist"; exit 65; }
symlink_path="$(find "$app_path" -type l -print -quit)"
[[ -z "$symlink_path" ]] || { print -u2 "bundle symlink is not allowed: $symlink_path"; exit 65; }

architectures="$(lipo -archs "$executable")"
architecture_list=(${=architectures})
architecture_list=(${(on)architecture_list})
[[ "${(j: :)architecture_list}" == "arm64 x86_64" ]] || {
  print -u2 "unexpected architectures: $architectures"
  exit 65
}
minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info")"
gate_validate_minimum_system "$minimum_system" || { print -u2 "unexpected minimum system: $minimum_system"; exit 65; }
actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")"
[[ "$actual_version" == "$expected_version" && "$actual_build" == "$expected_build" ]] || {
  print -u2 "bundle version mismatch: ${actual_version} (${actual_build})"
  exit 65
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" == "com.slatesync.app" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info")" == "SlateSync" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$info")" == "SlateSync" ]]

# The tracked manifest is the single audit source for canonical resource bytes.
# Entries with a bundle path must match both source and packaged copies.
python3 - "$resource_manifest" "$project_root" "$resources" <<'PY'
import hashlib
import json
import os
import sys

manifest_path, root, resources = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
for item in manifest["resources"]:
    source = os.path.join(root, item["source"])
    with open(source, "rb") as handle:
        source_bytes = handle.read()
    assert len(source_bytes) == item["bytes"], item["source"]
    assert hashlib.sha256(source_bytes).hexdigest() == item["sha256"], item["source"]
    if bundle_path := item.get("bundle"):
        target = os.path.join(resources, bundle_path)
        with open(target, "rb") as handle:
            bundle_bytes = handle.read()
        assert bundle_bytes == source_bytes, bundle_path

paddle_root = os.path.join(resources, manifest["bundlePolicy"]["paddleRoot"].split("Contents/Resources/", 1)[-1])
actual = sorted(os.listdir(paddle_root))
assert actual == sorted(manifest["bundlePolicy"]["allowedPaddleFiles"]), actual
PY

# Paddle's one .py source is the only script allowed in the final bundle.
# Any renderer/package/runtime residue makes the audit fail immediately.
forbidden_path="$(find "$app_path" \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.ts' -o -name '*.tsx' -o -name '*.map' -o -name '*.html' -o -name '*.css' -o -name 'app.asar' -o -name 'node_modules' -o -name 'package.json' -o -name 'package-lock.json' -o -name 'Electron Framework.framework' -o -name 'Chromium Framework.framework' \) -print -quit)"
[[ -z "$forbidden_path" ]] || { print -u2 "forbidden bundle input: $forbidden_path"; exit 65; }
python_residue="$(find "$resources" \( -name '__pycache__' -o -name '*.pyc' -o -name '.venv' -o -name 'venv' \) -print -quit)"
[[ -z "$python_residue" ]] || { print -u2 "forbidden Python runtime residue: $python_residue"; exit 65; }

codesign --verify --deep --strict --verbose=2 "$app_path"
signing_details="$(codesign -dvvv "$app_path" 2>&1)"
[[ "$signing_details" == *"flags="*"runtime"* ]] || { print -u2 "hardened runtime is missing"; exit 65; }
case "$lane" in
  adhoc) [[ "$signing_details" == *"Signature=adhoc"* ]] || { print -u2 "bundle is not ad-hoc signed"; exit 65; } ;;
  developer-id) [[ "$signing_details" == *"Authority=Developer ID Application:"* ]] || { print -u2 "bundle lacks Developer ID signature"; exit 65; } ;;
  *) print -u2 "unknown signing lane: $lane"; exit 64 ;;
esac

# The frozen entitlement baseline is empty for Release. Any entitlement added
# to make signing pass changes the product capability boundary and fails here.
entitlements="$(codesign -d --entitlements - "$app_path" 2>&1)"
[[ "$entitlements" != *"[Key]"* && "$entitlements" != *"<key>"* ]] || {
  print -u2 "unexpected Release entitlement"
  exit 65
}

# Audit each Mach-O dependency. Relative dependencies must resolve to a file
# shipped inside this app; absolute dependencies are restricted to macOS.
mach_o_files="$(find "${app_path}/Contents" -type f -exec file {} \; | sed -n 's/: Mach-O.*$//p')" || {
  print -u2 "Mach-O traversal failed"
  exit 65
}
[[ "$mach_o_files" == *"$executable"* ]] || { print -u2 "main Mach-O was not audited"; exit 65; }
while IFS= read -r macho; do
  dependency_output="$(otool -L "$macho")" || { print -u2 "dependency audit failed: $macho"; exit 65; }
  while IFS= read -r dependency_line; do
    [[ "$dependency_line" == *" (architecture "*"):" ]] && continue
    dependency="$(print -r -- "$dependency_line" | awk '{print $1}')"
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /System/Library/*|/usr/lib/*) ;;
      @rpath/*|@loader_path/*|@executable_path/*)
        dependency_name="${dependency:t}"
        [[ -n "$(find "${app_path}/Contents" -type f -name "$dependency_name" -print -quit)" ]] || {
          print -u2 "unresolved bundled dependency: $dependency"
          exit 65
        }
        ;;
      *) print -u2 "unapproved dependency: $dependency"; exit 65 ;;
    esac
    [[ "$dependency" != *Electron* && "$dependency" != *Chromium* && "$dependency" != *node* ]] || {
      print -u2 "forbidden runtime dependency: $dependency"
      exit 65
    }
  done < <(print -r -- "$dependency_output" | tail -n +2)
  [[ "$macho" == "$executable" ]] || codesign --verify --strict --verbose=2 "$macho"
done <<< "$mach_o_files"

print "verified ${lane} bundle: version=${actual_version} build=${actual_build} architectures=arm64,x86_64 minimum=${minimum_system}"
