#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  print -u2 "usage: verify_app_store_sandbox.sh <SlateSync.app|AppStore.pkg>"
  exit 64
fi

input="${1:A}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/slatesync-app-store-check.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

if [[ "$input" == *.pkg ]]; then
  # Inspect the executable inside the actual upload artifact, not only the archive.
  pkgutil --expand-full "$input" "${scratch}/expanded" >/dev/null
  binaries=("${scratch}"/**/SlateSync.app/Contents/MacOS/SlateSync(N))
  (( ${#binaries} == 1 )) || { print -u2 "expected one SlateSync executable in pkg"; exit 65; }
  executable="$binaries[1]"
elif [[ "$input" == */SlateSync.app ]]; then
  executable="${input}/Contents/MacOS/SlateSync"
else
  print -u2 "expected SlateSync.app or App Store pkg"
  exit 64
fi

[[ -f "$executable" ]] || { print -u2 "SlateSync executable is missing"; exit 65; }
app_path="${executable:h:h:h}"
codesign --verify --deep --strict "$app_path"
codesign -d --xml --entitlements - "$executable" > "${scratch}/entitlements.plist" 2>/dev/null

# plistlib preserves Boolean types, so a string "true" cannot pass this check.
python3 - "${scratch}/entitlements.plist" <<'PY'
import plistlib
import sys

try:
    with open(sys.argv[1], "rb") as handle:
        signed = plistlib.load(handle)
except (OSError, ValueError, plistlib.InvalidFileException) as error:
    raise SystemExit(f"signed entitlements are unreadable: {error}")
for key in (
    "com.apple.security.app-sandbox",
    "com.apple.security.network.client",
    "com.apple.security.files.user-selected.read-write",
):
    if signed.get(key) is not True:
        raise SystemExit(f"missing Boolean true signed entitlement: {key}")
print("signed App Sandbox and app capability entitlements: PASS")
PY
