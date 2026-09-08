"""Typed calls to the native gateway's limited interception service."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

OWNER = "/usr/libexec/opl-netfleet/main.uc"
PORT = 18443
_epoch = None


def call(action, **params):
    with tempfile.TemporaryDirectory(prefix="netfleet-lease-") as directory:
        path = Path(directory) / "request.json"
        with path.open("w") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump({"action": action, **params}, stream)
        result = subprocess.run(["ucode", OWNER, "compatibility-lease", str(path)],
                                text=True, capture_output=True, timeout=3)
    response = json.loads(result.stdout)
    if not response.get("ok"):
        raise ValueError(response.get("error", "lease_operation_failed"))
    return response["result"]


def snapshot():
    return call("snapshot")


def prepare(network):
    global _epoch
    _epoch = network["epoch"]
    return call("prepare", epoch=_epoch)


def renew(candidates):
    return call("renew", epoch=_epoch, candidates=candidates)


def bypass():
    return call("bypass")


def status():
    return call("status")


def remove():
    return call("remove")
