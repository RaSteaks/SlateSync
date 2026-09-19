#!/usr/bin/env python3
"""Verify persistent signing across processes using a disposable keychain only."""
from pathlib import Path
import plistlib
import secrets
import shutil
import subprocess
import tempfile
import uuid
from setup_local_signing import configured, ROOT


def run(args, timeout=60):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{Path(args[0]).name} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def main():
    identity = configured()
    with tempfile.TemporaryDirectory(prefix="slatesync-keychain-verification-") as directory:
        tmp = Path(directory)
        keychain = tmp / "isolated.keychain-db"
        password = secrets.token_urlsafe(32)
        service = "com.slatesync.regression." + str(uuid.uuid4())
        app = tmp / "KeychainProbe.app"
        binary = app / "Contents/MacOS/KeychainProbe"
        binary.parent.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.slatesync.keychain-regression",
            "CFBundleExecutable": "KeychainProbe", "CFBundlePackageType": "APPL",
        }))
        source = tmp / "probe.swift"
        source.write_text((ROOT / "script/fixtures/KeychainSigningProbe.swift").read_text())
        def build():
            run(["xcrun", "swiftc", str(source), "-framework", "LocalAuthentication", "-o", str(binary)])
            run(["codesign", "--force", "--sign", identity, str(app)])
            return subprocess.run(["codesign", "-d", "-r-", str(app)], capture_output=True, text=True, check=True).stderr
        def probe(mode, expected=0, executable=binary):
            status = int(run([str(executable), mode, str(keychain), service], timeout=10))
            if expected == "denied":
                assert status in [-25293, -25308, -128], f"Expected denial, got {status}"
            else:
                assert status == expected, f"{mode}: {status}"
        try:
            run(["security", "create-keychain", "-p", password, str(keychain)])
            run(["security", "unlock-keychain", "-p", password, str(keychain)])
            first = build()
            probe("create")
            for _ in range(3): probe("read")
            probe("status")
            # Force a different executable hash without changing its identity.
            source.write_text(source.read_text() + '\nprint("", terminator: "")\n')
            second = build()
            assert first == second, "Designated requirement changed after rebuild"
            probe("read")
            rejected = tmp / "Rejected.app"
            shutil.copytree(app, rejected)
            run(["codesign", "--force", "--sign", "-", str(rejected)])
            probe("read", "denied", rejected / "Contents/MacOS/KeychainProbe")
            # Attributes remain available without authorizing the secret reader.
            probe("status", executable=rejected / "Contents/MacOS/KeychainProbe")
            run(["security", "lock-keychain", str(keychain)])
            probe("read", "denied")
            run(["security", "unlock-keychain", "-p", password, str(keychain)])
            probe("read")
            print("PASS: three launches, rebuild identity, denied reader, metadata-only status, locked keychain, recovery")
        finally:
            # Remove only the uniquely named disposable keychain, never login.
            subprocess.run(["security", "delete-keychain", str(keychain)], capture_output=True)


if __name__ == "__main__":
    main()
