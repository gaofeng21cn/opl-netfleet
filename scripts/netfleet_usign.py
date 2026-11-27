#!/usr/bin/env python3
"""Deterministic OpenWrt Ed25519 usign key/signature helpers (pure-Python RFC 8032)."""

from __future__ import annotations

import argparse
import base64
import hashlib
import os
from pathlib import Path
import sys
import tempfile


ED25519_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")
ED25519_PKCS8_PREFIX = bytes.fromhex("302e020100300506032b657004220420")
ED25519_PKCS8_V2_PREFIX = bytes.fromhex("3053020101300506032b657004220420")

_P = 2**255 - 19
_L = 2**252 + 27742317777372353535851937790883648493
_D = (-121665 * pow(121666, _P - 2, _P)) % _P
_I = pow(2, (_P - 1) // 4, _P)
_BX = 15112221349535400772501151409588531511454012693041857206046113283949847762202
_BY = (4 * pow(5, _P - 2, _P)) % _P
_BASE_POINT = (_BX, _BY, 1, (_BX * _BY) % _P)
_IDENTITY_POINT = (0, 1, 1, 0)


def _point_add(
    p1: tuple[int, int, int, int],
    p2: tuple[int, int, int, int],
) -> tuple[int, int, int, int]:
    x1, y1, z1, t1 = p1
    x2, y2, z2, t2 = p2
    a = ((y1 - x1) * (y2 - x2)) % _P
    b = ((y1 + x1) * (y2 + x2)) % _P
    c = (t1 * 2 * _D * t2) % _P
    d = (z1 * 2 * z2) % _P
    e = (b - a) % _P
    f = (d - c) % _P
    g = (d + c) % _P
    h = (b + a) % _P
    return ((e * f) % _P, (g * h) % _P, (f * g) % _P, (e * h) % _P)


def _point_mul(scalar: int, pt: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    acc = _IDENTITY_POINT
    cur = pt
    while scalar > 0:
        if scalar & 1:
            acc = _point_add(acc, cur)
        cur = _point_add(cur, cur)
        scalar >>= 1
    return acc


def _point_equal(p1: tuple[int, int, int, int], p2: tuple[int, int, int, int]) -> bool:
    x1, y1, z1, _ = p1
    x2, y2, z2, _ = p2
    return (x1 * z2 - x2 * z1) % _P == 0 and (y1 * z2 - y2 * z1) % _P == 0


def _point_encode(pt: tuple[int, int, int, int]) -> bytes:
    x, y, z, _ = pt
    zinv = pow(z, _P - 2, _P)
    x = (x * zinv) % _P
    y = (y * zinv) % _P
    encoded = bytearray(y.to_bytes(32, "little"))
    if x & 1:
        encoded[31] |= 0x80
    return bytes(encoded)


def _point_decode(raw: bytes) -> tuple[int, int, int, int] | None:
    if len(raw) != 32:
        return None
    buf = bytearray(raw)
    sign = (buf[31] >> 7) & 1
    buf[31] &= 0x7F
    y = int.from_bytes(buf, "little")
    if y >= _P:
        return None
    y2 = (y * y) % _P
    u = (y2 - 1) % _P
    v = (_D * y2 + 1) % _P
    v3 = pow(v, 3, _P)
    v7 = (v3 * v3 % _P * v) % _P
    x = (u * v3 % _P * pow((u * v7) % _P, (_P - 5) // 8, _P)) % _P
    vx2 = (v * x * x) % _P
    if vx2 != u:
        if vx2 != (-u) % _P:
            return None
        x = (x * _I) % _P
    if x == 0 and sign:
        return None
    if (x & 1) != sign:
        x = _P - x
    return (x, y, 1, (x * y) % _P)


def _secret_expand(seed: bytes) -> tuple[int, bytes]:
    if len(seed) != 32:
        raise ValueError("Ed25519 seed must be 32 bytes")
    digest = hashlib.sha512(seed).digest()
    scalar_bytes = bytearray(digest[:32])
    scalar_bytes[0] &= 248
    scalar_bytes[31] &= 127
    scalar_bytes[31] |= 64
    return int.from_bytes(scalar_bytes, "little"), digest[32:]


def ed25519_public_key(seed: bytes) -> bytes:
    """Derive the 32-byte Ed25519 public key from a 32-byte seed (RFC 8032)."""
    scalar, _ = _secret_expand(seed)
    return _point_encode(_point_mul(scalar, _BASE_POINT))


def ed25519_sign(seed: bytes, message: bytes) -> bytes:
    """Compute a 64-byte RFC 8032 Ed25519 signature."""
    scalar, prefix = _secret_expand(seed)
    pub = _point_encode(_point_mul(scalar, _BASE_POINT))
    r = int.from_bytes(hashlib.sha512(prefix + message).digest(), "little") % _L
    r_bytes = _point_encode(_point_mul(r, _BASE_POINT))
    k = int.from_bytes(hashlib.sha512(r_bytes + pub + message).digest(), "little") % _L
    s = (r + k * scalar) % _L
    return r_bytes + s.to_bytes(32, "little")


def ed25519_verify(pub: bytes, message: bytes, sig: bytes) -> bool:
    """Verify a 64-byte RFC 8032 Ed25519 signature."""
    if len(pub) != 32 or len(sig) != 64:
        return False
    a_pt = _point_decode(pub)
    r_pt = _point_decode(sig[:32])
    s = int.from_bytes(sig[32:], "little")
    if a_pt is None or r_pt is None or not (0 <= s < _L):
        return False
    k = int.from_bytes(hashlib.sha512(sig[:32] + pub + message).digest(), "little") % _L
    lhs = _point_mul(s, _BASE_POINT)
    rhs = _point_add(r_pt, _point_mul(k, a_pt))
    return _point_equal(lhs, rhs)


def _read_private_seed(pem_path: Path) -> bytes:
    lines = Path(pem_path).read_text(encoding="utf-8").splitlines()
    body: list[str] = []
    in_key = False
    for line in lines:
        stripped = line.strip()
        if stripped == "-----BEGIN PRIVATE KEY-----":
            in_key = True
            continue
        if stripped == "-----END PRIVATE KEY-----":
            break
        if in_key and stripped:
            body.append(stripped)
    if not body:
        raise ValueError(f"missing PKCS#8 PRIVATE KEY block in {pem_path}")
    der = base64.b64decode("".join(body), validate=True)
    if len(der) == len(ED25519_PKCS8_PREFIX) + 32 and der.startswith(ED25519_PKCS8_PREFIX):
        return der[len(ED25519_PKCS8_PREFIX) :]
    if len(der) >= len(ED25519_PKCS8_V2_PREFIX) + 32 and der.startswith(ED25519_PKCS8_V2_PREFIX):
        start = len(ED25519_PKCS8_V2_PREFIX)
        return der[start : start + 32]
    raise ValueError("private key is not a standard PKCS#8 Ed25519 key")


def generate_private_key(pem_path: Path) -> Path:
    """Create a 0600 Ed25519 PKCS#8 private key PEM file if missing."""
    pem_path = Path(pem_path)
    pem_path.parent.mkdir(parents=True, exist_ok=True)
    if pem_path.exists():
        return pem_path
    seed = os.urandom(32)
    b64 = base64.b64encode(ED25519_PKCS8_PREFIX + seed).decode("ascii")
    pem_text = "-----BEGIN PRIVATE KEY-----\n" + "\n".join(b64[i : i + 64] for i in range(0, len(b64), 64)) + "\n-----END PRIVATE KEY-----\n"
    with tempfile.NamedTemporaryFile(dir=pem_path.parent, prefix=".ed25519-", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        tmp_path.chmod(0o600)
        tmp_path.write_text(pem_text, encoding="utf-8")
        tmp_path.chmod(0o600)
        tmp_path.replace(pem_path)
    finally:
        tmp_path.unlink(missing_ok=True)
    return pem_path


def raw_public_key_from_private(pem_path: Path) -> bytes:
    """Extract the 32-byte raw Ed25519 public key from a private PEM."""
    return ed25519_public_key(_read_private_seed(Path(pem_path)))


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
    seed = _read_private_seed(pem_path)
    raw_pub = ed25519_public_key(seed)
    keynum = key_fingerprint(raw_pub)
    keyid = keynum.hex()
    raw_sig = ed25519_sign(seed, message_path.read_bytes())
    label = comment or f"signed by opl-netfleet {keyid}"
    payload = base64.b64encode(b"Ed" + keynum + raw_sig).decode("ascii")
    sig_path.parent.mkdir(parents=True, exist_ok=True)
    sig_path.write_text(f"untrusted comment: {label}\n{payload}\n", encoding="utf-8")
    sig_path.chmod(0o644)
    return sig_path


def verify_file(pub_path: Path, message_path: Path, sig_path: Path) -> bool:
    """Verify an OpenWrt usign signature against message_path."""
    try:
        pub_keynum, raw_pub = parse_usign_blob(Path(pub_path).read_text(encoding="utf-8"), 42)
        sig_keynum, raw_sig = parse_usign_blob(Path(sig_path).read_text(encoding="utf-8"), 74)
        message = Path(message_path).read_bytes()
    except (OSError, ValueError):
        return False
    if pub_keynum != sig_keynum:
        return False
    return ed25519_verify(raw_pub, message, raw_sig)


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
