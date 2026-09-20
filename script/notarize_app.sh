#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"

if (( $# != 3 )); then
  print -u2 "usage: notarize_app.sh <SlateSync.app> <submission-zip> <keychain-profile>"
  exit 64
fi

app_path="${1:A}"
submission_zip="${2:A}"
profile="$3"
[[ -d "$app_path" && "$app_path" == */SlateSync.app ]] || { print -u2 "invalid SlateSync.app path"; exit 65; }
[[ "$submission_zip" == /* && "$submission_zip" == *.zip ]] || { print -u2 "submission ZIP must be an absolute .zip path"; exit 64; }
[[ -n "$profile" ]] || { print -u2 "notary keychain profile is required"; exit 64; }
[[ ! -e "$submission_zip" ]] || { print -u2 "submission ZIP already exists: $submission_zip"; exit 65; }

submission_parent="${submission_zip:h}"
[[ -d "$submission_parent" ]] || { print -u2 "submission ZIP parent does not exist"; exit 65; }

# Submit the exact app that will be packaged, then staple the ticket before the
# final ZIP/DMG is generated. Credentials remain in the user's keychain.
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission_zip"
xcrun notarytool submit "$submission_zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
spctl -a -vv --type execute "$app_path"
print "notarized and stapled: $app_path"
