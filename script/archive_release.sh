#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"

if (( $# != 3 )); then
  print -u2 "usage: archive_release.sh <absolute-output-directory> <version> <build>"
  exit 64
fi

output_dir="${1:A}"
version="$2"
build_number="$3"
[[ "$1" == /* && "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$build_number" =~ '^[1-9][0-9]*$' ]] || {
  print -u2 "output must be absolute and version/build must be valid"
  exit 64
}
[[ "$output_dir" != "$project_root" && "$output_dir" != "$project_root"/* ]] || {
  print -u2 "release output must stay outside the repository"
  exit 64
}
[[ -z "$(git -C "$project_root" status --porcelain)" ]] || {
  print -u2 "release archives require a clean committed workspace"
  exit 65
}
# Creating the output root atomically prevents two release jobs from sharing
# archive, result-bundle, or DerivedData state.
mkdir "$output_dir" || { print -u2 "release output must be a new directory"; exit 65; }
archive_path="${output_dir}/SlateSync.xcarchive"
derived_data="${output_dir}/DerivedData"
result_bundle="${output_dir}/Archive.xcresult"
toolchain_record="${output_dir}/toolchain.txt"
build_log="${output_dir}/archive.log"

{
  xcodebuild -version
  swift --version
  sw_vers
  xcrun --sdk macosx --show-sdk-version
} > "$toolchain_record"

cd "$project_root"
# Version overrides are explicit build inputs and never rewrite the tracked
# project. The local lane remains ad-hoc while retaining hardened runtime.
if ! xcodebuild clean archive \
  -project SlateSync.xcodeproj \
  -scheme SlateSync \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- > "$build_log" 2>&1; then
  cat "$build_log" >&2
  exit 1
fi

app_path="${archive_path}/Products/Applications/SlateSync.app"
"${script_dir}/verify_bundle.sh" "$app_path" "$version" "$build_number" adhoc
print "$app_path"
