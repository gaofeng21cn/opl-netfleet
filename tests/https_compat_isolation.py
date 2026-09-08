"""Execute the production isolation launcher in a disposable OpenWrt guest."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, "/usr/libexec/opl-netfleet-compat")
import isolation
import control


class Isolation(unittest.TestCase):
    def test_gateway_session_deadline_and_recovery_with_cpu_budget(self):
        if not Path('/tmp/netfleet-compat-vm-authorized').exists():
            self.skipTest('disposable VM required')
        program = r'''
import os, signal, sys, time
sys.path.insert(0, '/usr/libexec/opl-netfleet-compat')
import gateway, isolation
isolation.constrain_manager()
gateway.start_worker()
worker = gateway._worker.pid
assert gateway.status()['intercepting'] is False
assert gateway.status()['intercepting'] is False
assert gateway._worker.pid == worker
os.kill(worker, signal.SIGSTOP)
started = time.monotonic()
try:
    gateway.status()
    raise AssertionError('stalled service was accepted')
except ValueError as error:
    assert str(error) == 'lease_service_timeout'
assert time.monotonic() - started < 4
gateway.start_worker()
assert gateway._worker.pid != worker
assert gateway.status()['intercepting'] is False
gateway.stop_worker()
'''
        child = subprocess.run([sys.executable, '-c', program], capture_output=True, text=True, timeout=35)
        self.assertEqual(child.returncode, 0, child.stderr)

    def test_probe_releases_network_lock_and_rejects_stale_results(self):
        from unittest.mock import patch
        import tempfile
        import fcntl
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = {name: root / name for name in ("CONFIG", "TRUST", "STATE", "EFFECTIVE")}
            for path in paths.values():
                path.write_text("{}")
            with patch.multiple(control, **paths, CA=root), patch.object(control, "snapshot", return_value={"core_pid": 123}):
                with (root / "network.lock").open("w") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    def probe():
                        with (root / "network.lock").open("a") as concurrent:
                            fcntl.flock(concurrent, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        return "observed"
                    self.assertEqual(control.probe_without_network_lock(lock, probe), "observed")
                    def changed_probe():
                        probe()
                        paths["CONFIG"].write_text('{"enabled":false}')
                    with self.assertRaisesRegex(ValueError, "compatibility_probe_stale"):
                        control.probe_without_network_lock(lock, changed_probe)

    def test_restricted_process_and_resource_failure(self):
        if not Path("/tmp/netfleet-compat-vm-authorized").exists():
            self.skipTest("disposable VM required")
        private = Path("/tmp/netfleet-isolation-private")
        private.write_text("private fixture")
        private.chmod(0o600)
        self.addCleanup(private.unlink)
        program = r'''
import json, os, resource, subprocess, sys
from pathlib import Path
sys.path.insert(0, "/usr/libexec/opl-netfleet-compat")
import isolation
isolation.constrain()
try:
    Path("/tmp/netfleet-isolation-private").read_bytes()
    raise AssertionError("private input accessible")
except PermissionError:
    pass
assert os.getuid() == isolation.account()[0] != 0
assert "NoNewPrivs:\t1" in Path("/proc/self/status").read_text()
assert "CapEff:\t0000000000000000" in Path("/proc/self/status").read_text()
assert resource.getrlimit(resource.RLIMIT_NOFILE) == (512, 512)
assert isolation.status()["enforced"]
result = subprocess.run(["nft", "list", "ruleset"], capture_output=True)
assert result.returncode != 0
print(json.dumps({"uid": os.getuid(), "limits": isolation.status()}))
'''
        child = subprocess.run([sys.executable, "-c", program], capture_output=True, text=True, timeout=10)
        self.assertEqual(child.returncode, 0, child.stderr)
        self.assertTrue(json.loads(child.stdout)["limits"]["enforced"])
        # Exceed the real group memory limit, not a mocked setrlimit call.
        pressure = program[:program.index('try:')] + "\nblocks=[]\nwhile True: blocks.append(bytearray(8*1024*1024))\n"
        before = (isolation.CGROUP / "memory.events").read_text()
        child = subprocess.run([sys.executable, "-c", pressure], capture_output=True, timeout=15)
        self.assertNotEqual(child.returncode, 0)
        after = (isolation.CGROUP / "memory.events").read_text()
        counts = lambda text: dict(zip(text.split()[::2], map(int, text.split()[1::2])))
        self.assertGreater(counts(after)["oom_kill"], counts(before)["oom_kill"])
        self.assertEqual(subprocess.run(["ubus", "call", "system", "board"], capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
