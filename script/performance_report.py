#!/usr/bin/env python3
"""Run advisory benchmarks without changing their assertions or exit status."""
import argparse
import json
import os
import re
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BENCHMARKS = (
    "testNativeCSVReusesViewsForTenThousandRowsAndReleasesOwners",
    "testForegroundCSVMeetsDisplayCadenceBudget",
    "testFiveSampleProjectAndTaskNativeListScale",
    "testRealSQLiteProjectAndTaskScaleLoad",
    "testTenThousandRowIndexedMergeTimingAndScaling",
)
METRICS = (
    "native-csv-foreground.json", "native-csv-scale.json",
    "native-project-task-scale.json", "real-sqlite-scale.json",
)


def run(output: Path) -> int:
    # Never mix a new attempt with stale metric files or overwrite a prior report.
    if output.exists() and any(output.iterdir()):
        raise ValueError("Choose a new or empty results directory; existing reports are preserved")
    output.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, SLATESYNC_PERFORMANCE_POLICY="strict",
                       SLATESYNC_SM08_FOREGROUND_GATE="1", SM05_PERFORMANCE_GATE="1",
                       SLATESYNC_SM08_METRICS_DIR=str(output / "metrics"))
    command = ["swift", "test", "--configuration", "release", "--filter", "|".join(BENCHMARKS)]
    with (output / "benchmarks.log").open("w") as log:
        try:
            code = subprocess.run(command, cwd=ROOT, env=environment, stdout=log,
                                  stderr=subprocess.STDOUT, check=False).returncode
        except OSError as error:
            log.write(str(error) + "\n")
            code = 127
    metrics = {}
    for name in METRICS:
        path = output / "metrics" / name
        if path.exists():
            try:
                metrics[name] = json.loads(path.read_text())
            except (OSError, ValueError) as error:
                metrics[name] = {"error": str(error)}
                code = code or 1
    # A zero exit with an empty filter or missing metrics is not evidence.
    log_text = (output / "benchmarks.log").read_text(errors="replace")
    missing_tests = [name for name in BENCHMARKS if not re.search(r"\b" + re.escape(name) + r"\]' passed", log_text)]
    missing_metrics = [name for name in METRICS if name not in metrics]
    if missing_tests or missing_metrics:
        code = code or 1
    result = {"missingTests": missing_tests, "missingMetrics": missing_metrics, "scope": "advisory-performance", "passed": code == 0,
              "exitCode": code, "command": command, "metrics": metrics}
    (output / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    summary = ("## Performance report (non-blocking)\n\n"
               + ("PASS" if code == 0 else "FAIL — budget exceeded or benchmark execution failed")
               + "\n\nThis report does not approve a release. Functional merge checks remain required.\n\n"
               + "See `benchmarks.log` and `result.json` for the complete result.\n\n```json\n"
               + json.dumps(metrics, ensure_ascii=False, indent=2) + "\n```\n")
    (output / "SUMMARY.md").write_text(summary)
    if destination := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(destination, "a") as handle:
            handle.write(summary)
    if code:
        print("::warning::Advisory performance check failed; see the performance report and artifacts.")
    else:
        print("Advisory performance checks passed.")
    # The workflow alone makes this advisory. Local callers still receive failure.
    return 1 if code else 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--results-dir", required=True, type=Path)
    args = parser.parse_args()
    try:
        raise SystemExit(run(args.results_dir.resolve()))
    except ValueError as error:
        parser.error(str(error))
