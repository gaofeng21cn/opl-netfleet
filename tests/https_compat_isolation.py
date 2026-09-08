"""Execute the production isolation launcher in a disposable OpenWrt guest."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, "/usr/libexec/opl-netfleet-compat")
import isolation
import control


class Isolation(unittest.TestCase):
    def test_module_recovery_counts_outages_after_readmission(self):
        from contextlib import ExitStack
        from unittest.mock import patch
        import tempfile
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            root = Path(directory)
            paths = {name: root / name for name in ('CONFIG', 'TRUST', 'STATE', 'EFFECTIVE')}
            stack.enter_context(patch.multiple(control, **paths))
            config = {**control.DEFAULT, 'enabled': True}
            paths['CONFIG'].write_text(json.dumps(config))
            paths['TRUST'].write_text('{}')
            paths['EFFECTIVE'].write_text(json.dumps(config))
            stack.enter_context(patch.object(control.device_identity, 'resolve', return_value=({}, {})))
            stack.enter_context(patch.object(control, 'probe_without_network_lock', side_effect=lambda lock, work: work()))
            stack.enter_context(patch.object(control, 'snapshot', return_value={'ready': True, 'reason': None}))
            stack.enter_context(patch.object(control, 'ca_fingerprint', return_value=None))
            stack.enter_context(patch.object(control.gateway, 'prepare'))
            stack.enter_context(patch.object(control.gateway, 'bypass'))
            execute = stack.enter_context(patch.object(control.subprocess, 'run'))
            health = stack.enter_context(patch.object(control, 'engine_health'))
            state = {'engine_pid': 123, 'recovery': {'healthy': True, 'healthy_since': 900,
                                                   'intercepting': True, 'faults': []}}
            for now, healthy, count in ((1000, False, 1), (1002, True, 1), (1004, False, 1),
                                        (1006, True, 1), (1010, False, 1), (1012, True, 1),
                                        (1042, True, 1), (1044, False, 2), (1046, True, 2),
                                        (1076, True, 2), (1078, False, 3)):
                state['last_tick'] = now
                paths['STATE'].write_text(json.dumps(state))
                health.return_value = {'ready': True, 'pid': 123, 'processing_chain': healthy,
                                       'transparent_chain': healthy,
                                       'revision': hashlib.sha256(paths['EFFECTIVE'].read_bytes()).hexdigest()}
                with patch.object(control.time, 'monotonic', return_value=now):
                    control.tick()
                state = json.loads(paths['STATE'].read_text())
                self.assertEqual(len(state['recovery']['faults']), count, (now, state))
                self.assertEqual(state['recovery']['latched'], count == 3, (now, state))
            execute.assert_not_called()

    def test_cold_start_grace_expires_and_never_masks_a_ready_engine_failure(self):
        from contextlib import ExitStack
        from unittest.mock import patch
        import tempfile
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            root = Path(directory)
            paths = {name: root / name for name in ('CONFIG', 'TRUST', 'STATE', 'EFFECTIVE')}
            stack.enter_context(patch.multiple(control, **paths))
            paths['CONFIG'].write_text(json.dumps({**control.DEFAULT, 'enabled': True}))
            paths['TRUST'].write_text('{}')
            paths['EFFECTIVE'].write_text('{}')
            stack.enter_context(patch.object(control.time, 'monotonic', return_value=1000))
            stack.enter_context(patch.object(control.device_identity, 'resolve', return_value=({}, {})))
            stack.enter_context(patch.object(control, 'probe_without_network_lock', side_effect=lambda lock, work: work()))
            stack.enter_context(patch.object(control, 'snapshot', return_value={'ready': True, 'epoch': 'fixture'}))
            stack.enter_context(patch.object(control.gateway, 'prepare'))
            bypass = stack.enter_context(patch.object(control.gateway, 'bypass'))
            execute = stack.enter_context(patch.object(control.subprocess, 'run'))
            health = stack.enter_context(patch.object(control, 'engine_health'))
            previous = {'last_tick': 999, 'unhealthy_since': 980, 'engine_pid': 123}
            for starting, ready_before in ((True, False), (False, False), (True, True)):
                with self.subTest(starting=starting, ready_before=ready_before):
                    paths['STATE'].write_text(json.dumps({**previous, **({'ready_engine_pid': 123} if ready_before else {})}))
                    health.return_value = {'ready': False, 'starting': starting, 'pid': 123}
                    execute.reset_mock()
                    control.tick()
                    state = json.loads(paths['STATE'].read_text())
                    self.assertFalse(state['intercepting'])
                    if starting and not ready_before:
                        execute.assert_not_called()
                        self.assertEqual(state['reason'], 'engine_starting')
                        self.assertEqual(state['recovery']['faults'], [])
                    else:
                        self.assertEqual(execute.call_count, 2)
                        self.assertEqual(len(state['recovery']['faults']), 1)
            self.assertEqual(bypass.call_count, 3)

    def test_gateway_session_deadline_and_recovery_with_cpu_budget(self):
        if not Path('/tmp/netfleet-compat-vm-authorized').exists():
            self.skipTest('disposable VM required')
        program = r'''
import os, signal, sys, time
from pathlib import Path
sys.path.insert(0, '/usr/libexec/opl-netfleet-compat')
import gateway, isolation
isolation.constrain_manager()
assert Path('/sys/fs/cgroup/netfleet-compat-manager/cpu.max').read_text().strip() == '50000 100000'
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
started = time.monotonic()
try:
    gateway.bypass()
    raise AssertionError('dead service fell back to synchronous startup')
except ValueError as error:
    assert str(error) == 'lease_service_unavailable'
assert time.monotonic() - started < 0.1
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
