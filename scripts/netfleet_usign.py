#!/usr/bin/env python3
"""Deterministic OpenWrt Ed25519 usign key/signature helpers backed by OpenSSL."""

from __future__ import annotations

import argparse
import base64
import functools
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ED25519_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")


@functools.lru_cache(maxsize=1)
def resolve_openssl() -> str:
    """Prefer OpenSSL 3 (supports Ed25519 `-rawin`) over macOS Apple LibreSSL."""
    candidates: list[str] = []
    for item in (
        os.environ.get("NETFLEET_OPENSSL"),
        shutil.which("openssl"),
        "/opt/homebrew/opt/openssl@3/bin/openssl",
        "/usr/local/opt/openssl@3/bin/openssl",
        "/opt/homebrew/bin/openssl",
        "/usr/local/bin/openssl",
    ):
        if item and item not in candidates:
            candidates.append(item)
    for candidate in candidates:
        try:
            probe = subprocess.run([candidate, "version"], capture_output=True, text=True, check=False)
        except OSError:
            continue
        if probe.returncode == 0 and probe.stdout.strip().startswith("OpenSSL "):
            return candidate
    return shutil.which("openssl") or "openssl"


def _run_openssl(args: list[str]) -> bytes:
    proc = subprocess.run([resolve_openssl(), *args], capture_output=True)
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"openssl {' '.join(args[:2])} failed: {err}")
    return proc.stdout


def generate_private_key(pem_path: Path) -> Path:
    """Create a 0600 Ed25519 PKCS#8 private key PEM file if missing."""
    pem_path = Path(pem_path)
    pem_path.parent.mkdir(parents=True, exist_ok=True)
    if pem_path.exists():
        return pem_path
    with tempfile.NamedTemporaryFile(dir=pem_path.parent, prefix=".ed25519-", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        tmp_path.chmod(0o600)
        _run_openssl(["genpkey", "-algorithm", "ED25519", "-out", str(tmp_path)])
        tmp_path.chmod(0o600)
        tmp_path.replace(pem_path)
    finally:
        tmp_path.unlink(missing_ok=True)
    return pem_path


def raw_public_key_from_private(pem_path: Path) -> bytes:
    """Extract the 32-byte raw Ed25519 public key from a private PEM."""
    der = _run_openssl(["pkey", "-in", str(pem_path), "-pubout", "-outform", "DER"])
    if len(der) < 32 or not der[:-32].endswith(ED25519_SPKI_PREFIX[:-32]) and len(der) != len(ED25519_SPKI_PREFIX) + 32:
        # Standard Ed25519 SubjectPublicKeyInfo is 44 bytes (12-byte header + 32-byte key).
        if len(der) != len(ED25519_SPKI_PREFIX) + 32 or not der.startswith(ED25519_SPKI_PREFIX):
            raise ValueError("private key is not an Ed25519 key")
    return der[-32:]


def key_fingerprint(raw_pub: bytes) -> bytes:
    if len(raw_pub) != 32:
        raise ValueError("Ed25519 public key must be 32 bytes")
    return hashlib.sha256(raw_pub).digest()[:8]


def format_usign_pubkey(pem_path: Path, comment: str | None = None) -> tuple[str, str]:
    """Return (16-char keyid hex, 2-line usign public key text)."""
    raw_pub = raw_public_key_from_private(Path(pem_path))
    keynum = key_fingerprint(raw_pub)
    keyid = keynum.hex()
    label = comment or f"opl-netfleet Ed25519 public key {keyid}"
    payload = base64.b64encode(b"Ed" + keynum + raw_pub).decode("ascii")
    return keyid, f"untrusted comment: {label}\n{payload}\n"


def parse_usign_blob(text: str, expected_len: int) -> tuple[bytes, bytes]:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) != 2 or not lines[0].startswith("untrusted comment:"):
        raise ValueError("invalid usign file format")
    raw = base64.b64decode(lines[1], validate=True)
    if len(raw) != expected_len or raw[:2] != b"Ed":
        raise ValueError("unsupported or malformed usign Ed25519 payload")
    return raw[2:10], raw[10:]


