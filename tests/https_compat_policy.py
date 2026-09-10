import sys
from pathlib import Path
import unittest
import copy
import hashlib
import json
import tempfile
import os
import subprocess
from unittest.mock import patch, AsyncMock
from contextlib import ExitStack
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "openwrt/https-compat/files/usr/libexec/opl-netfleet-compat"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests/reference/https-gateway"))
from recovery import ENGINE_RESTART_GRACE_SECONDS, LEASE_SECONDS, advance
from policy import select, validate
from routing import admission, egress_policy
import control


class Decisions(unittest.TestCase):
    def test_interactive_lock_waits_for_owner_without_stealing_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'mutation.lock'
            holder = subprocess.Popen([sys.executable, '-c', """import fcntl, sys, time
with open(sys.argv[1], 'a') as file:
    fcntl.flock(file, fcntl.LOCK_EX)
    print('locked', flush=True)
    sys.stdin.read(1)
    time.sleep(0.15)
""", str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(holder.stdout.readline().strip(), 'locked')
                with patch.object(control, 'MUTATION_LOCK', path):
                    with self.assertRaisesRegex(ValueError, 'mutation_busy'):
                        with control.mutation_lock(wait_seconds=0.05):
                            self.fail('must not acquire a lock owned by another process')
                    holder.stdin.write('\n'); holder.stdin.flush()
                    with control.mutation_lock(wait_seconds=1):
                        holder.wait(timeout=3)
            finally:
                holder.communicate(timeout=3)

    def test_engine_restart_threshold_is_shorter_than_lease(self):
        self.assertLess(ENGINE_RESTART_GRACE_SECONDS, LEASE_SECONDS)

    @unittest.skipUnless(sys.platform == "linux" and os.geteuid() == 0, "requires Linux root fdinfo")
    def test_only_actual_ancestor_lock_can_be_inherited(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mutation.lock"
            code = """import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import control
control.MUTATION_LOCK = Path(sys.argv[2])
with control.mutation_lock(): print('acquired')
"""
            child = [sys.executable, "-c", code, str(Path(control.__file__).parent), str(path)]
            with patch.object(control, "MUTATION_LOCK", path), control.mutation_lock():
                result = subprocess.run(child, capture_output=True, text=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "acquired")
            holder = subprocess.Popen([sys.executable, "-c", """import fcntl, sys
with open(sys.argv[1], 'a') as file:
    fcntl.flock(file, fcntl.LOCK_EX)
    print('locked', flush=True)
    sys.stdin.read(1)
""", str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(holder.stdout.readline().strip(), "locked")
                result = subprocess.run(child, capture_output=True, text=True, timeout=3)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("mutation_busy", result.stderr)
            finally:
                holder.communicate("\n", timeout=3)

    def test_health_revalidates_on_pid_revision_age_and_failure(self):
        value = {'service': 'netfleet-https-compat', 'ready': True, 'pid': 123, 'revision': 'a' * 64}
        with patch.object(control.haproxy, 'health', return_value=value) as health, \
             patch.object(control.haproxy, 'probe', return_value={'ok': True}) as full, \
             patch.object(control.subprocess, 'run') as probe, patch.object(control.isolation, 'account', return_value=(1000, 1000)), \
             patch.object(control, '_verified_engine', None), patch.object(control.time, 'monotonic') as now:
            probe.return_value.stdout = '{"ok":true}'
            for timestamp in (100, 102, 104):
                now.return_value = timestamp
                self.assertTrue(control.engine_health(probe=True)['transparent_chain'])
            self.assertEqual(sum(len(call.args) == 1 for call in full.call_args_list), 1)
            now.return_value = 160
            self.assertTrue(control.engine_health(probe=True)['transparent_chain'])
            self.assertEqual(sum(len(call.args) == 1 for call in full.call_args_list), 2)
            value['pid'] = 124
            self.assertTrue(control.engine_health(probe=True)['transparent_chain'])
            self.assertEqual(sum(len(call.args) == 1 for call in full.call_args_list), 3)
            health.side_effect = TimeoutError()
            self.assertFalse(control.engine_health(probe=True)['ready'])
            self.assertIsNone(control._verified_engine)

    def test_recovery_window_disable_and_manual_reset(self):
        state = None
        now = 0
        for attempt in range(3):
            state = advance(state, requested=True, healthy=True, reason=None, now=now)
            self.assertFalse(state["intercepting"])
            state = advance(state, requested=True, healthy=True, reason=None, now=now + 30)
            self.assertTrue(state["intercepting"])
            state = advance(state, requested=True, healthy=False, reason="failure", now=now + 31)
            self.assertFalse(state["intercepting"])
            now += 60
        self.assertTrue(state["latched"])
        for timestamp in (181, 220, 800):
            state = advance(state, requested=True, healthy=True, reason=None, now=timestamp)
            self.assertFalse(state["intercepting"])
        state = advance(state, requested=False, healthy=True, reason=None, now=801)
        self.assertFalse(state["intercepting"])
        state = advance(state, requested=True, healthy=True, reason=None, now=802, manual_reset=True)
        self.assertFalse(state["intercepting"])
        state = advance(state, requested=True, healthy=True, reason=None, now=832)
        self.assertTrue(state["intercepting"])

    def test_rule_counts_outages_not_parallel_requests_or_recovery_probes(self):
        state = advance(None, requested=True, healthy=True, reason=None, now=0)
        state = advance(state, requested=True, healthy=True, reason=None, now=30)
        # Four failed requests within one outage must not consume four retries.
        for now in (31, 31.01, 31.02, 31.1):
            state = advance(state, requested=True, healthy=False, reason="upstream_transport_failed", now=now,
                            count_failure=state.get("intercepting") is True)
        self.assertEqual(len(state["faults"]), 1)
        # Intermittent probe successes during recovery are not recovered service.
        for now, healthy in ((40, True), (50, False), (60, True), (70, False), (80, True)):
            state = advance(state, requested=True, healthy=healthy, reason="upstream_probe_timeout", now=now,
                            count_failure=state.get("intercepting") is True)
        self.assertEqual(len(state["faults"]), 1)
        self.assertFalse(state["latched"])
        state = advance(state, requested=True, healthy=True, reason=None, now=110, count_failure=False)
        self.assertTrue(state["intercepting"])
        for now in (111, 160):
            state = advance(state, requested=True, healthy=False, reason="upstream_transport_failed", now=now,
                            count_failure=state.get("intercepting") is True)
            if now == 111:
                state = advance(state, requested=True, healthy=True, reason=None, now=120, count_failure=False)
                state = advance(state, requested=True, healthy=True, reason=None, now=150, count_failure=False)
        self.assertTrue(state["latched"])
        self.assertEqual(len(state["faults"]), 3)

    def test_controller_does_not_latch_a_burst_or_failed_recovery_probe(self):
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            root = Path(directory)
            for name in ("CONFIG", "STATE", "EFFECTIVE", "TRUST"):
                stack.enter_context(patch.object(control, name, root / (name + ".json")))
            config = {"schema": 1, "enabled": True, "devices": [{"id": "mac", "name": "Mac", "addresses": ["192.0.2.2"]}],
                      "rules": [{"id": "target", "name": "Target", "devices": ["mac"], "domain": "example.com", "match": "exact", "port": 443, "enabled": True, "strategy": "h2"}]}
            now = time.monotonic()
            admitted = {"healthy": True, "healthy_since": now - 100, "intercepting": True, "faults": [], "probe_ok": True}
            control.atomic(control.CONFIG, config)
            control.atomic(control.EFFECTIVE, config)
            control.atomic(control.STATE, {"last_tick": now, "engine_pid": 1, "recovery": admitted,
                                          "rule_recovery": {"target": admitted}})
            stack.enter_context(patch.object(control, "effective", side_effect=lambda c, *a: copy.deepcopy(c)))
            stack.enter_context(patch.object(control, "ca_fingerprint", return_value="test"))
            stack.enter_context(patch.object(control, "certificate_refresh_required", return_value=False))
            stack.enter_context(patch.object(control.haproxy, "sync_rule_switches"))
            stack.enter_context(patch.object(control, "snapshot", return_value={"interfaces": [], "ipv4_proxy": True, "reason": None}))
            for name in ("prepare", "bypass", "renew"):
                stack.enter_context(patch.object(control.gateway, name))
            events = [{"id": i + 1, "rule": "target", "at": now, "reason": "upstream_connection_reset"} for i in range(4)]
            def health(**kwargs):
                return {"ready": True, "processing_chain": True, "transparent_chain": True, "pid": 1,
                        "revision": control.haproxy.configuration_revision(json.loads(control.EFFECTIVE.read_bytes())), "failure_events": events}
            stack.enter_context(patch.object(control, "engine_health", side_effect=health))
            probe = stack.enter_context(patch.object(control, "probe_rules", new_callable=AsyncMock))
            stack.enter_context(patch.object(control, "resolve_targets", new_callable=AsyncMock, return_value={"target": ["192.0.2.3"]}))
            for offset, ok in ((0, True), (11, False), (22, True), (33, False), (44, True)):
                probe.return_value = {"target": {"ok": ok, "reason": None if ok else "upstream_probe_timeout"}}
                with patch.object(control.time, "monotonic", return_value=now + offset):
                    with (root / "network.lock").open("a") as lock:
                        control.tick(lock)
                state = control.read(control.STATE)
                recovery = state["rule_recovery"]["target"]
                self.assertFalse(recovery["latched"])
                self.assertEqual(len(recovery["faults"]), 1)
                self.assertEqual(recovery["last_failure"]["reason"], "upstream_connection_reset")
                # Keep the module watchdog fresh as normal intervening ticks do.
                state["last_tick"] = now + offset + 10
                control.atomic(control.STATE, state)
            self.assertEqual(recovery["last_error"], 4)

    def test_scoped_ipv6_cannot_inject_engine_configuration(self):
        candidate = {'schema': 1, 'enabled': False, 'devices': [
            {'id': 'client', 'name': 'Client', 'addresses': ['fe80::1%zone\nfrontend injected']}], 'rules': []}
        with self.assertRaisesRegex(ValueError, 'invalid_device_address'):
            validate(candidate)

    def test_match_precedence_and_conflict(self):
        base = {"name": "Rule", "devices": ["mac"], "enabled": True, "port": 443}
        config = validate({"schema": 1, "enabled": True, "devices": [{"id": "mac", "name": "Mac", "addresses": ["192.0.2.2"]}],
                           "rules": [{**base, "id": "suffix", "domain": "example.com", "match": "suffix", "strategy": "h2"},
                                     {**base, "id": "exact", "domain": "images.example.com", "match": "exact", "strategy": "bypass"}]})
        self.assertEqual(select(config, "192.0.2.2", "images.example.com", 443)["strategy"], "bypass")
        self.assertEqual(select(config, "192.0.2.2", "api.example.com", 443)["strategy"], "h2")
        self.assertIsNone(select(config, "192.0.2.3", "api.example.com", 443))
        self.assertIsNone(select(config, "192.0.2.2", None, 443))
        self.assertIsNone(select(config, "192.0.2.2", "evil-example.com", 443))
        config["rules"].append({**config["rules"][0], "id": "conflict"})
        with self.assertRaisesRegex(ValueError, "conflicting_rule"):
            validate(config)

    def test_unproven_routing_is_rejected(self):
        network = {"backend": "native-mihomo", "ready": True, "router_proxy": True, "lan_proxy": True,
                   "compatibility_ownership_guard": True}
        self.assertEqual(admission({}, {**network, "compatibility_ownership_guard": False}), "native_ownership_guard_missing")
        self.assertIsNone(admission({"rules": ["DOMAIN,example.com,DIRECT", "MATCH,DIRECT"]}, network))
        self.assertIsNotNone(admission({"rules": ["SRC-IP-CIDR,192.0.2.0/24,DIRECT"]}, network))
        self.assertIsNone(admission({"rules": ["SRC-PORT,41641,DIRECT"]}, network))
        for expression in ("41600-41650", "0", "65536", "41641/443", "!41641"):
            self.assertEqual(admission({"rules": [f"SRC-PORT,{expression},DIRECT"]}, network), "source_port_rule_unsupported")

    def test_source_port_rules_exclude_both_ingress_and_egress(self):
        profile = {"rules": ["SRC-PORT,41641,DIRECT", "SRC-PORT,443,REJECT", "MATCH,DIRECT"]}
        policy = egress_policy(profile, [32768, 60999])
        self.assertEqual(policy["excluded_ports"], [443, 41641])
        self.assertEqual(policy["port_range"], [41642, 60999])
        self.assertEqual(egress_policy({}, [32768, 60999]), {"excluded_ports": [], "port_range": None})
        with self.assertRaisesRegex(ValueError, "egress_port_range_unavailable"):
            egress_policy({"rules": [f"SRC-PORT,{port},DIRECT" for port in range(50000, 50005)]}, [50000, 50004])


if __name__ == "__main__":
    unittest.main(verbosity=2)
