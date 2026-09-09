"""Read address evidence through the registered plugin without sharing private files."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

OWNER = "/usr/libexec/opl-netfleet/main.uc"
RUN = Path("/var/run/opl-netfleet-compat")
_workers = []


def request(action, background=False):
    RUN.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, path = tempfile.mkstemp(prefix="identity-", suffix=".json", dir=RUN)
    with os.fdopen(fd, "w") as stream:
        json.dump({"request": {"id": "device-identity", "action": action, "params": {}}}, stream)
    try:
        if background:
            # The existing tick supplies scheduling; the worker has no polling loop.
            worker = subprocess.Popen(["sh", "-c", 'timeout 7 ucode "$1" plugin-read "$2" >/dev/null 2>&1; rm -f "$2"',
                                       "identity-sync", OWNER, path], stdin=subprocess.DEVNULL,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            _workers.append(worker)
            return
        # Include the host's package checks and process startup on router hardware.
        result = subprocess.run(["ucode", OWNER, "plugin-read", path], capture_output=True, timeout=3)
        value = json.loads(result.stdout)
        if not value.get("ok"):
            return {"source_ready": False, "reason": "identity_source_unavailable", "devices": []}
        return value["result"]
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        return {"source_ready": False, "reason": "identity_source_unavailable", "devices": []}
    finally:
        if not background:
            Path(path).unlink(missing_ok=True)


def resolve(config, previous=None, schedule=False):
    if not any(device.get("identity") for device in config["devices"]):
        return {}, previous or {}
    now = time.monotonic()
    progress = dict(previous or {})
    if schedule and not 0 <= now - progress.get("last_sync", -30) < 30:
        request("sync", background=True)
        progress["last_sync"] = now
    return request("resolve"), progress


def addresses(device, source):
    identity = device.get("identity")
    if not identity:
        return device["addresses"]
    if not source.get("source_ready") or source.get("binding") != identity["binding"]:
        return []
    rows = [row for row in source.get("devices", []) if row.get("mac") == identity["mac"]]
    return rows[0].get("addresses", []) if len(rows) == 1 and rows[0].get("expires_in", 0) > 0 else []


def trust_matches(device, trust):
    if device.get("identity"):
        return trust.get("identity") == device["identity"]
    return not trust.get("identity") and trust.get("addresses") == device["addresses"]
