#!/usr/bin/env python3
"""macOS enrollment over authenticated SSH; never changes application URLs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import ssl
import subprocess
import tempfile


KEYCHAIN = "/Library/Keychains/System.keychain"


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout


def remote(target, action, request=None):
    if target.startswith("-") or not target or any(char.isspace() for char in target):
        raise ValueError("invalid SSH target")
    command = ["ssh", "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", target]
    if request is None:
        output = run([*command, "ucode /usr/libexec/opl-netfleet/main.uc compatibility-" + action], timeout=20)
    else:
        output = run([*command, "umask 077; request=$(mktemp); trap 'rm -f \"$request\"' EXIT; cat >\"$request\"; ucode /usr/libexec/opl-netfleet/main.uc compatibility-" + action + ' "$request"'],
                     input=json.dumps({"request": request}), timeout=20)
    value = json.loads(output)
    if value.get("ok") is not True:
        raise ValueError(value.get("error", "remote operation failed"))
    return value["result"]


def main():
    parser = argparse.ArgumentParser(description="NetFleet macOS CA 信任接入")
    parser.add_argument("action", choices=("install", "verify", "revoke"))
    parser.add_argument("--target", required=True, help="已验证 SSH 主机")
    parser.add_argument("--device", required=True, help="NetFleet 设备 ID")
    args = parser.parse_args()
    if os.uname().sysname != "Darwin":
        raise ValueError("requires macOS")
    status = remote(args.target, "get")
    if args.device not in {item["id"] for item in status["config"]["devices"]}:
        raise ValueError("请先在 HTTPS 兼容页添加设备")
    ca = remote(args.target, "ca")
    der = ssl.PEM_cert_to_DER_cert(ca["pem"])
    fingerprint = hashlib.sha256(der).hexdigest()
    if fingerprint != ca["sha256"] or fingerprint != status["ca_sha256"]:
        raise ValueError("CA fingerprint mismatch")
    with tempfile.TemporaryDirectory(prefix="netfleet-trust-") as directory:
        path = Path(directory) / "ca.pem"
        path.write_text(ca["pem"])
        if args.action == "revoke":
            status = remote(args.target, "probe", {"revision": status["revision"], "operation": "trust_revoke", "device": args.device})
            # Removing trust during an established request can break its next TLS connection.
            if status.get("active_connections") != 0:
                raise ValueError("接管已撤销；现有连接尚未排空，请稍后再次撤销本机信任")
            subprocess.run(["sudo", "security", "delete-certificate", "-Z", fingerprint, KEYCHAIN], check=True)
            print(json.dumps({"revoked": True, "ca_sha256": fingerprint}))
            return
        if args.action == "install":
            subprocess.run(["sudo", "security", "add-trusted-cert", "-d", "-r", "trustRoot", "-k", KEYCHAIN, str(path)], check=True)
        run(["security", "verify-cert", "-c", str(path), "-p", "ssl"], timeout=10)
        report = {"system": True, "ca_sha256": fingerprint, "codex_app": None, "codex_cli": None, "images": None}
        remote(args.target, "probe", {"revision": status["revision"], "operation": "trust_record", "device": args.device, "report": report})
        print(json.dumps({"device": args.device, "verification": report}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
