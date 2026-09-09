"""Exercise gateway admission before any nftables mutation."""
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import unittest
from unittest.mock import patch

RESOURCES = Path('/usr/libexec/opl-netfleet/plugins/mihomo/resources')
if not RESOURCES.exists():
    RESOURCES = Path(__file__).resolve().parents[1] / 'openwrt/files/usr/libexec/opl-netfleet/plugins/mihomo/resources'
sys.path.insert(0, str(RESOURCES))
sys.dont_write_bytecode = True
import interception

OWNER = {"owner": "https-compat", "service": "opl-netfleet-compat", "instance": "engine", "user": "netfleet-compat"}
NETWORK = {"backend": "native-mihomo", "ready": True, "compatibility_ownership_guard": True,
           "router_proxy": True, "lan_proxy": True, "interfaces": ["br-lan"], "engine_pid": 123}


class Lease(unittest.TestCase):
    def test_invalid_request_never_reaches_network_mutation(self):
        with patch.object(interception, 'run') as run:
            for request in ({"action": "renew", "script": "flush ruleset"}, {"action": "execute"}):
                with self.assertRaises(ValueError):
                    interception.dispatch(OWNER, request, NETWORK)
            with self.assertRaisesRegex(ValueError, 'lease_owner_invalid'):
                interception.dispatch({**OWNER, "service": "../../another"}, {"action": "prepare"}, NETWORK)
            for candidates in ([["192.0.2.2", "198.51.100.0/24", 443]] * 4097,
                               [["127.0.0.1", "198.51.100.1", 443]],
                               [["192.0.2.2", "::/0", 443]],
                               [["192.0.2.2", "198.51.100.1", True]]):
                with self.assertRaises(ValueError):
                    interception.renew(candidates)
            run.assert_not_called()

    def test_disabled_gateway_stale_epoch_and_foreign_listener_cannot_renew(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            profile = root / 'config.json'
            profile.write_text(json.dumps({"rules": ["MATCH,DIRECT"]}))
            with patch.object(interception, 'CLAIM', root / 'claim.json'), \
                 patch.object(interception, 'IDENTITY_PATHS', [profile]), \
                 patch.object(interception, 'network_lock_held', return_value=True), \
                 patch.object(interception, 'bypass') as bypass, \
                 patch.object(interception, 'prepare') as prepare, \
                 patch.object(interception.pwd, 'getpwnam') as account, \
                 patch.object(interception, 'listener_owned', return_value=False):
                account.return_value.pw_uid = 1234
                with self.assertRaisesRegex(ValueError, 'native_gateway_not_ready'):
                    interception.dispatch(OWNER, {"action": "renew"}, {**NETWORK, "ready": False})
                bypass.assert_called_once()
                with self.assertRaisesRegex(ValueError, 'lease_gateway_changed'):
                    interception.dispatch(OWNER, {"action": "renew", "epoch": "old"}, NETWORK)
                token = interception.epoch(NETWORK)
                with self.assertRaisesRegex(ValueError, 'lease_listener_unconfirmed'):
                    interception.dispatch(OWNER, {"action": "renew", "epoch": token}, NETWORK)
                prepare.assert_not_called()
                profile.write_text('{"rules":["MATCH,OTHER"]}')
                self.assertNotEqual(token, interception.epoch(NETWORK))

    def test_another_owner_cannot_remove_active_slot(self):
        with tempfile.TemporaryDirectory() as temporary:
            claim = Path(temporary) / 'claim.json'
            claim.write_text(json.dumps(OWNER))
            with patch.object(interception, 'CLAIM', claim), \
                 patch.object(interception, 'network_lock_held', return_value=True), \
                 patch.object(interception, 'remove') as remove:
                with self.assertRaisesRegex(ValueError, 'lease_owner_conflict'):
                    interception.dispatch({**OWNER, "owner": "different-plugin"}, {"action": "remove"}, {})
                remove.assert_not_called()

    @unittest.skipUnless(sys.platform == 'linux', 'Linux socket ownership readback')
    def test_listener_must_belong_to_exact_process_and_uid(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            with patch.object(interception, 'PORT', listener.getsockname()[1]):
                self.assertTrue(interception.listener_owned(os.getpid(), os.getuid()))
                self.assertFalse(interception.listener_owned(os.getpid(), os.getuid() + 1))
                self.assertFalse(interception.listener_owned(os.getppid(), os.getuid()))


class SnapshotPreview(unittest.TestCase):
    def setUp(self):
        runtime = Path('/usr/libexec/opl-netfleet-compat')
        if not runtime.exists():
            runtime = Path(__file__).resolve().parents[1] / 'openwrt/https-compat/files/usr/libexec/opl-netfleet-compat'
        sys.path.insert(0, str(runtime))
        self.addCleanup(sys.path.pop, 0)

    def test_renew_rejection_discards_preview_and_next_snapshot_is_fresh(self):
        import gateway
        with patch.multiple(gateway, _watching=True, _worker=object(), _snapshot=None), \
             patch.object(gateway, 'worker_response') as response, \
             patch.object(gateway.time, 'monotonic', return_value=100):
            response.return_value = {'ok': True, 'result': {'ready': True, 'epoch': 'old'}}
            self.assertEqual(gateway.snapshot()['epoch'], 'old')
            self.assertEqual(gateway.snapshot()['epoch'], 'old')
            self.assertEqual(response.call_count, 1)
            response.return_value = {'ok': False, 'error': 'lease_gateway_changed'}
            with self.assertRaisesRegex(ValueError, 'lease_gateway_changed'):
                gateway.renew([])
            self.assertIsNone(gateway._snapshot)
            response.return_value = {'ok': True, 'result': {'ready': True, 'epoch': 'new'}}
            self.assertEqual(gateway.snapshot()['epoch'], 'new')
            self.assertEqual(response.call_count, 3)

    def test_expiry_failure_and_independent_reads_are_not_cached(self):
        import gateway
        with patch.multiple(gateway, _watching=True, _snapshot=None), \
             patch.object(gateway, 'call') as call, patch.object(gateway.time, 'monotonic') as now:
            now.return_value = 100
            call.return_value = {'ready': True, 'epoch': 'old'}
            gateway.snapshot()
            now.return_value = 110
            call.return_value = {'ready': False, 'reason': 'native_gateway_not_ready'}
            self.assertFalse(gateway.snapshot()['ready'])
            self.assertIsNone(gateway._snapshot)
            gateway.snapshot()
            self.assertEqual(call.call_count, 3)
            gateway._watching = False
            call.return_value = {'ready': True, 'epoch': 'new'}
            gateway.snapshot()
            gateway.snapshot()
            self.assertEqual(call.call_count, 5)


if __name__ == '__main__':
    unittest.main(verbosity=2)
