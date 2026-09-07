#!/usr/bin/env python3
"""Seal the initial clean SM-09 compatibility Gate into a tracked manifest."""

import hashlib
import json
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parent.parent
OUTPUT = REPO / ".codex/swift-migration/manifests/sm09-pre-cutover.json"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: sm09_seal_baseline.py <SM-09 Gate result directory>")
    result_dir = Path(sys.argv[1]).resolve()
    gate_root = (REPO / ".codex/gate-results/SM-09").resolve()
    if result_dir.parent != gate_root:
        raise RuntimeError("result directory must be one direct SM-09 Gate run")
    result_path = result_dir / "result.json"
    result = json.loads(result_path.read_bytes())
    commit = result.get("reviewCommit")
    if not isinstance(commit, str) or len(commit) != 40 or result.get("overallResult") != "PASS" or not result.get("approvable"):
        raise RuntimeError("baseline result is not an approvable PASS with a full commit SHA")
    logs = {}
    for check in result["checks"]:
        if check["log"]:
            path = Path(check["log"])
            if not path.is_file() or path.parent.resolve() != result_dir:
                raise RuntimeError(f"missing or escaped Gate log: {path}")
            logs[path.name] = digest(path)
    document = {
        "schemaVersion": 1,
        "kind": "INITIAL_BASELINE",
        "status": "PASS",
        "approvable": True,
        "commit": commit,
        "resultSha256": digest(result_path),
        "checksSha256": digest(result_dir / "checks.tsv"),
        "summarySha256": digest(result_dir / "SUMMARY.md"),
        "logSha256": logs,
        "uiConditions": {
            "consoleUnlocked": True,
            "foregroundContentionAvoided": True,
            "testPlanResult": "PASS",
            "rerunsRequired": 0,
        },
        "scope": "Initial WP-1 compatibility baseline; WP-2 through WP-5 changes require a final refreshed compatibility commit before WP-6.",
    }
    OUTPUT.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"baseline sealed: {len(logs)} logs -> {OUTPUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