def write_usign_pubkey(pem_path: Path, output_path: Path, comment: str | None = None) -> str:
    keyid, text = format_usign_pubkey(pem_path, comment=comment)
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(text, encoding="utf-8")
    output_path.chmod(0o644)
    return keyid


def sign_file(pem_path: Path, message_path: Path, sig_path: Path, comment: str | None = None) -> Path:
    """Sign message_path with pem_path and write an OpenWrt usign .sig file."""
    pem_path, message_path, sig_path = Path(pem_path), Path(message_path), Path(sig_path)
    raw_pub = raw_public_key_from_private(pem_path)
    keynum = key_fingerprint(raw_pub)
    keyid = keynum.hex()
    raw_sig = _run_openssl(["pkeyutl", "-sign", "-inkey", str(pem_path), "-rawin", "-in", str(message_path)])
    if len(raw_sig) != 64:
        raise ValueError("unexpected Ed25519 signature length")
    label = comment or f"signed by opl-netfleet {keyid}"
    payload = base64.b64encode(b"Ed" + keynum + raw_sig).decode("ascii")
    sig_path.parent.mkdir(parents=True, exist_ok=True)
    sig_path.write_text(f"untrusted comment: {label}\n{payload}\n", encoding="utf-8")
    sig_path.chmod(0o644)
    return sig_path


def verify_file(pub_path: Path, message_path: Path, sig_path: Path) -> bool:
    """Verify an OpenWrt usign signature against message_path using OpenSSL."""
    try:
        pub_keynum, raw_pub = parse_usign_blob(Path(pub_path).read_text(encoding="utf-8"), 42)
        sig_keynum, raw_sig = parse_usign_blob(Path(sig_path).read_text(encoding="utf-8"), 74)
    except (OSError, ValueError):
        return False
    if pub_keynum != sig_keynum:
        return False
    spki_der = ED25519_SPKI_PREFIX + raw_pub
    with tempfile.TemporaryDirectory(prefix="netfleet-usign-verify-") as tmp:
        tmp_dir = Path(tmp)
        pub_der = tmp_dir / "pub.der"
        sig_bin = tmp_dir / "sig.bin"
        pub_der.write_bytes(spki_der)
        sig_bin.write_bytes(raw_sig)
        proc = subprocess.run(
            [
                resolve_openssl(), "pkeyutl", "-verify",
                "-pubin", "-keyform", "DER", "-inkey", str(pub_der),
                "-rawin", "-in", str(message_path), "-sigfile", str(sig_bin),
            ],
            capture_output=True,
        )
        return proc.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_gen = sub.add_parser("keygen")
    p_gen.add_argument("--key", type=Path, required=True)
    p_gen.add_argument("--pub", type=Path)

    p_pub = sub.add_parser("pubkey")
    p_pub.add_argument("--key", type=Path, required=True)
    p_pub.add_argument("--out", type=Path)

    p_sign = sub.add_parser("sign")
    p_sign.add_argument("--key", type=Path, required=True)
    p_sign.add_argument("--in", dest="message", type=Path, required=True)
    p_sign.add_argument("--out", dest="sig", type=Path, required=True)

    p_verify = sub.add_parser("verify")
    p_verify.add_argument("--pub", type=Path, required=True)
    p_verify.add_argument("--in", dest="message", type=Path, required=True)
    p_verify.add_argument("--sig", type=Path, required=True)

    args = parser.parse_args()
    if args.cmd == "keygen":
        generate_private_key(args.key)
        if args.pub:
            print(write_usign_pubkey(args.key, args.pub))
        else:
            keyid, _ = format_usign_pubkey(args.key)
            print(keyid)
    elif args.cmd == "pubkey":
        if args.out:
            print(write_usign_pubkey(args.key, args.out))
        else:
            keyid, text = format_usign_pubkey(args.key)
            sys.stdout.write(text)
    elif args.cmd == "sign":
        sign_file(args.key, args.message, args.sig)
    elif args.cmd == "verify":
        if not verify_file(args.pub, args.message, args.sig):
            sys.stderr.write("usign verification failed\n")
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
