#!/usr/bin/env python3
"""Package and Ed25519-sign a service plugin directory into a macOS overlay."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

OVERLAY_SCHEMA = "opl-netfleet-plugin-overlay.v1"
SERVICE_PLUGIN_SCHEMA = "opl-netfleet-service-plugin.v1"
SEMVER_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
IGNORED_NAMES = {".DS_Store", "__pycache__", "overlay-signature.json"}


def sign_payload_with_node(canonical_payload: str, private_key_b64: str) -> str:
    node = shutil.which("node")
    if not node:
        raise RuntimeError("node binary is required to sign plugin overlays")
    try:
        seed = base64.b64decode(private_key_b64.strip(), validate=True)
    except Exception as exc:
        raise ValueError("Private key must be valid base64") from exc
    if len(seed) != 32:
        raise ValueError(f"Expected 32-byte raw Ed25519 private key seed, got {len(seed)} bytes")

    js = (
        "const crypto = require('node:crypto');"
        "const chunks = [];"
        "process.stdin.on('data', d => chunks.push(d));"
        "process.stdin.on('end', () => {"
        "  const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));"
        "  const seed = Buffer.from(input.seed_b64, 'base64');"
        "  const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]);"
        "  const key = crypto.createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' });"
        "  const sig = crypto.sign(null, Buffer.from(input.payload, 'utf8'), key);"
        "  process.stdout.write(sig.toString('base64'));"
        "});"
    )
    proc = subprocess.run(
        [node, "-e", js],
        input=json.dumps({"seed_b64": base64.b64encode(seed).decode("ascii"), "payload": canonical_payload}),
        capture_output=True,
        text=True,
        check=True,
    )
    return proc.stdout.strip()


def collect_plugin_files(plugin_dir: Path) -> list[tuple[str, bytes]]:
    if not plugin_dir.is_dir() or plugin_dir.is_symlink():
        raise ValueError(f"Plugin directory must be a real directory: {plugin_dir}")
    entries: list[tuple[str, bytes]] = []
    for root, dirs, files in os.walk(plugin_dir, followlinks=False):
        root_path = Path(root)
        dirs[:] = sorted(d for d in dirs if d not in IGNORED_NAMES and not d.startswith("._"))
        for dirname in dirs:
            if (root_path / dirname).is_symlink():
                raise ValueError(f"Symlink disallowed in plugin directory: {root_path / dirname}")
        for filename in sorted(files):
            if filename in IGNORED_NAMES or filename.startswith("._") or filename.endswith(".pyc"):
                continue
            full_path = root_path / filename
            if full_path.is_symlink() or not full_path.is_file():
                raise ValueError(f"Non-regular file or symlink disallowed: {full_path}")
            rel = full_path.relative_to(plugin_dir).as_posix()
            entries.append((rel, full_path.read_bytes()))
    entries.sort(key=lambda item: item[0])
    return entries


def build_signed_overlay(plugin_dir: Path, output_dir: Path, private_key_b64: str) -> dict:
    manifest_path = plugin_dir / "manifest.json"
    if not manifest_path.is_file():
        raise ValueError(f"Missing manifest.json in {plugin_dir}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    plugin_id = manifest.get("id")
    version = manifest.get("version")
    if manifest.get("schema") != SERVICE_PLUGIN_SCHEMA or not isinstance(plugin_id, str) or not plugin_id:
        raise ValueError("Invalid service plugin manifest schema or id")
    if plugin_id == "platform-macos":
        raise ValueError("platform-macos cannot be distributed as a plugin overlay")
    if not isinstance(version, str) or not SEMVER_RE.fullmatch(version):
        raise ValueError(f"Invalid semantic version in manifest: {version!r}")

    files_data = collect_plugin_files(plugin_dir)
    file_records = [
        {"path": rel, "sha256": hashlib.sha256(data).hexdigest()}
        for rel, data in files_data
    ]
    canonical = json.dumps(
        {
            "schema": OVERLAY_SCHEMA,
            "id": plugin_id,
            "version": version,
            "files": file_records,
        },
        separators=(",", ":"),
        ensure_ascii=False,
    )
    signature = sign_payload_with_node(canonical, private_key_b64)
    envelope = {
        "schema": OVERLAY_SCHEMA,
        "id": plugin_id,
        "version": version,
        "files": file_records,
        "signature": signature,
    }

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(output_dir.parent, 0o700)
    staging = Path(tempfile.mkdtemp(prefix=f".sign-{plugin_id}-", dir=output_dir.parent))
    try:
        os.chmod(staging, 0o700)
        for rel, data in files_data:
            dest = staging / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            for parent in [dest.parent, *dest.parent.parents]:
                if parent == staging:
                    break
                os.chmod(parent, 0o700)
            dest.write_bytes(data)
            os.chmod(dest, 0o600)
        sig_file = staging / "overlay-signature.json"
        sig_file.write_text(json.dumps(envelope, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        os.chmod(sig_file, 0o600)

        if output_dir.exists() or output_dir.is_symlink():
            if output_dir.is_symlink() or not output_dir.is_dir():
                output_dir.unlink()
            else:
                shutil.rmtree(output_dir)
        staging.rename(output_dir)
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    return {
        "ok": True,
        "id": plugin_id,
        "version": version,
        "output_dir": str(output_dir),
        "files": [record["path"] for record in file_records],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin-dir", type=Path, required=True, help="Source plugins/<id> directory")
    parser.add_argument("--output-dir", type=Path, required=True, help="Target signed overlay directory")
    parser.add_argument(
        "--private-key-env",
        default="SPARKLE_ED25519_PRIVATE_KEY",
        help="Environment variable holding the base64 32-byte Ed25519 private key seed",
    )
    args = parser.parse_args()
    key_b64 = os.environ.get(args.private_key_env, "").strip()
    if not key_b64:
        raise SystemExit(f"Missing signing key environment variable: {args.private_key_env}")
    result = build_signed_overlay(args.plugin_dir.resolve(), args.output_dir.resolve(), key_b64)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
