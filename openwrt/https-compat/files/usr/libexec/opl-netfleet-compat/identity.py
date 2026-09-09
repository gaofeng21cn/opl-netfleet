"""Read address evidence through the registered plugin without sharing private files."""
import atexit
import signal
import json
import os
from pathlib import Path
import subprocess
import stat
import math
import ipaddress
import tempfile
import time

OWNER = "/usr/libexec/opl-netfleet/main.uc"
RUN = Path("/var/run/opl-netfleet-compat")
_workers = []
_next_sync = 0
TRUSTED_UID = 0
EVIDENCE = Path("/var/run/opl-netfleet-device-identity/evidence.json")


def reap_sync(force=False):
    now = time.monotonic()
    for worker in list(_workers):
        if not force and worker.poll() is None and now < worker.deadline:
            continue
        # The host invokes nested shells and a plugin process. Kill the session's
        # process group even if its leader has already exited.
        if getattr(worker, "owns_session", False):
            try:
                os.killpg(worker.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        worker.wait(timeout=2)
        path = getattr(worker, "request_path", None)
        if path:
            Path(path).unlink(missing_ok=True)
        _workers.remove(worker)


atexit.register(lambda: reap_sync(force=True))


def schedule_sync():
    global _next_sync
    reap_sync()
    now = time.monotonic()
    if _workers or now < _next_sync:
        return
    # Keep the attempt clock independent of successful health-state commits.
    _next_sync = now + 30
    RUN.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, path = tempfile.mkstemp(prefix="identity-", suffix=".json", dir=RUN)
    with os.fdopen(fd, "w") as stream:
        json.dump({"request": {"id": "device-identity", "action": "sync", "params": {}}}, stream)
    try:
        worker = subprocess.Popen(["nice", "-n", "15", "ucode", OWNER, "plugin-read", path], stdin=subprocess.DEVNULL,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        worker.deadline, worker.request_path, worker.owns_session = now + 7, path, True
        _workers.append(worker)
    except OSError:
        Path(path).unlink(missing_ok=True)


def published():
    """Read the source's bounded publication without spawning host processes."""
    unavailable = {"source_ready": False, "reason": "identity_source_unavailable", "devices": []}
    try:
        parent = EVIDENCE.parent.lstat()
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != TRUSTED_UID or parent.st_mode & 0o022:
            return unavailable
        fd = os.open(EVIDENCE, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != TRUSTED_UID or info.st_mode & 0o022 or info.st_size > 65536:
                return unavailable
            value = json.loads(stream.read(65537))
        now = time.monotonic()
        age = now - value["sampled_monotonic"]
        if value["schema"] != 1 or value["source_ready"] is not True or not 0 <= age < 120:
            return unavailable
        devices = []
        if len(value["devices"]) > 256:
            return unavailable
        for row in value["devices"]:
            expires = row["address_expires"]
            addresses = []
            remaining = []
            for address, expiry in expires.items():
                if not math.isfinite(expiry) or expiry > value["sampled_monotonic"] + 120:
                    return unavailable
                if expiry > now:
                    ip = ipaddress.ip_address(address)
                    if ip.is_unspecified or ip.is_multicast or ip.is_loopback or ip.is_link_local:
                        return unavailable
                    addresses.append(str(ip))
                    remaining.append(expiry - now)
            devices.append({"mac": row["mac"], "addresses": sorted(addresses),
                            "expires_in": min(remaining, default=0)})
        return {"source_ready": True, "binding": value["binding"], "devices": devices}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return unavailable


def resolve(config, previous=None, schedule=False):
    if not any(device.get("identity") for device in config["devices"]):
        return {}, previous or {}
    now = time.monotonic()
    progress = dict(previous or {})
    if schedule:
        reap_sync()
    if schedule and not 0 <= now - progress.get("last_sync", -30) < 30:
        schedule_sync()
        progress["last_sync"] = now
    return published(), progress


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
