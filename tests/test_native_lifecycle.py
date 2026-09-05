import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
INIT = ROOT / "openwrt/files/etc/init.d/opl-netfleet-core"


class NativeLifecycleTest(unittest.TestCase):
    def run_init(self, body):
        script = '\n'.join([
            'extra_command() { :; }',
            '. "$1"',
            'procd_lock() { echo lock; }',
            'procd_kill() { echo "kill:$1"; }',
            body,
        ])
        return subprocess.run(
            ["sh", "-c", script, "test", str(INIT)],
            check=False, text=True, capture_output=True,
        )

    def test_reconcile_shares_service_lock_and_propagates_failure(self):
        result = self.run_init('''
ucode() { echo "gateway:$2"; return 7; }
reconcile
''')
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout.splitlines(), ["lock", "gateway:reconcile"])

    def test_running_checks_core_not_lifecycle_observer(self):
        result = self.run_init('''
procd_running() { echo "$1:$2"; return 1; }
service_running
''')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.strip(), "opl-netfleet-core:core")

    def test_failed_attach_cleans_before_core_stop(self):
        result = self.run_init('''
ucode() { echo "gateway:$2" >&2; [ "$2" != attach ]; }
service_started
''')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.splitlines(), ["gateway:attach", "gateway:cleanup"])
        self.assertEqual(result.stdout.splitlines(), ["kill:opl-netfleet-core"])

    def test_normal_stop_uses_same_cleanup_owner(self):
        result = self.run_init('''
ucode() { echo "gateway:$2" >&2; }
stop_service
service_stopped
''')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr.splitlines(), ["gateway:cleanup", "gateway:cleanup"])

    def test_core_and_notification_observer_have_distinct_instances(self):
        result = self.run_init('''
NETFLEET_PACKAGE_RESTORE=1
gateway_action() { return 0; }
config_load() { :; }
config_get() { eval "$1="; }
config_get_bool() { eval "$1=0"; }
procd_open_instance() { echo "instance:$1"; }
procd_set_param() {
    case "$1" in command|respawn) echo "$*" ;; esac
}
procd_append_param() { :; }
procd_close_instance() { :; }
start_service
''')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.splitlines(), [
            "instance:core",
            "command /usr/bin/mihomo -d /etc/opl-netfleet/native/run -f /etc/opl-netfleet/native/run/config.yaml",
            "respawn 3600 5 5",
            "instance:lifecycle",
            "command /usr/bin/ucode /usr/libexec/opl-netfleet/application/native_gateway.uc watch",
            "respawn 3600 1 0",
        ])


if __name__ == "__main__":
    unittest.main()
