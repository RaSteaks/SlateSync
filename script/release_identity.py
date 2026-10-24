#!/usr/bin/env python3
"""Resolve the candidate's Release identity, independently of the built bundle."""

import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def release_identity(project: dict) -> dict:
    objects = project["objects"]
    targets = [objects[key] for key in objects[project["rootObject"]]["targets"]
               if objects[key].get("name") == "SlateSync"]
    if len(targets) != 1:
        raise ValueError("expected exactly one SlateSync application target")
    configurations = objects[targets[0]["buildConfigurationList"]]["buildConfigurations"]
    release = [objects[key]["buildSettings"] for key in configurations if objects[key]["name"] == "Release"]
    if len(release) != 1:
        raise ValueError("expected exactly one Release configuration")
    version = str(release[0].get("MARKETING_VERSION", ""))
    build = str(release[0].get("CURRENT_PROJECT_VERSION", ""))
    # Fail closed on unresolved substitutions rather than trusting the archive
    # to define its own expected version. Historical migration fixtures stay sealed.
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Release requires explicit semantic version and positive build number")
    return {"configuration": "Release", "version": version, "build": build}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    # plutil understands Xcode's OpenStep plist; no fragile text matching of
    # target/configuration order and no build, signing or GUI work is needed.
    raw = subprocess.check_output(["plutil", "-convert", "json", "-o", "-",
                                   str(ROOT / "SlateSync.xcodeproj/project.pbxproj")])
    identity = release_identity(json.loads(raw))
    if args.output:
        args.output.write_text(json.dumps(identity, indent=2) + "\n")
    print(identity["version"])
    print(identity["build"])


if __name__ == "__main__":
    main()
