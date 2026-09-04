from pathlib import Path
import json
import os
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).parents[1]
WRAPPER = ROOT / "scripts" / "openwrt-vm.sh"
RUNNER = ROOT / "scripts" / "openwrt-vm" / "qualify.sh"
GUEST = ROOT / "scripts" / "openwrt-vm" / "guest-qualify.sh"
RUNTIME_GUEST = ROOT / "scripts" / "openwrt-vm" / "guest-runtime-qualify.sh"
PACKAGE_GUEST = ROOT / "scripts" / "openwrt-vm" / "guest-package-qualify.sh"
RECOVERY = ROOT / "scripts" / "recover-openwrt-local.sh"


class OpenWrtVmTests(unittest.TestCase):
    def test_vm_cli_and_shell_sources_parse(self):
        result = subprocess.run(
            [str(WRAPPER), "--help"], text=True, capture_output=True, check=False
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("--output", result.stdout)
        self.assertIn("Apple Silicon QEMU/HVF", result.stdout)
        self.assertNotIn("--rebuild", result.stdout)

        scripts = (WRAPPER, RUNNER, GUEST, RUNTIME_GUEST, PACKAGE_GUEST, RECOVERY)
        for script in scripts:
            parsed = subprocess.run(
                ["bash", "-n", str(script)], text=True, capture_output=True, check=False
            )
            self.assertEqual(0, parsed.returncode, f"{script}: {parsed.stderr}")

        runner = ROOT / "tests" / "run_deploy_matrix.py"
        parsed = subprocess.run(
            ["python3", "-m", "py_compile", str(runner)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, parsed.returncode, parsed.stderr)

    def test_vm_architecture_and_assets_are_pinned(self):
        runner = RUNNER.read_text()
        wrapper = WRAPPER.read_text()
        combined = runner + wrapper

        self.assertIn("qemu-system-aarch64", runner)
        self.assertIn("armsr-armv8-generic-ext4-combined-efi.img.gz", runner)
        for digest in ("image_sha", "mihomo_sha", "yq_sha"):
            self.assertRegex(runner, rf"(?m)^{digest}=[0-9a-f]{{64}}$")
        self.assertIn("version=25.12.5", runner)
        self.assertIn('"$(uname -s)" == Darwin', wrapper)
        self.assertIn('"$(uname -m)" == arm64', wrapper)
        self.assertIn("qemu-system-aarch64 -accel help", wrapper)
        self.assertIn("-accel hvf", runner)
        self.assertIn("-cpu host", runner)
        self.assertIn('sock.bind(("127.0.0.1", 0))', runner)
        self.assertIn("'$probe_port'", runner)
        self.assertIn("NETFLEET_PACKAGE_ARCHIVE", wrapper + runner)
        self.assertIn("opl-netfleet-openwrt-vm-qualification.v2", runner)
        self.assertIn('"accelerator": "hvf"', runner)
        self.assertIn('"qemu_version": sys.argv[11]', runner)
        self.assertNotRegex(
            combined, r"docker|linux/amd64|qemu-system-x86|-accel tcg|virtio-net-pci"
        )
        self.assertFalse((ROOT / "scripts" / "openwrt-vm" / "Dockerfile").exists())

    def test_vm_keeps_real_management_runtime_and_recovery_gates(self):
        runtime_source = RUNTIME_GUEST.read_text()
        package_source = PACKAGE_GUEST.read_text()
        guest_source = GUEST.read_text()
        source = RUNNER.read_text() + guest_source + runtime_source + package_source
        self.assertNotIn('ruleset_index" -eq 3', runtime_source)
        required_gates = (
            "var_symlink",
            "ubus",
            "deploy_failure_rollback",
            "post_failure_management",
            "ucode_runtime",
            "mihomo_runtime",
            "connections_readback",
            "config_get",
            "config_validate",
            "config_save_inactive",
            "config_apply_saved",
            "config_apply_active",
            "config_apply_rollback",
            "compile_staged",
            "enable_readback",
            "direct_history_isolated",
            "supervisor_native_recovery",
            "supervisor_lan_ingress_passthrough",
            "supervisor_lock_retry",
            "supervisor_dns_ingress_passthrough",
            "disable_native",
        )
        for gate in required_gates:
            self.assertIn(gate, source)
        self.assertNotIn('cat >"$bin/ucode"', runtime_source)
        self.assertNotIn('cat >"$bin/mihomo"', runtime_source)
        self.assertIn("netfleet-probe.test", runtime_source)
        self.assertIn("run_locked", runtime_source)
        self.assertIn("apk --timeout 300 add curl flock coreutils-date", runtime_source)
        self.assertIn("flock -n /var/lock/opl-netfleet-deploy.lock true", runtime_source)
        self.assertIn("prepare-recovery subscription:base", runtime_source)
        self.assertIn('"value": "private.example.invalid", "capability": "standard"', runtime_source)
        self.assertIn('qualification_temporary=$qualification.tmp', runtime_source)
        self.assertIn('[ "$stage" != complete ] || [ ! -s "$work/qualification.json" ]', runtime_source)
        self.assertIn('jsonfilter -i "$qualification_temporary" -e \'@.ok\'', runtime_source)
        self.assertIn('cat "$qualification"', runtime_source)
        self.assertNotIn("&& cat /tmp/netfleet-runtime-fixture/qualification.json", source)
        self.assertNotRegex(runtime_source, r"(?m)^/etc/init\.d/[^ ]+ (?:running|status)$")
        self.assertIn("call session create", guest_source)
        self.assertIn('"objects":[["luci","getFeatures"]]', guest_source)
        self.assertIn("-v list luci", guest_source)
        self.assertIn('\t"probe":{}', guest_source)
        self.assertIn("http://127.0.0.1/ubus", guest_source)
        for gate in (
            "package_database",
            "package_contents",
            "installed_bytes",
            "rpcd_methods",
            "onboarding_get",
            "onboarding_apply",
            "probe_rpc",
            "disable_native",
            "uninstall",
            "active_artifact_removed",
        ):
            self.assertIn(gate, package_source)
        self.assertIn('real_apk=$(command -v apk)', package_source)
        self.assertIn('add --virtual mihomo=1.19.30-r1', package_source)
        self.assertIn('add --virtual yq=4.53.6-r1', package_source)
        self.assertIn('cp "$fixture/bin/mihomo" /usr/bin/mihomo', package_source)
        self.assertIn('cp "$fixture/bin/yq" /usr/bin/yq', package_source)
        self.assertIn('env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin yq --version', package_source)
        self.assertIn('"$real_apk" --timeout 300 add "$candidate/$runtime_apk"', package_source)
        self.assertIn("uci set network.wan.proto=none", package_source)
        self.assertIn("ubus call network.interface.wan status", package_source)
        self.assertIn("ip -4 route show default", package_source)
        self.assertNotIn('add --force-broken-world', package_source)
        self.assertNotIn('add --allow-untrusted', package_source)
        self.assertIn('installed_manifest=$("$real_apk" list --manifest)', package_source)
        self.assertIn('"$real_apk" info -e opl-netfleet luci-app-netfleet', package_source)
        self.assertNotIn('apk info -v opl-netfleet', package_source)
        self.assertIn('ubus -v list opl-netfleet', package_source)
        self.assertNotIn('ubus -S -v list opl-netfleet', package_source)
        self.assertIn('ubus -t 300 call opl-netfleet onboarding_apply', package_source)
        self.assertIn('[ "$rpcd_timeout" -ge 300 ]', package_source)
        self.assertIn('/etc/apk/keys/opl-netfleet-apk.pem', package_source)
        self.assertIn('packages.adb', package_source)
        self.assertIn('package_arch\":\"noarch', package_source)
        self.assertIn('build_target_arch\":\"aarch64_generic', package_source)
        self.assertIn('package_metadata\":true', package_source)
        self.assertIn('policy.example.json.apk-new', package_source)
        self.assertIn("printf '{\"legacy\":true}", package_source)
        self.assertIn('probe_port=${4:?}', package_source)
        self.assertIn("DNS:www.gstatic.com", source)
        self.assertIn("dnat to \"192.168.1.2:$probe_port\"", package_source)
        self.assertIn("www.gstatic.com: 192.168.1.2", package_source)
        self.assertIn('"$fixture/bin/netfleet-test-primary"', package_source)
        self.assertIn('"$fixture/bin/netfleet-test-reserve"', package_source)
        self.assertIn('"$helpers_ready" = true', package_source)
        self.assertIn("'$package_manifest_sha' '$probe_port'", RUNNER.read_text())

        self.assertIn('/etc/nikki/profiles/opl-netfleet/mvp.manifest.json', package_source)
        self.assertNotIn('/etc/nikki/profiles/opl-netfleet/manifest.json', package_source)
        for cache in ('base.yaml', 'alpha.yaml', 'beta.yaml'):
            self.assertIn(f'cat >/etc/nikki/subscriptions/{cache}', package_source)
        self.assertIn('[ "$runtime_ready" = true ]', package_source)

    def test_vm_and_deployment_scripts_cannot_operate_device_power_or_firmware(self):
        forbidden = re.compile(
            r"(^|[;&|$(\s])(reboot|poweroff|sysupgrade|firstboot|mtd|sd_update)([;&|)\s]|$)"
        )
        for path in (
            WRAPPER,
            RUNNER,
            GUEST,
            RUNTIME_GUEST,
            PACKAGE_GUEST,
            ROOT / "scripts" / "deploy-openwrt.sh",
            ROOT / "scripts" / "deploy-openwrt-remote.sh",
            RECOVERY,
        ):
            self.assertIsNone(forbidden.search(path.read_text()), path)

    def test_local_recovery_preserves_wrong_var_before_repair(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "etc").mkdir()
            (root / "etc" / "openwrt_release").write_text("DISTRIB_ID='OpenWrt'\n")
            (root / "tmp").mkdir()
            (root / "var" / "lib").mkdir(parents=True)
            (root / "var" / "lib" / "evidence").write_text("preserve\n")
            env = os.environ.copy()
            env.update(
                {
                    "OPL_NETFLEET_RECOVERY_ROOT": str(root),
                    "OPL_NETFLEET_RECOVERY_TESTING": "1",
                }
            )
            result = subprocess.run(
                [str(RECOVERY), "--repair-var-link"],
                text=True,
                capture_output=True,
                env=env,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr + result.stdout)
            receipt = json.loads(result.stdout)
            self.assertEqual("correct_symlink", receipt["var_state"])
            self.assertTrue((root / "var").is_symlink())
            backup = Path(receipt["backup"])
            self.assertEqual("preserve\n", (backup / "lib" / "evidence").read_text())


if __name__ == "__main__":
    unittest.main()
