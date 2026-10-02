#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
cd "$project_root"

# This entry point never builds or launches an app, captures the display, or
# runs a foreground performance/UI test. Keep local work and CI on the same
# fast contracts; the complete SM-09 Gate still runs on the remote macOS runner.
python3 -B script/tests/sm09_release_contract.py
python3 -B script/tests/packaged_ui_contract.py --self-test
./script/tests/phase_gate_tests.zsh
# Packaging self-tests use mock inspection/signing/mount tools and disposable
# bundles; no application or foreground test is launched by this check.
./script/tests/release_pipeline_tests.zsh
python3 -B script/tests/sm09_native_contract.py --functional
print 'Headless preflight: PASS; complete SM-09 requires the remote functional Gate and UI coverage checks.'
