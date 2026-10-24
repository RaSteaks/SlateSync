#!/usr/bin/env python3
"""Export each failed test's attachments, including screenshots added in teardown."""
import argparse
import json
from pathlib import Path
import subprocess


def export_failures(bundle: Path, summary: dict, output: Path, run=subprocess.run) -> None:
    # --only-failures filters attachment activity, not just failed test cases:
    # XCTest teardown screenshots can disappear even when the test failed.
    # Per-test directories also prevent xcresulttool overwriting earlier manifests.
    failures = summary.get("testFailures", [])
    identifiers = sorted({entry["testIdentifierString"] for entry in failures
                          if isinstance(entry, dict) and entry.get("testIdentifierString")})
    errors = []
    for index, identifier in enumerate(identifiers, 1):
        destination = output / f"failed-test-{index}"
        try:
            # Filesystem errors belong to this test too. A blocked first
            # directory must not prevent later failure screenshots being saved.
            destination.mkdir(parents=True, exist_ok=True)
            (destination / "test-id.txt").write_text(identifier + "\n")
            run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
                 "--output-path", str(destination), "--test-id", identifier], check=True)
        except (OSError, subprocess.CalledProcessError) as error:
            errors.append(f"{identifier}: {error}")
    if errors:
        raise RuntimeError(f"failed to export test attachments: {errors}")
    if not identifiers:
        print("No named test failures; raw xcresult and runner diagnostics remain the evidence")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("summary", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    export_failures(args.bundle, json.loads(args.summary.read_text()), args.output)


if __name__ == "__main__":
    main()
