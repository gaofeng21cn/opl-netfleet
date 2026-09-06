import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "openwrt/https-compat/files/usr/libexec/opl-netfleet-compat"))
from recovery import advance
from policy import select, validate
from routing import admission


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
        network = {"backend": "native-mihomo", "ready": True, "router_proxy": True, "lan_proxy": True}
        self.assertIsNone(admission({"rules": ["DOMAIN,example.com,DIRECT", "MATCH,DIRECT"]}, network))
        self.assertIsNotNone(admission({"rules": ["SRC-IP-CIDR,192.0.2.0/24,DIRECT"]}, network))
        self.assertIsNotNone(admission({"rules": ["SRC-PORT,41641,DIRECT"]}, network))
        self.assertIsNone(admission({"rules": ["SRC-PORT,41641,DIRECT"]}, {**network, "preserve_source_port": True}))


if __name__ == "__main__":
    unittest.main(verbosity=2)
