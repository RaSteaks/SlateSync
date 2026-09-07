#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"

if (( $# != 4 )); then
  print -u2 "usage: package_release.sh <SlateSync.app> <absolute-output-directory> <version> <build>"
  exit 64
fi

source_app="${1:A}"
output_dir="${2:A}"
version="$3"
build_number="$4"
[[ "$1" == /* && "$2" == /* && "$source_app" == */SlateSync.app ]] || { print -u2 "app and output paths must be absolute"; exit 64; }
[[ "$output_dir" != "$project_root" && "$output_dir" != "$project_root"/* ]] || { print -u2 "release output must stay outside the repository"; exit 64; }
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$build_number" =~ '^[1-9][0-9]*$' ]] || { print -u2 "invalid version/build"; exit 64; }
if [[ "${GITHUB_REF_TYPE:-}" == tag && "${GITHUB_REF_NAME:-}" != "v${version}" ]]; then
  print -u2 "release tag does not match version"
  exit 65
fi

"${script_dir}/verify_bundle.sh" "$source_app" "$version" "$build_number" adhoc
# A new output directory is an atomic release lock and prevents jobs from
# overwriting one another after both observed that an artifact was absent.
mkdir "$output_dir" || { print -u2 "package output must be a new directory"; exit 65; }
zip_path="${output_dir}/SlateSync-${version}-macOS-universal.zip"
dmg_path="${output_dir}/SlateSync-${version}-macOS-universal.dmg"
checksums="${output_dir}/SHA256SUMS"
manifest="${output_dir}/SlateSync-${version}-manifest.json"
release_notes="${output_dir}/SlateSync-${version}-release-notes.md"

staging="$(mktemp -d "${TMPDIR:-/tmp}/slatesync-package.XXXXXX")"
mount_point="$(mktemp -d "${TMPDIR:-/tmp}/slatesync-mount.XXXXXX")"
zip_check="$(mktemp -d "${TMPDIR:-/tmp}/slatesync-zip-check.XXXXXX")"
mounted=0
completed=0
cleanup() {
  if (( mounted )); then hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true; fi
  rm -rf "$staging" "$mount_point" "$zip_check"
  if (( ! completed )); then
    rm -f "$zip_path" "$dmg_path" "$checksums" "$manifest" "$release_notes"
    rmdir "$output_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

bundle_manifest_hash() {
  # Hash relative paths, permissions, sizes, and bytes. Package round-trips
  # must preserve this lineage exactly even though container hashes may vary.
  python3 - "$1" <<'PY'
import hashlib
import os
import stat
import sys

root = os.path.realpath(sys.argv[1])
digest = hashlib.sha256()
for directory, directories, files in os.walk(root):
    directories.sort()
    files.sort()
    for name in files:
        path = os.path.join(directory, name)
        relative = os.path.relpath(path, root)
        metadata = os.lstat(path)
        if stat.S_ISLNK(metadata.st_mode):
            raise SystemExit(f"symlink is not allowed: {relative}")
        digest.update(relative.encode("utf-8") + b"\0")
        digest.update(f"{stat.S_IMODE(metadata.st_mode):04o}\0{metadata.st_size}\0".encode("ascii"))
        with open(path, "rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
print(digest.hexdigest())
PY
}

source_app_hash="$(bundle_manifest_hash "$source_app")"
ditto "$source_app" "${staging}/SlateSync.app"
[[ "$(bundle_manifest_hash "${staging}/SlateSync.app")" == "$source_app_hash" ]] || {
  print -u2 "staged app does not match audited source"
  exit 65
}
ditto -c -k --sequesterRsrc --keepParent "${staging}/SlateSync.app" "$zip_path"
hdiutil create -quiet -fs HFS+ -format UDZO -volname "SlateSync ${version}" -srcfolder "$staging" "$dmg_path"

ditto -x -k "$zip_path" "$zip_check"
[[ "$(find "$zip_check" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" == 1 ]]
"${script_dir}/verify_bundle.sh" "${zip_check}/SlateSync.app" "$version" "$build_number" adhoc
[[ "$(bundle_manifest_hash "${zip_check}/SlateSync.app")" == "$source_app_hash" ]] || {
  print -u2 "ZIP app lineage mismatch"
  exit 65
}
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount_point" "$dmg_path"
mounted=1
[[ "$(find "$mount_point" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" == 1 ]]
"${script_dir}/verify_bundle.sh" "${mount_point}/SlateSync.app" "$version" "$build_number" adhoc
[[ "$(bundle_manifest_hash "${mount_point}/SlateSync.app")" == "$source_app_hash" ]] || {
  print -u2 "DMG app lineage mismatch"
  exit 65
}
hdiutil detach "$mount_point" -quiet
mounted=0

cp "${project_root}/.codex/swift-migration/manifests/sm09-release-notes.md" "$release_notes"
(cd "$output_dir" && shasum -a 256 "${zip_path:t}" "${dmg_path:t}" "${release_notes:t}" > "${checksums:t}")
commit="$(git -C "$project_root" rev-parse HEAD)"
zip_hash="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
dmg_hash="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
notes_hash="$(shasum -a 256 "$release_notes" | awk '{print $1}')"
resource_manifest_hash="$(shasum -a 256 "${project_root}/.codex/swift-migration/manifests/sm09-native-resources.json" | awk '{print $1}')"
toolchain="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
release_tag="${GITHUB_REF_NAME:-}"
[[ "${GITHUB_REF_TYPE:-}" == tag ]] || release_tag=""
python3 - "$manifest" "$commit" "$release_tag" "$version" "$build_number" "$source_app_hash" "$resource_manifest_hash" "$toolchain" "$sdk_version" "$zip_path" "$zip_hash" "$dmg_path" "$dmg_hash" "$release_notes" "$notes_hash" <<'PY'
import json, os, sys
(path, commit, tag, version, build, app_hash, resource_hash, toolchain,
 sdk_version, zip_path, zip_hash, dmg_path, dmg_hash, notes_path,
 notes_hash) = sys.argv[1:]
document = {
    "schemaVersion": 1,
    "commit": commit,
    "tag": tag or None,
    "version": version,
    "build": int(build),
    "platform": "macOS",
    "architectures": ["arm64", "x86_64"],
    "minimumMacOS": "15.0",
    "toolchain": toolchain,
    "macOSSDK": sdk_version,
    "signingLane": "adhoc-local-validation",
    "developerIDStatus": "BLOCKED_ENV:not-authorized-or-configured",
    "notarizationStatus": "BLOCKED_ENV:not-authorized-or-configured",
    "notarized": False,
    "published": False,
    "appBundleManifestSHA256": app_hash,
    "resourceManifestSHA256": resource_hash,
    "artifacts": [
        {"name": os.path.basename(zip_path), "bytes": os.path.getsize(zip_path), "sha256": zip_hash},
        {"name": os.path.basename(dmg_path), "bytes": os.path.getsize(dmg_path), "sha256": dmg_hash},
        {"name": os.path.basename(notes_path), "bytes": os.path.getsize(notes_path), "sha256": notes_hash},
    ],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY

completed=1
print "packaged local validation artifacts in $output_dir"
