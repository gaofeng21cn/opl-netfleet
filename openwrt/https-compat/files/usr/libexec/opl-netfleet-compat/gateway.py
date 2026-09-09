"""Typed calls to the native gateway's limited interception service."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import atexit
import selectors
import signal
import time

OWNER = "/usr/libexec/opl-netfleet/main.uc"
PORT = 18443
_epoch = None
_worker = None
_watching = False


def stop_worker():
    global _worker
    worker, _worker = _worker, None
    if worker is None:
        return
    try:
        os.killpg(worker.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    worker.wait(timeout=2)
    worker.stdin.close()
    worker.stdout.close()


def worker_response(timeout, request=b''):
    deadline = time.monotonic() + timeout
    received = bytearray()
    with selectors.DefaultSelector() as selector:
        selector.register(_worker.stdout, selectors.EVENT_READ)
        if request:
            selector.register(_worker.stdin, selectors.EVENT_WRITE)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError('lease_service_timeout')
            events = selector.select(remaining)
            if not events:
                raise ValueError('lease_service_timeout')
            for key, mask in events:
                if mask & selectors.EVENT_WRITE:
                    count = os.write(key.fd, request)
                    request = request[count:]
                    if not request:
                        selector.unregister(_worker.stdin)
                if mask & selectors.EVENT_READ:
                    part = os.read(key.fd, 65536)
                    if not part:
                        raise ValueError('lease_service_unavailable')
                    received.extend(part)
                    if len(received) > 262144:
                        raise ValueError('lease_response_too_large')
                    if b'\n' in received:
                        return json.loads(received)


def start_worker():
    global _worker, _watching
    _watching = True
    if _worker is not None and _worker.poll() is None:
        return
    stop_worker()
    _worker = subprocess.Popen(['ucode', OWNER, 'compatibility-lease-watch'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        start_new_session=True, bufsize=0)
    os.set_blocking(_worker.stdin.fileno(), False)
    os.set_blocking(_worker.stdout.fileno(), False)
    try:
        if worker_response(10) != {'ready': True}:
            raise ValueError('lease_service_unavailable')
    except (OSError, ValueError, subprocess.SubprocessError):
        stop_worker()
        raise


atexit.register(stop_worker)


def call(action, **params):
    if _watching and _worker is None:
        raise ValueError('lease_service_unavailable')
    if _worker is not None:
        try:
            data = json.dumps({'action': action, **params}).encode() + b'\n'
            if len(data) > 262144:
                raise ValueError('lease_request_invalid')
            response = worker_response(3, data)
        except (OSError, ValueError, subprocess.SubprocessError):
            stop_worker()
            raise
        if not response.get('ok'):
            raise ValueError(response.get('error', 'lease_operation_failed'))
        return response['result']
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
    if _epoch == network['epoch']:
        return None
    result = call('prepare', epoch=network['epoch'])
    _epoch = network['epoch']
    return result


def renew(candidates):
    return call("renew", epoch=_epoch, candidates=candidates)


def bypass():
    return call("bypass")


def status():
    return call("status")


def remove():
    return call("remove")
