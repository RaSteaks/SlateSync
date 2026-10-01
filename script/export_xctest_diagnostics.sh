#!/bin/zsh
set -uo pipefail

# Retain raw results even when --only-failures returns an empty manifest. They
# contain the AX snapshots, screenshots and runner output for hosted macOS.
(( $# == 1 )) || { print -u2 'usage: export_xctest_diagnostics.sh <Gate results root>'; exit 64; }
gate_root="${1:A}"
export_status=0
bundle_count=0
if [[ ! -d "$gate_root" ]]; then
  print 'No XCTest results: Gate stopped before UI execution'
  exit 0
fi
# Check enumeration explicitly; process substitution would hide a find failure.
bundle_list="$(mktemp "${TMPDIR:-/tmp}/slatesync-xctest-bundles.XXXXXX")" || exit 1
trap 'rm -f "$bundle_list"' EXIT
find "$gate_root" -type d -name '*.xcresult' -prune -print0 > "$bundle_list" || exit 1
while IFS= read -r -d '' bundle; do
  (( bundle_count += 1 ))
  result_dir="${bundle:h}"
  bundle_name="${bundle:t}"
  output_path="${result_dir}/xcresult-failure-attachments/${bundle_name}"
  mkdir -p "$output_path" || { export_status=1; continue; }
  print -r -- "Retaining XCTest diagnostics: ${bundle}"
  if ! ditto -c -k --keepParent "$bundle" "${result_dir}/${bundle_name}.zip"; then export_status=1; fi
  if ! xcrun xcresulttool get test-results summary --path "$bundle" --format json \
      > "${result_dir}/${bundle_name}.summary.json"; then export_status=1; fi
  if ! xcrun xcresulttool get test-results tests --path "$bundle" --format json \
      > "${result_dir}/${bundle_name}.tests.json"; then export_status=1; fi
  if ! xcrun xcresulttool export attachments --path "$bundle" --output-path "$output_path" --only-failures; then
    export_status=1
  fi
  if ! xcrun xcresulttool export diagnostics --path "$bundle" \
      --output-path "${result_dir}/xcresult-diagnostics/${bundle_name}"; then export_status=1; fi
done < "$bundle_list"
if (( bundle_count == 0 )); then print 'No XCTest result bundles available for diagnostics'; fi
exit "$export_status"
