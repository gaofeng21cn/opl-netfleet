import sys
from pathlib import Path
import unittest
import copy
import hashlib
import json
import tempfile
from unittest.mock import patch, AsyncMock
from contextlib import ExitStack
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "openwrt/https-compat/files/usr/libexec/opl-netfleet-compat"))
from recovery import advance
from policy import select, validate
from routing import admission
import control


class Decisions(unittest.TestCase):
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
            stack.enter_context(patch.object(control, "snapshot", return_value={"interfaces": [], "ipv4_proxy": True}))
            stack.enter_context(patch.object(control, "admission", return_value=None))
            for name in ("prepare", "bypass", "renew"):
                stack.enter_context(patch.object(control.gateway, name))
            events = [{"id": i + 1, "rule": "target", "at": now, "reason": "upstream_connection_reset"} for i in range(4)]
            def health(**kwargs):
                return {"ready": True, "processing_chain": True, "transparent_chain": True, "pid": 1,
                        "revision": hashlib.sha256(control.EFFECTIVE.read_bytes()).hexdigest(), "failure_events": events}
            stack.enter_context(patch.object(control, "engine_health", side_effect=health))
            probe = stack.enter_context(patch.object(control, "probe_rules", new_callable=AsyncMock))
            stack.enter_context(patch.object(control, "resolve_targets", new_callable=AsyncMock, return_value={"target": ["192.0.2.3"]}))
            for offset, ok in ((0, True), (11, False), (22, True), (33, False), (44, True)):
                probe.return_value = {"target": {"ok": ok, "reason": None if ok else "upstream_probe_timeout"}}
                with patch.object(control.time, "monotonic", return_value=now + offset):
                    control.tick()
                state = control.read(control.STATE)
                recovery = state["rule_recovery"]["target"]
                self.assertFalse(recovery["latched"])
                self.assertEqual(len(recovery["faults"]), 1)
                self.assertEqual(recovery["last_failure"]["reason"], "upstream_connection_reset")
                # Keep the module watchdog fresh as normal intervening ticks do.
                state["last_tick"] = now + offset + 10
                control.atomic(control.STATE, state)
            self.assertEqual(recovery["last_error"], 4)

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
        self.assertIsNotNone(admission({"rules": ["SRC-PORT,41641,DIRECT"]}, network))
        self.assertIsNone(admission({"rules": ["SRC-PORT,41641,DIRECT"]}, {**network, "preserve_source_port": True}))


if __name__ == "__main__":
    unittest.main(verbosity=2)
