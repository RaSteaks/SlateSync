#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"

if (( $# < 3 || $# > 5 )); then
  print -u2 "usage: archive_release.sh <absolute-output-directory> <version> <build> [adhoc|developer-id] [identity]"
  exit 64
fi

output_dir="${1:A}"
version="$2"
build_number="$3"
lane="${4:-${SLATESYNC_SIGNING_LANE:-adhoc}}"
identity="${5:-${SLATESYNC_SIGNING_IDENTITY:-}}"
[[ "$1" == /* && "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$build_number" =~ '^[1-9][0-9]*$' ]] || {
  print -u2 "output must be absolute and version/build must be valid"
  exit 64
}
case "$lane" in
  adhoc)
    signing_identity="-"
    ;;
  developer-id)
    [[ -n "$identity" && "$identity" != "-" ]] || {
      print -u2 "developer-id lane requires a Developer ID Application identity"
      exit 64
    }
    [[ -n "${DEVELOPMENT_TEAM:-}" ]] || {
      print -u2 "developer-id lane requires DEVELOPMENT_TEAM"
      exit 64
    }
    signing_identity="$identity"
    ;;
  *)
    print -u2 "unknown signing lane: $lane"
    exit 64
    ;;
esac
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
# Version and signing overrides are explicit build inputs and never rewrite the
# tracked project. The default lane stays ad-hoc for local validation; the
# developer-id lane requires an installed Developer ID Application identity.
signing_arguments=(
  "CODE_SIGN_STYLE=Manual"
  "CODE_SIGN_IDENTITY=${signing_identity}"
)
if [[ "$lane" == developer-id ]]; then
  signing_arguments+=("DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}" "OTHER_CODE_SIGN_FLAGS=--timestamp")
fi
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
  "${signing_arguments[@]}" > "$build_log" 2>&1; then
  cat "$build_log" >&2
  exit 1
fi

app_path="${archive_path}/Products/Applications/SlateSync.app"
"${script_dir}/verify_bundle.sh" "$app_path" "$version" "$build_number" "$lane"
print "$app_path"
