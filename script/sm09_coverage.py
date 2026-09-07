#!/usr/bin/env python3
"""Map every SM-09 legacy removal candidate to native acceptance ownership."""

import hashlib
import json
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INVENTORY = REPO / ".codex/swift-migration/manifests/sm09-inventory.json"
OUTPUT = REPO / ".codex/swift-migration/manifests/sm09-coverage.json"
BASELINE = REPO / ".codex/swift-migration/manifests/sm09-pre-cutover.json"

FAMILIES = {
    "native-gate": {
        "acceptanceIDs": ["CUT-03", "CUT-06", "CUT-07", "CAR-05"],
        "replacement": ["script/phase_gate.sh", "script/lib/phase_gate_lib.sh", "script/tests/phase_gate_tests.zsh"],
    },
    "native-release": {
        "acceptanceIDs": ["ARC-01", "ARC-08", "REL-01", "REL-04", "CUT-02", "CUT-06"],
        "replacement": ["SlateSync.xcodeproj", ".github/workflows/ci.yml", ".github/workflows/release.yml"],
    },
    "app-shell-ui": {
        "acceptanceIDs": ["MAT-02", "CUT-02", "CUT-03", "CUT-08"],
        "replacement": ["SlateSyncApp", "Sources/SlateSyncUI", "SlateSyncUITests", "Tests/SlateSyncUIUnitTests"],
    },
    "persistence-workflow": {
        "acceptanceIDs": ["MAT-04", "DAT-01", "DAT-02", "DAT-04"],
        "replacement": ["Sources/SlateSyncPersistence", "Tests/SlateSyncPersistenceTests"],
    },
    "csv-metadata-scenario": {
        "acceptanceIDs": ["MAT-05", "DAT-02", "CAR-06"],
        "replacement": ["Sources/SlateSyncWorkflow", "Tests/SlateSyncWorkflowTests/Fixtures/SM05", "Tests/SlateSyncWorkflowTests"],
    },
    "media-ocr": {
        "acceptanceIDs": ["MAT-05", "CUT-05", "CAR-01", "CAR-04"],
        "replacement": ["Sources/SlateSyncMedia", "Tests/SlateSyncMediaTests", "Tests/SlateSyncWorkflowTests/MediaOCRWorkflowTests.swift"],
    },
    "provider-recognition": {
        "acceptanceIDs": ["MAT-05", "DAT-03"],
        "replacement": ["Sources/SlateSyncDomain", "Sources/SlateSyncWorkflow", "Tests/SlateSyncWorkflowTests/Fixtures/SM07"],
    },
}


def family_for(path: str) -> str:
    lower = path.lower()
    if path.startswith("script/tests/"):
        return "native-gate"
    if path.startswith(("scripts/", ".storybook/")) or path in {
        "electron-builder.yml", "package.json", "package-lock.json",
        "playwright.config.ts", "vitest.config.ts",
    } or lower.startswith(("tsconfig", "vite")):
        return "native-release"
    if path.startswith("electron/"):
        return "app-shell-ui"
    if any(token in lower for token in ("ocr", "paddle", "vision", "image", "media")):
        return "media-ocr"
    if any(token in lower for token in ("csv", "metadata", "scenario", "slate-scanner", "slate_scanner")):
        return "csv-metadata-scenario"
    if any(token in lower for token in ("provider", "model", "recognition", "ai-client", "http-timeout", "config", "settings", "key-store", "logger")):
        return "provider-recognition"
    if any(token in lower for token in ("project", "library", "persistence", "task", "sqlite", "autosave", "workflow")):
        return "persistence-workflow"
    if path.startswith(("src/", "public/", "test/", "test-support/", "lib/")):
        return "app-shell-ui"
    raise ValueError(f"unowned legacy removal candidate: {path}")


def main() -> int:
    inventory_bytes = INVENTORY.read_bytes()
    inventory = json.loads(inventory_bytes)
    baseline = json.loads(BASELINE.read_bytes())
    entries = []
    counts = {name: 0 for name in FAMILIES}
    for item in inventory["files"]:
        if item["category"] != "legacy-remove":
            continue
        family = family_for(item["path"])
        counts[family] += 1
        entries.append({
            "path": item["path"],
            "preCutoverSha256": item["sha256"],
            "family": family,
            "disposition": "remove-after-final-pre-cutover-pass",
            **FAMILIES[family],
        })
    document = {
        "schemaVersion": 1,
        "sourceInventorySha256": hashlib.sha256(inventory_bytes).hexdigest(),
        "baselineCommit": baseline["commit"],
        "status": "BASELINE_COVERED; FINAL_REFRESH_REQUIRED_BEFORE_WP6",
        "summary": {"legacyRemove": len(entries), "families": counts, "unowned": 0},
        "entries": entries,
    }
    OUTPUT.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"coverage: {len(entries)} legacy files, 0 unowned -> {OUTPUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
