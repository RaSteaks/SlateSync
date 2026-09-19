#!/usr/bin/env python3
"""Create/reuse a machine-local code-signing identity; never store private keys in Git."""
import argparse
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "Configuration/LocalSigning.xcconfig"
NAME = "SlateSync Local Development"


def run(args):
    # Avoid echoing arguments: PKCS#12 import includes a one-use random password.
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{Path(args[0]).name} failed: {result.stderr.strip()}")
    return result.stdout


def identities():
    output = run(["security", "find-identity", "-v", "-p", "codesigning"])
    return {fingerprint: name for fingerprint, name in re.findall(r'([A-Fa-f0-9]{40}) "([^"]+)"', output)}


def configured():
    if not CONFIG.exists():
        raise RuntimeError("本地签名尚未配置，请先运行 python3 script/setup_local_signing.py")
    match = re.search(r'^CODE_SIGN_IDENTITY\s*=\s*([A-Fa-f0-9]{40})\s*$', CONFIG.read_text(), re.M)
    if not match:
        raise RuntimeError("本地签名配置无效；禁止回退到临时签名")
    fingerprint = match[1].upper()
    if fingerprint not in identities():
        raise RuntimeError("本地签名证书或私钥不可用，请恢复原证书；禁止生成替代身份或回退到临时签名")
    return fingerprint


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--verify-app", type=Path)
    args = parser.parse_args()
    if args.check or args.verify_app or CONFIG.exists():
        fingerprint = configured()
    else:
        matches = [fp for fp, name in identities().items() if name == NAME]
        if len(matches) > 1:
            raise RuntimeError("存在多个同名签名身份，请先明确要复用的证书")
        if matches:
            fingerprint = matches[0]
        else:
            found = subprocess.run(["security", "find-certificate", "-c", NAME], capture_output=True)
            if found.returncode == 0:
                raise RuntimeError("存在同名证书但私钥不可用，请恢复身份，不要重新生成证书")
            # Restrictive temporary directory is outside the repository. Only
            # the login keychain retains the private key after setup completes.
            with tempfile.TemporaryDirectory(prefix="slatesync-signing-") as directory:
                tmp = Path(directory)
                os.chmod(tmp, 0o700)
                password = secrets.token_urlsafe(32)
                password_file = tmp / "password"
                password_file.write_text(password)
                os.chmod(password_file, 0o600)
                openssl_config = tmp / "openssl.cnf"
                openssl_config.write_text("""[req]
prompt = no
distinguished_name = subject
x509_extensions = signing
[subject]
CN = SlateSync Local Development
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
                key, cert, bundle = tmp / "key.pem", tmp / "cert.pem", tmp / "identity.p12"
                run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "3650", "-config", str(openssl_config), "-keyout", str(key), "-out", str(cert)])
                os.chmod(key, 0o600)
                run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(cert), "-name", NAME, "-out", str(bundle), "-passout", "file:" + str(password_file)])
                login = Path.home() / "Library/Keychains/login.keychain-db"
                run(["security", "import", str(bundle), "-k", str(login), "-P", password, "-T", "/usr/bin/codesign"])
                # Trust is user-local and limited to code signing, not TLS or
                # a system-wide trust-store change. No blanket private-key ACL.
                run(["security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", str(login), str(cert)])
                output = run(["/usr/bin/openssl", "x509", "-in", str(cert), "-noout", "-fingerprint", "-sha1"])
                fingerprint = output.strip().split("=")[-1].replace(":", "").upper()
            if fingerprint not in identities():
                raise RuntimeError("证书已导入但尚不可用于签名，请检查登录钥匙串解锁和代码签名信任")
        CONFIG.parent.mkdir(parents=True, exist_ok=True)
        CONFIG.write_text("// Machine-local certificate fingerprint; contains no private key.\nCODE_SIGN_IDENTITY = " + fingerprint + "\n")
        os.chmod(CONFIG, 0o600)
    if args.verify_app:
        run(["codesign", "--verify", "--strict", str(args.verify_app)])
        with tempfile.TemporaryDirectory(prefix="slatesync-signature-") as directory:
            prefix = str(Path(directory) / "certificate")
            run(["codesign", "-d", "--extract-certificates=" + prefix, str(args.verify_app)])
            output = run(["/usr/bin/openssl", "x509", "-inform", "DER", "-in", prefix + "0", "-noout", "-fingerprint", "-sha1"])
            actual = output.strip().split("=")[-1].replace(":", "").upper()
            if actual != fingerprint:
                raise RuntimeError("App 的实际签名证书与本地配置不一致")
    print("本地稳定签名已验证")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        raise SystemExit(str(error))
