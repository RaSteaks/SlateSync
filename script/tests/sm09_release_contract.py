#!/usr/bin/env python3
"""Static SM-09 contracts for native resources, Xcode, and workflows."""

from __future__ import annotations

import hashlib
import json
import plistlib
import re
import stat
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def validate_yaml_shape(source: str, label: str) -> None:
    """Validate the strict workflow subset without adding a YAML dependency."""

    require("\t" not in source, f"{label}: YAML contains tabs")
    require(source.count("${{") == source.count("}}"), f"{label}: unmatched expression")
    top_level: set[str] = set()
    block_indent: int | None = None
    for number, raw in enumerate(source.splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        require(indent % 2 == 0, f"{label}:{number}: indentation must use pairs of spaces")
        if block_indent is not None:
            if indent > block_indent:
                continue
            block_indent = None
        if raw.rstrip().endswith("|"):
            block_indent = indent
        if indent == 0:
            match = re.fullmatch(r"([A-Za-z][A-Za-z0-9_-]*):(?:.*)", raw)
            require(match is not None, f"{label}:{number}: malformed top-level key")
            require(match.group(1) not in top_level, f"{label}: duplicate top-level key")
            top_level.add(match.group(1))
    require({"name", "on", "permissions", "jobs"} <= top_level, f"{label}: missing workflow key")


def validate_resources(manifest: dict[str, object]) -> None:
    resources = manifest.get("resources")
    require(isinstance(resources, list) and resources, "resource manifest is empty")
    seen: set[str] = set()
    for entry in resources:
        require(isinstance(entry, dict), "resource entry must be an object")
        source = str(entry["source"])
        require(source not in seen, f"duplicate resource source: {source}")
        seen.add(source)
        data = (ROOT / source).read_bytes()
        require(len(data) == entry["bytes"], f"resource byte count drift: {source}")
        require(hashlib.sha256(data).hexdigest() == entry["sha256"], f"resource hash drift: {source}")

    tracked = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "--cached", "--others", "--exclude-standard"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    paddle_names = {"paddleocr_runner.py", "requirements-ocr.txt"}
    paddle_paths = sorted(
        path for path in tracked if Path(path).name in paddle_names and (ROOT / path).is_file()
    )
    require(
        paddle_paths
        == [
            "SlateSyncApp/Resources/PaddleOCR/paddleocr_runner.py",
            "SlateSyncApp/Resources/PaddleOCR/requirements-ocr.txt",
        ],
        f"PaddleOCR resources are not canonical: {paddle_paths}",
    )


def validate_xcode() -> None:
    project = read("SlateSync.xcodeproj/project.pbxproj")
    info = read("SlateSyncApp/Info.plist")
    require("SWIFT_VERSION = 6.0;" in project, "Swift 6 setting missing")
    require(project.count("MACOSX_DEPLOYMENT_TARGET = 15.0;") >= 2, "macOS 15 setting missing")
    require("ENABLE_HARDENED_RUNTIME = YES;" in project, "Release hardened runtime missing")
    require("ENABLE_HARDENED_RUNTIME = NO;" in project, "Debug runtime boundary missing")
    require("ONLY_ACTIVE_ARCH = NO;" in project, "Release Universal setting missing")
    require("SlateSyncApp/Resources/PaddleOCR" in project, "canonical PaddleOCR folder missing")
    require("scripts/paddleocr_runner.py" not in project, "legacy PaddleOCR resource remains")
    require("$(MARKETING_VERSION)" in info, "short version is not injected")
    require("$(CURRENT_PROJECT_VERSION)" in info, "build version is not injected")
    with (ROOT / "SlateSyncApp/SlateSync.entitlements").open("rb") as handle:
        require(plistlib.load(handle) == {}, "Release entitlement baseline must remain empty")


def validate_workflows(ci: str, release: str) -> None:
    validate_yaml_shape(ci, "ci.yml")
    validate_yaml_shape(release, "release.yml")
    combined = ci + "\n" + release
    require(combined.count("runs-on: macos-26") == 2, "runner image drift")
    require(
        combined.count("DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer") == 2,
        "Xcode selection drift",
    )
    require(combined.count("timeout-minutes: 30") == 2, "CARRY-02 timeout drift")
    forbidden = re.compile(
        r"actions/setup-node|\bnpm\b|\bnpx\b|\bnode\b|electron-builder|\bgh\s+release\b|"
        r"CSC_LINK|APPLE_APP_SPECIFIC_PASSWORD|notarytool",
        re.IGNORECASE,
    )
    require(forbidden.search(combined) is None, "Node/Electron/distribution action remains in native workflows")
    for required in (
        "xcodebuild -version",
        "swift --version",
        "./script/phase_gate.sh SM-09",
    ):
        require(required in ci, f"CI native command missing: {required}")
    require("./script/phase_gate.sh SM-09" in release, "release native Gate missing")
    require("workflow_dispatch:" in release, "release must use protected explicit dispatch")
    require("contents: read" in release, "release permissions are not read-only")
    require("actions/upload-artifact@v4" in release, "release candidate upload missing")
    require("Developer ID" in release and "no Developer ID secret" in release, "ad-hoc limitation is not explicit")


def validate_gate_package_retention(source: str) -> None:
    """Keep the package wrapper fail-closed after its external staging step."""

    require(
        re.search(r"\blocal[^\n]*\bstatus\b", source) is None,
        "zsh read-only status variable used by Gate",
    )
    require(
        "sm09_package_artifacts_check && sm09_package_artifacts_evidence_check" in source,
        "package evidence postcondition is not mandatory",
    )
    for name in (
        "SlateSync-1.0.0-macOS-universal.zip",
        "SlateSync-1.0.0-macOS-universal.dmg",
        "SHA256SUMS",
        "SlateSync-1.0.0-manifest.json",
        "SlateSync-1.0.0-release-notes.md",
    ):
        require(name in source, f"retained package evidence is not checked: {name}")


def run_contract() -> None:
    manifest = json.loads(read(".codex/swift-migration/manifests/sm09-native-resources.json"))
    validate_resources(manifest)
    validate_xcode()
    validate_workflows(read(".github/workflows/ci.yml"), read(".github/workflows/release.yml"))
    validate_gate_package_retention(read("script/phase_gate.sh"))
    for script in ("archive_release.sh", "package_release.sh", "verify_bundle.sh"):
        mode = (ROOT / "script" / script).stat().st_mode
        require(mode & stat.S_IXUSR != 0, f"script is not executable: {script}")


def run_self_tests() -> None:
    ci = read(".github/workflows/ci.yml")
    release = read(".github/workflows/release.yml")
    cases = 0

    for mutated, expected in (
        (ci.replace("./script/phase_gate.sh SM-09", "true"), "missing native Gate"),
        (ci + "\n# npm ci\n", "Node token"),
        (ci.replace("runs-on: macos-26", "runs-on: ubuntu-latest"), "runner drift"),
        (ci.replace("    runs-on:", "   runs-on:"), "bad indentation"),
    ):
        try:
            validate_workflows(mutated, release)
        except AssertionError:
            cases += 1
        else:
            raise AssertionError(f"negative fixture unexpectedly passed: {expected}")

    manifest = json.loads(read(".codex/swift-migration/manifests/sm09-native-resources.json"))
    manifest["resources"][0]["sha256"] = "0" * 64
    try:
        validate_resources(manifest)
    except AssertionError:
        cases += 1
    else:
        raise AssertionError("resource hash negative fixture unexpectedly passed")

    gate = read("script/phase_gate.sh")
    for mutated, expected in (
        (
            gate.replace(
                "sm09_package_artifacts_check && sm09_package_artifacts_evidence_check",
                "sm09_package_artifacts_check",
            ),
            "missing package evidence postcondition",
        ),
        (gate.replace("package_status=0", "status=0"), "zsh read-only status variable"),
    ):
        try:
            validate_gate_package_retention(mutated)
        except AssertionError:
            cases += 1
        else:
            raise AssertionError(f"negative fixture unexpectedly passed: {expected}")
    print(f"SM-09 release contract self-tests: {cases} passed, 0 failed")


if __name__ == "__main__":
    run_contract()
    run_self_tests()
    print("SM-09 native release contract: PASS")
