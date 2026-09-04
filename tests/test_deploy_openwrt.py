from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).parents[1]
HOST = ROOT / "scripts" / "deploy-openwrt.sh"
REMOTE = ROOT / "scripts" / "deploy-openwrt-remote.sh"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def platform_fixture(target: str = "fixture") -> dict:
    return {
        "schema_version": 1,
        "target": target,
        "nikki": {
            "scheduled_restart": False,
            "test_profile": True,
            "fast_reload": False,
            "api_listen": "0.0.0.0:9090",
            "api_secret_required": True,
            "allow_lan": True,
            "selection_cache": True,
            "log_level": "warning",
            "log_clear_at_stop": False,
            "ipv6": True,
            "unified_delay": True,
            "tcp_concurrent": True,
            "tun_enabled": False,
            "dns_enabled": True,
            "dns_cache_algorithm": "arc",
            "dns_ipv6": True,
            "dns_mode": "redir-host",
            "fake_ip_cache": False,
            "sniffer_enabled": True,
            "sniffer_force_dns_mapping": True,
            "sniffer_parse_pure_ip": True,
            "sniffer_override_destination": False,
            "tcp_mode": "tproxy",
            "udp_mode": "tproxy",
            "ipv4_dns_hijack": True,
            "ipv6_dns_hijack": True,
            "ipv4_proxy": True,
            "ipv6_proxy": True,
            "fake_ip_ping_hijack": False,
            "bypass_china_mainland_ip": True,
            "bypass_china_mainland_ip6": True,
        },
        "openwrt": {
            "software_flow_offload": False,
            "hardware_flow_offload": False,
        },
    }


def platform_uci_fixture(profile: str) -> dict[str, str]:
    return {
        "config.enabled": "1",
        "config.profile": profile,
        "config.scheduled_restart": "0",
        "config.test_profile": "1",
        "procd.fast_reload": "0",
        "mixin.mixin_file_content": "1",
        "mixin.api_listen": "0.0.0.0:9090",
        "mixin.api_secret": "fixture-secret",
        "mixin.allow_lan": "1",
        "mixin.authentication": "1",
        "@authentication[0].username": "fixture-user",
        "@authentication[0].password": "fixture-password",
        "mixin.selection_cache": "1",
        "mixin.log_level": "warning",
        "log.clear_at_stop": "0",
        "mixin.ipv6": "1",
        "mixin.unify_delay": "1",
        "mixin.tcp_concurrent": "1",
        "mixin.tun_enabled": "0",
        "mixin.dns_enabled": "1",
        "mixin.dns_cache_algorithm": "arc",
        "mixin.dns_ipv6": "1",
        "mixin.dns_mode": "redir-host",
        "mixin.fake_ip_cache": "0",
        "mixin.sniffer": "1",
        "mixin.sniffer_sniff_dns_mapping": "1",
        "mixin.sniffer_sniff_pure_ip": "1",
        "mixin.sniffer_sniff": "1",
        "proxy.tcp_mode": "tproxy",
        "proxy.udp_mode": "tproxy",
        "proxy.ipv4_dns_hijack": "1",
        "proxy.ipv6_dns_hijack": "1",
        "proxy.ipv4_proxy": "1",
        "proxy.ipv6_proxy": "1",
        "proxy.fake_ip_ping_hijack": "0",
        "proxy.bypass_china_mainland_ip": "1",
        "proxy.bypass_china_mainland_ip6": "1",
        "@sniff[0]": "sniff",
        "@sniff[0].protocol": "HTTP",
        "@sniff[0].overwrite_destination": "0",
        "@sniff[1]": "sniff",
        "@sniff[1].protocol": "TLS",
        "@sniff[1].overwrite_destination": "0",
        "@sniff[2]": "sniff",
        "@sniff[2].protocol": "QUIC",
        "@sniff[2].overwrite_destination": "0",
    }


class DeployOpenWrtTests(unittest.TestCase):
    def test_host_dry_run_accepts_an_ssh_alias(self):
        result = subprocess.run(
            [str(HOST), "openwrt-target", "--ref", "HEAD", "--dry-run"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        receipt = json.loads(result.stdout)
        self.assertTrue(receipt["ok"])
        self.assertEqual("openwrt-target", receipt["target"])
        self.assertRegex(receipt["product_version"], r"^[0-9][0-9A-Za-z.+~-]*$")
        self.assertIsInstance(receipt["prepare_elapsed_ms"], int)

    def test_host_dry_run_binds_a_private_instance_without_printing_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            instance = Path(directory)
            (instance / "policy.json").write_text(json.dumps({
                "schema_version": 2,
                "private": "policy-secret",
                "main": {"target": "fixture", "enabled": True},
                "policy_source": {"kind": "profile", "ref": "subscription:alpha"},
                "recovery_profile": {"ref": "subscription:alpha"},
                "providers": {
                    "alpha": {"role": "primary"},
                    "beta": {"role": "primary"},
                },
                "capabilities": {"standard": {"enabled": True}},
            }) + "\n")
            (instance / "subscriptions.json").write_text(
                '{"schema_version":1,"subscriptions":[{"section":"base","name":"Base","url":"https://secret.invalid/token"}]}\n'
            )
            (instance / "nikki-mixin.yaml").write_text("nikki-rules: []\n")
            (instance / "platform.json").write_text(json.dumps(platform_fixture()) + "\n")
            result = subprocess.run(
                [str(HOST), "openwrt-target", "--ref", "HEAD", "--instance", str(instance), "--dry-run"],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        receipt = json.loads(result.stdout)
        self.assertTrue(receipt["instance"])
        combined = result.stdout + result.stderr
        self.assertIn("policy_source=subscription:alpha", result.stderr)
        self.assertIn("recovery_profile=subscription:alpha", result.stderr)
        self.assertIn("providers=alpha:primary,beta:primary", result.stderr)
        self.assertIn("capabilities=standard", result.stderr)
        self.assertNotIn("policy-secret", combined)
        self.assertNotIn("secret.invalid", combined)

    def test_host_dry_run_accepts_a_verified_package_release(self):
        commit = subprocess.check_output(["git", "rev-parse", "HEAD^{commit}"], cwd=ROOT, text=True).strip()
        tree = subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=ROOT, text=True).strip()
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory)
            payload = Path(directory) / "payload"
            files = {
                "usr/libexec/opl-netfleet/main.uc": "candidate-main\n",
                "usr/libexec/opl-netfleet/supervisor.uc": "candidate-supervisor\n",
                "usr/libexec/opl-netfleet/output.uc": "candidate-output\n",
                "usr/libexec/rpcd/opl-netfleet": "candidate-rpcd\n",
                "etc/init.d/opl-netfleet": "candidate-init\n",
                "etc/opl-netfleet/policy.example.json": '{"schema_version":2}\n',
                "www/luci-static/resources/netfleet/api.js": "candidate-api\n",
                "www/luci-static/resources/netfleet/native.css": "candidate-style\n",
                "www/luci-static/resources/view/netfleet/overview.js": "candidate-view\n",
                "usr/share/luci/menu.d/luci-app-netfleet.json": "{}\n",
                "usr/share/rpcd/acl.d/luci-app-netfleet.json": "{}\n",
            }
            for name, content in files.items():
                path = payload / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            with (release / "FILES.sha256").open("w") as stream:
                for path in sorted(item for item in payload.rglob("*") if item.is_file()):
                    stream.write(f"{sha256(path)}  {path.relative_to(payload)}\n")
            for name in ("opl-netfleet_0.4.3-r1.apk", "luci-app-netfleet_0.4.3-r1.apk"):
                (release / name).write_text(name + "\n")
            (release / "opl-netfleet-apk.pem").write_text("test-public-key\n")
            (release / "packages.adb").write_bytes(b"test-feed-index\n")
            runtime_lines = []
            for line in (release / "FILES.sha256").read_text().splitlines():
                rel = line.split(None, 1)[1]
                if not rel.startswith("www/luci-static/resources/netfleet/") and rel not in {
                    "www/luci-static/resources/view/netfleet/overview.js",
                    "www/luci-static/resources/view/netfleet/log.js",
                    "usr/share/luci/menu.d/luci-app-netfleet.json",
                    "usr/share/rpcd/acl.d/luci-app-netfleet.json",
                }:
                    runtime_lines.append(line)
            runtime_digest = hashlib.sha256(("\n".join(runtime_lines) + "\n").encode()).hexdigest()
            manifest = {
                "schema": "opl-netfleet-package-manifest.v2",
                "source_commit": commit,
                "source_tree": tree,
                "package_version": "0.4.3",
                "package_release": "1",
                "package_format": "apk",
                "package_arch": "noarch",
                "build_target_arch": "aarch64_generic",
                "policy_schema": 2,
                "runtime_payload_sha256": runtime_digest,
                "files_manifest": {"name": "FILES.sha256", "sha256": sha256(release / "FILES.sha256")},
                "artifact_files": {
                    "opl-netfleet": "opl-netfleet_0.4.3-r1.apk",
                    "luci-app-netfleet": "luci-app-netfleet_0.4.3-r1.apk",
                },
                "artifacts": [
                    {"package": "opl-netfleet", "name": "opl-netfleet_0.4.3-r1.apk", "sha256": sha256(release / "opl-netfleet_0.4.3-r1.apk"), "size": (release / "opl-netfleet_0.4.3-r1.apk").stat().st_size},
                    {"package": "luci-app-netfleet", "name": "luci-app-netfleet_0.4.3-r1.apk", "sha256": sha256(release / "luci-app-netfleet_0.4.3-r1.apk"), "size": (release / "luci-app-netfleet_0.4.3-r1.apk").stat().st_size},
                ],
                "apk_public_key": {"name": "opl-netfleet-apk.pem", "sha256": sha256(release / "opl-netfleet-apk.pem")},
                "feed_index": {"name": "packages.adb", "sha256": sha256(release / "packages.adb")},
            }
            (release / "manifest.json").write_text(json.dumps(manifest) + "\n")
            result = subprocess.run(
                [str(HOST), "openwrt-target", "--ref", "HEAD", "--packages", str(release), "--dry-run"],
                cwd=ROOT, text=True, capture_output=True, check=False,
            )
        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        receipt = json.loads(result.stdout)
        self.assertEqual("package", receipt["release_mode"])
        self.assertEqual("apk", receipt["release_format"])
        self.assertIn("format=apk arch=noarch build_target=aarch64_generic", result.stderr)

    def test_host_activation_requires_matching_vm_qualification(self):
        commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD^{commit}"], cwd=ROOT, text=True
        ).strip()
        tree = subprocess.check_output(
            ["git", "rev-parse", "HEAD^{tree}"], cwd=ROOT, text=True
        ).strip()
        with tempfile.TemporaryDirectory() as directory:
            cache_root = Path(directory) / "cache"
            receipt = Path(directory) / "qualification.json"
            receipt.write_text(json.dumps({
                "schema": "opl-netfleet-openwrt-vm-qualification.v1",
                "qualified": True,
                "source_commit": commit,
                "source_tree": tree,
                "checks": {
                    "boot": True,
                    "ssh": True,
                    "var_symlink": True,
                    "ubus": True,
                    "deploy_failure_rollback": True,
                    "post_failure_management": True,
                },
            }) + "\n")
            env = os.environ.copy()
            env["XDG_CACHE_HOME"] = str(cache_root)
            result = subprocess.run(
                [
                    str(HOST), "openwrt-target", "--ref", "HEAD", "--activate",
                    "--qualification", str(receipt), "--dry-run",
                ],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            cached = cache_root / "opl-netfleet" / "vm-qualifications" / f"{commit}-{tree}.json"
            source_receipt_bytes = receipt.read_bytes()
            cached_receipt_bytes = cached.read_bytes()
            cached_mode = cached.stat().st_mode & 0o777
        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        value = json.loads(result.stdout)
        self.assertEqual("activate", value["mode"])
        self.assertTrue(value["activation_qualified"])
        self.assertEqual("explicit", value["qualification_source"])
        self.assertEqual(source_receipt_bytes, cached_receipt_bytes)
        self.assertEqual(0o600, cached_mode)
        self.assertIn("qualification_cache=", result.stderr)

    def test_host_activation_reuses_commit_tree_qualification_cache(self):
        commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD^{commit}"], cwd=ROOT, text=True
        ).strip()
        tree = subprocess.check_output(
            ["git", "rev-parse", "HEAD^{tree}"], cwd=ROOT, text=True
        ).strip()
        with tempfile.TemporaryDirectory() as directory:
            cache_root = Path(directory)
            receipt_dir = cache_root / "opl-netfleet" / "vm-qualifications"
            receipt_dir.mkdir(parents=True)
            receipt = receipt_dir / f"{commit}-{tree}.json"
            receipt.write_text(json.dumps({
                "schema": "opl-netfleet-openwrt-vm-qualification.v1",
                "qualified": True,
                "source_commit": commit,
                "source_tree": tree,
                "checks": {
                    "boot": True,
                    "ssh": True,
                    "var_symlink": True,
                    "ubus": True,
                    "deploy_failure_rollback": True,
                    "post_failure_management": True,
                },
            }) + "\n")
            env = os.environ.copy()
            env["XDG_CACHE_HOME"] = str(cache_root)
            result = subprocess.run(
                [str(HOST), "openwrt-target", "--ref", "HEAD", "--activate", "--dry-run"],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        value = json.loads(result.stdout)
        self.assertTrue(value["activation_qualified"])
        self.assertEqual("cache", value["qualification_source"])
        self.assertIn("qualification=cache", result.stderr)

    def test_host_presentation_only_skips_vm_qualification(self):
        self._make_instance_bundle()
        result = subprocess.run(
            [
                str(HOST), "openwrt-target", "--ref", "HEAD",
                "--instance", str(self.bundle), "--presentation-only", "--dry-run",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        value = json.loads(result.stdout)
        self.assertEqual("presentation_only", value["mode"])
        self.assertFalse(value["activation_qualified"])
        self.assertEqual("none", value["qualification_source"])

    def test_host_archives_exclude_extended_attributes(self):
        self.assertEqual(2, HOST.read_text().count("tar --no-xattrs"))

    def test_host_rejects_stale_vm_qualification_before_ssh(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "qualification.json"
            receipt.write_text(json.dumps({
                "schema": "opl-netfleet-openwrt-vm-qualification.v1",
                "qualified": True,
                "source_commit": "0" * 40,
                "source_tree": "1" * 40,
                "checks": {},
            }) + "\n")
            result = subprocess.run(
                [
                    str(HOST), "openwrt-target", "--ref", "HEAD", "--activate",
                    "--qualification", str(receipt), "--dry-run",
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("does not match this source", result.stderr)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.device = self.base / "device"
        self.bundle = self.base / "bundle"
        self.state = self.base / "state"
        self.bin = self.base / "bin"
        for path in (self.device, self.bundle, self.state, self.bin):
            path.mkdir(parents=True)
        self._write_fake_commands()
        self._write_device()
        self._write_bundle()

    def _write_executable(self, name: str, source: str):
        path = self.bin / name
        path.write_text(textwrap.dedent(source).lstrip())
        path.chmod(0o755)

    def _write_fake_commands(self):
        self._write_executable("mihomo", "#!/bin/sh\nexit 0\n")
        self._write_executable(
            "yq",
            r"""
            #!/usr/bin/env python3
            import json
            from pathlib import Path
            import sys

            source = Path(sys.argv[-1])
            text = source.read_text().strip()
            if text in {"nikki-rules: []", "nikki-rules: [ ]"}:
                print(json.dumps({"nikki-rules": []}))
            elif text.startswith("{"):
                print(json.dumps(json.loads(text)))
            else:
                print("{}")
            """,
        )
        self._write_executable(
            "curl",
            r"""
            #!/usr/bin/env python3
            import json
            import os
            from pathlib import Path
            import shutil
            import sys

            args = sys.argv[1:]
            state = Path(os.environ["FAKE_STATE"])
            with (state / "curl-args.jsonl").open("a") as stream:
                stream.write(json.dumps(args) + "\n")
            if "http://127.0.0.1/ubus" in args:
                if (state / "uhttpd-stale").exists():
                    print('{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Object not found"}}')
                elif not (state / "session-granted").exists():
                    print('{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"Access denied"}}')
                else:
                    print('{"jsonrpc":"2.0","id":1,"result":[0,{}]}')
                sys.exit(0)
            if any("127.0.0.1:9090/configs" in arg for arg in args):
                if os.environ.get("FAKE_PROXY_RUNTIME") == "1":
                    print('{"mixed-port":7890}')
                    sys.exit(0)
                sys.exit(1)
            if "-o" not in args:
                sys.exit(0)
            output = Path(args[args.index("-o") + 1])
            name = output.name.removesuffix(".tmp")
            source = Path(os.environ["FAKE_RULESET_SOURCE"]) / name
            if not source.is_file():
                sys.exit(1)
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, output)
            """,
        )
        self._write_executable(
            "pidof",
            r"""
            #!/bin/sh
            [ "${FAKE_PROXY_RUNTIME:-}" = "1" ] && [ "$1" = "mihomo" ]
            """,
        )
        self._write_executable(
            "jsonfilter",
            r"""
            #!/usr/bin/env python3
            import json
            import re
            import sys

            args = sys.argv[1:]
            if "-i" in args:
                source = json.load(open(args[args.index("-i") + 1]))
            elif "-s" in args:
                source = json.loads(args[args.index("-s") + 1])
            else:
                source = json.load(sys.stdin)
            expression = args[args.index("-e") + 1]
            value = source
            for part in expression.removeprefix("@.").split("."):
                if not part:
                    continue
                indexed = re.fullmatch(r"([^\[]+)\[(\d+)\]", part)
                quoted = re.fullmatch(r'([^\[]+)\["([^"]+)"\]', part)
                if indexed:
                    name, index = indexed.groups()
                    if not isinstance(value, dict) or name not in value:
                        sys.exit(1)
                    value = value[name]
                    if not isinstance(value, list) or int(index) >= len(value):
                        sys.exit(1)
                    value = value[int(index)]
                elif quoted:
                    name, key = quoted.groups()
                    if not isinstance(value, dict) or name not in value:
                        sys.exit(1)
                    value = value[name]
                    if not isinstance(value, dict) or key not in value:
                        sys.exit(1)
                    value = value[key]
                else:
                    if not isinstance(value, dict) or part not in value:
                        sys.exit(1)
                    value = value[part]
            if isinstance(value, bool):
                print("true" if value else "false")
            elif value is not None:
                print(value)
            """,
        )
        self._write_executable(
            "uci",
            r"""
            #!/usr/bin/env python3
            import json
            import os
            from pathlib import Path
            import sys

            root = Path(os.environ["OPL_NETFLEET_DEPLOY_ROOT"])

            def location(value):
                config, key = value.split(".", 1)
                return root / "etc/config" / config, key

            def load(path):
                return json.loads(path.read_text()) if path.exists() else {}

            def save(path, value):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(value, sort_keys=True) + "\n")

            args = [item for item in sys.argv[1:] if item != "-q"]
            if not args:
                sys.exit(1)
            action = args[0]
            if action == "get":
                path, key = location(args[1])
                data = load(path)
                if key not in data:
                    sys.exit(1)
                print(data[key])
            elif action == "set":
                target, value = args[1].split("=", 1)
                path, key = location(target)
                data = load(path)
                data[key] = value
                save(path, data)
            elif action == "delete":
                path, prefix = location(args[1])
                data = load(path)
                for key in list(data):
                    if key == prefix or key.startswith(prefix + "."):
                        del data[key]
                save(path, data)
            elif action == "commit":
                pass
            else:
                sys.exit(1)
            """,
        )
        self._write_executable(
            "ucode",
            r"""
            #!/usr/bin/env python3
            import json
            import os
            from pathlib import Path
            import sys

            if len(sys.argv) >= 4 and sys.argv[1] == "-":
                sys.stdin.read()
                left = json.loads(Path(sys.argv[2]).read_text())
                right = json.loads(Path(sys.argv[3]).read_text())
                sys.exit(0 if left == right else 1)

            state = Path(os.environ["FAKE_STATE"])
            uci_path = Path(os.environ["FAKE_UCI_FILE"])
            main_path = Path(sys.argv[1])
            action = sys.argv[2]

            def uci_data():
                return json.loads(uci_path.read_text())

            def profile_value():
                return uci_data().get("config.profile", "")

            def set_profile(value):
                data = uci_data()
                data["config.profile"] = value
                uci_path.write_text(json.dumps(data, sort_keys=True) + "\n")

            profile = profile_value()
            active = "file:OPL-NetFleet.json"
            legacy_active = "file:opl-netfleet/mvp.json"
            netfleet_profiles = {active, legacy_active}
            base = "subscription:base"
            with (state / "actions").open("a") as stream:
                stream.write(f"{action}\n")

            def emit(ok, result=None, error=None, detail=None):
                value = {"ok": ok, "action": action}
                if ok:
                    value["result"] = result or {}
                else:
                    value["error"] = error or f"{action}_failed"
                    if detail is not None:
                        value["detail"] = detail
                print(json.dumps(value))
                sys.exit(0 if ok else 1)

            fail_action = os.environ.get("FAKE_FAIL_ACTION")
            if (
                os.environ.get("FAKE_REJECT_CANDIDATE_PREFLIGHT") == "1"
                and "candidate" in main_path.parts
                and action in {"status", "probe"}
            ):
                emit(False, error="policy_unreadable")
            if action == "validate-schema":
                emit(True, {"policy_schema": 2})
            if action == "validate":
                emit(True, {"would_generate": True})
            if action == "status":
                emit(True, {
                    "active": profile in netfleet_profiles,
                    "profile": profile,
                    "runtime": {
                        "netfleet_present": profile in netfleet_profiles,
                        "mihomo_running": True,
                        "controller_available": True,
                    },
                })
            if action == "probe":
                if (state / "fail-native-probe").exists() and profile == base:
                    emit(False, error="protected_probe_failed")
                if (state / "fail-final-probe").exists() and (state / "enabled-once").exists():
                    emit(False, error="protected_probe_failed")
                emit(True, {"count": 2})
            if action == "disable":
                if fail_action == "disable":
                    emit(False, error="disable_failed")
                set_profile(base)
                (state / "prepared").unlink(missing_ok=True)
                native_ok = not (state / "fail-native-probe").exists()
                emit(True, {
                    "state": "native_profile",
                    "business_ok": native_ok,
                    "protected_probes": {"ok": native_ok},
                })
            if action == "compile":
                if fail_action == "compile":
                    emit(False, error="compile_failed")
                (state / "prepared").write_text("1\n")
                emit(True, {"state": "staged"})
            if action == "prepare-recovery":
                expected = sys.argv[3]
                if profile != expected:
                    emit(False, error="profile_precondition_stale")
                if fail_action == "prepare-recovery":
                    if os.environ.get("FAKE_DROP_UBUS_ON_FAILURE") == "1":
                        (state / "ubus-unavailable").write_text("1\n")
                    emit(False, error="recovery_profile_unhealthy")
                if fail_action == "prepare-recovery-unexpected":
                    emit(False, error="unexpected_error", detail={
                        "unexpected_stacktrace": [{"line": 321}, {"line": 97}],
                    })
                data = uci_data()
                data["config.enabled"] = "1"
                uci_path.write_text(json.dumps(data, sort_keys=True) + "\n")
                set_profile(base)
                emit(True, {"profile": base, "business_ok": True})
            if action == "restore-recovery":
                target = sys.argv[3]
                set_profile(target)
                emit(True, {"profile": target, "business_ok": True})
            if action == "enable":
                if fail_action == "enable":
                    set_profile(base)
                    emit(False, error="enable_failed")
                if not (state / "prepared").exists():
                    emit(False, error="staged_input_stale")
                target = legacy_active if main_path.read_text() == "old-main\n" else active
                set_profile(target)
                (state / "enabled-once").write_text("1\n")
                emit(True, {"state": "active", "protected_probes": {"ok": True}})
            emit(False, error="unknown_action")
            """,
        )
        self._write_executable(
            "flock",
            """
            #!/bin/sh
            exit 0
            """,
        )
        self._write_executable(
            "pidof",
            r"""
            #!/bin/sh
            if [ "$1" = "mihomo" ] && [ ! -f "$FAKE_STATE/mihomo-down" ]; then
                printf '4242\n'
                exit 0
            fi
            exit 1
            """,
        )
        self._write_executable(
            "ip",
            """
            #!/bin/sh
            echo 'default via 192.0.2.1 dev wan'
            """,
        )
        self._write_executable(
            "apk",
            r"""
            #!/usr/bin/env python3
            import os
            from pathlib import Path
            import shutil
            import sys

            if sys.argv[1:] == ["--print-arch"]:
                print(os.environ.get("FAKE_APK_ARCH", "aarch64"))
                sys.exit(0)
            if "add" not in sys.argv:
                sys.exit(1)
            source = Path(os.environ["FAKE_PACKAGE_CANDIDATE"])
            root = Path(os.environ["OPL_NETFLEET_DEPLOY_ROOT"])
            for path in source.rglob("*"):
                target = root / path.relative_to(source)
                if path.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                elif path.is_file():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(path, target)
            package_names = [Path(arg).name for arg in sys.argv if arg.endswith(".apk") or arg.endswith(".ipk")]
            with (Path(os.environ["FAKE_STATE"]) / "package-actions").open("a") as stream:
                stream.write(" ".join(package_names) + "\n")
            """,
        )
        self._write_executable(
            "ubus",
            r"""
            #!/usr/bin/env python3
            import os
            from pathlib import Path
            import sys

            args = sys.argv[1:]
            state = Path(os.environ["FAKE_STATE"])
            if args[:3] == ["call", "session", "create"]:
                print('{"ubus_rpc_session":"0123456789abcdef0123456789abcdef"}')
                sys.exit(0)
            if args[:3] == ["call", "session", "grant"]:
                import json

                payload = json.loads(args[3])
                if payload.get("scope") == "ubus" and payload.get("objects") == [["luci", "getFeatures"]]:
                    (state / "session-granted").write_text("1\n")
                print("{}")
                sys.exit(0)
            if args[:3] == ["call", "session", "destroy"]:
                (state / "session-granted").unlink(missing_ok=True)
                print("{}")
                sys.exit(0)
            if args == ["call", "system", "board"]:
                if (state / "ubus-unavailable").exists():
                    sys.exit(1)
                print("{}")
                sys.exit(0)
            if args == ["-v", "list", "luci"]:
                if (state / "luci-missing").exists():
                    sys.exit(1)
                print("'luci' @fixture")
                print('\t"getFeatures":{}')
                sys.exit(0)
            if args != ["-v", "list", "opl-netfleet"]:
                sys.exit(1)
            root = Path(os.environ["OPL_NETFLEET_DEPLOY_ROOT"])
            if not (state / "rpcd-registered").exists():
                sys.exit(1)
            rpcd = (root / "usr/libexec/rpcd/opl-netfleet").read_text()
            if (state / "rpcd-stale").exists():
                print("'opl-netfleet' @fixture")
                print('\t"status":{}')
                print('\t"disable":{}')
            elif (state / "rpcd-legacy").exists():
                print("'opl-netfleet' @fixture")
                for method in ("status", "events", "enable", "select_auto", "refresh", "disable"):
                    print(f'\t"{method}":{{}}')
            else:
                print("'opl-netfleet' @fixture")
                for method in (
                    "status", "events", "connections", "config_get", "config_validate", "config_save",
                    "config_apply", "enable", "select_auto", "refresh", "disable",
                ):
                    print(f'\t"{method}":{{}}')
            """,
        )

    def _write_device(self):
        supervisor_init = r"""#!/bin/sh
state=${FAKE_STATE:?}
printf '%s\n' "$1" >>"$state/supervisor-actions"
case "$1" in
    enabled) test -f "$state/supervisor-enabled" ;;
    enable) : >"$state/supervisor-enabled" ;;
    disable) rm -f "$state/supervisor-enabled" ;;
    status) test -f "$state/supervisor-running" ;;
    start|restart)
        if [ "${FAKE_FAIL_SUPERVISOR_START_ONCE:-}" = "1" ] && [ ! -f "$state/supervisor-start-failed" ]; then
            : >"$state/supervisor-start-failed"
            exit 1
        fi
        : >"$state/supervisor-running"
        ;;
    stop) rm -f "$state/supervisor-running" ;;
    *) exit 1 ;;
esac
"""
        nikki_init = r"""#!/bin/sh
root=${OPL_NETFLEET_DEPLOY_ROOT:?}
case "$1" in
    update_subscription)
        section=$2
        printf 'update:%s\n' "$section" >>"$FAKE_STATE/nikki-actions"
        if [ "${FAKE_FAIL_SUBSCRIPTION:-}" = "$section" ]; then
            exit 1
        fi
        mkdir -p "$root/etc/nikki/subscriptions"
        printf 'proxies: []\nproxy-groups: []\nrules: []\n' >"$root/etc/nikki/subscriptions/$section.yaml"
        uci set "nikki.$section.success=1"
        uci commit nikki
        ;;
    restart|stop|start)
        printf '%s\n' "$1" >>"$FAKE_STATE/nikki-actions"
        ;;
    status) printf 'running\n' ;;
    *) exit 1 ;;
esac
"""
        files = {
            "usr/libexec/opl-netfleet/main.uc": "old-main\n",
            "usr/libexec/opl-netfleet/supervisor.uc": "old-supervisor\n",
            "usr/libexec/opl-netfleet/output.uc": "old-output\n",
            "usr/libexec/rpcd/opl-netfleet": "old-rpcd\n",
            "etc/init.d/opl-netfleet": supervisor_init,
            "etc/init.d/nikki": nikki_init,
            "etc/nikki/mixin.yaml": "nikki-rules: []\n",
            "etc/opl-netfleet/policy.example.json": '{"schema_version":1}\n',
            "etc/opl-netfleet/policy.json": '{"schema_version":1}\n',
            "etc/nikki/profiles/opl-netfleet/mvp.json": "old-artifact\n",
            "etc/nikki/profiles/opl-netfleet/mvp.manifest.json": '{"old":true}\n',
            "var/lib/opl-netfleet/evidence.json": '{"old":true}\n',
            "var/lib/opl-netfleet/events.json": '{"schema_version":1,"events":[]}\n',
            "www/luci-static/resources/netfleet/api.js": "old-api\n",
            "www/luci-static/resources/netfleet/ui/netfleet-ui.css": "old-style\n",
            "www/luci-static/resources/netfleet/ui/netfleet-ui.js": "old-ui\n",
            "www/luci-static/resources/view/netfleet/overview.js": "old-view\n",
            "www/luci-static/resources/view/netfleet/log.js": "old-log\n",
            "usr/share/luci/menu.d/luci-app-netfleet.json": "{}\n",
            "usr/share/rpcd/acl.d/luci-app-netfleet.json": "{}\n",
        }
        for relative, content in files.items():
            path = self.device / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        (self.device / "usr/libexec/opl-netfleet/main.uc").chmod(0o755)
        (self.device / "usr/libexec/opl-netfleet/supervisor.uc").chmod(0o755)
        (self.device / "usr/libexec/rpcd/opl-netfleet").chmod(0o755)
        (self.device / "etc/init.d/opl-netfleet").chmod(0o755)
        (self.device / "etc/init.d/nikki").chmod(0o755)
        rpcd_init = self.device / "etc/init.d/rpcd"
        rpcd_init.parent.mkdir(parents=True, exist_ok=True)
        rpcd_init.write_text(textwrap.dedent(
            r"""
            #!/bin/sh
            if [ "${FAKE_FAIL_RPCD_RESTART:-}" = "1" ]; then
                exit 1
            fi
            rm -f "$FAKE_STATE/rpcd-stale" "$FAKE_STATE/rpcd-legacy" "$FAKE_STATE/luci-missing"
            : >"$FAKE_STATE/rpcd-registered"
            : >"$FAKE_STATE/uhttpd-stale"
            printf '%s\n' "$1" >>"$FAKE_STATE/rpcd-actions"
            """
        ).lstrip())
        rpcd_init.chmod(0o755)
        uhttpd_init = self.device / "etc/init.d/uhttpd"
        uhttpd_init.write_text(textwrap.dedent(
            r"""
            #!/bin/sh
            printf '%s\n' "$1" >>"$FAKE_STATE/uhttpd-actions"
            if [ "$1" = "restart" ]; then
                rm -f "$FAKE_STATE/uhttpd-stale"
                exit 0
            fi
            exit 1
            """
        ).lstrip())
        uhttpd_init.chmod(0o755)
        firewall_init = self.device / "etc/init.d/firewall"
        firewall_init.write_text("#!/bin/sh\nprintf '%s\\n' \"$1\" >>\"$FAKE_STATE/firewall-actions\"\n")
        firewall_init.chmod(0o755)
        uci_file = self.device / "etc/config/nikki"
        uci_file.parent.mkdir(parents=True, exist_ok=True)
        uci_file.write_text(json.dumps(platform_uci_fixture("file:opl-netfleet/mvp.json"), sort_keys=True) + "\n")
        (self.device / "etc/config/rpcd").write_text(json.dumps({
            "@rpcd[0].timeout": "30",
        }, sort_keys=True) + "\n")
        (self.device / "etc/config/firewall").write_text(json.dumps({
            "@defaults[0].flow_offloading": "0",
            "@defaults[0].flow_offloading_hw": "0",
        }, sort_keys=True) + "\n")
        (self.state / "actions").write_text("")
        (self.state / "rpcd-actions").write_text("")
        (self.state / "uhttpd-actions").write_text("")
        (self.state / "supervisor-actions").write_text("")
        (self.state / "nikki-actions").write_text("")
        (self.state / "firewall-actions").write_text("")
        (self.state / "package-actions").write_text("")
        (self.state / "supervisor-enabled").write_text("1\n")
        (self.state / "supervisor-running").write_text("1\n")
        (self.state / "prepared").write_text("1\n")
        (self.state / "rpcd-registered").write_text("1\n")

    def _write_bundle(self):
        payload = self.base / "payload"
        ruleset_source = self.state / "ruleset-source"
        ruleset_source.mkdir()
        fixture_rulesets = (
            ("private-domain", "domain"),
            ("private-ip", "ipcidr"),
            ("ai-domain", "domain"),
            ("netflix-domain", "domain"),
            ("netflix-ip", "ipcidr"),
            ("youtube-domain", "domain"),
            ("telegram-domain", "domain"),
            ("telegram-ip", "ipcidr"),
            ("social-domain", "domain"),
            ("steam-domain", "domain"),
            ("xbox-domain", "domain"),
            ("playstation-domain", "domain"),
            ("nintendo-domain", "domain"),
            ("microsoft-domain", "domain"),
            ("apple-domain", "domain"),
            ("google-domain", "domain"),
            ("domestic-media-domain", "domain"),
            ("cn-domain", "domain"),
            ("cn-ip", "ipcidr"),
            ("geolocation-non-cn", "domain"),
        )
        for name, _behavior in fixture_rulesets:
            (ruleset_source / f"{name}.mrs").write_text(f"fixture-{name}\n")
        commit = "4d065eb9c68fb13603fa4678cc34735db76cabb8"
        ruleset_entries = []
        for name, behavior in fixture_rulesets:
            source = ruleset_source / f"{name}.mrs"
            ruleset_entries.append({
                "id": name,
                "behavior": behavior,
                "format": "mrs",
                "url": f"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/{commit}/fixture/{name}.mrs",
                "size_bytes": source.stat().st_size,
                "sha256": sha256(source),
            })
        ruleset_lock = json.dumps({
            "schema": "opl-netfleet-ruleset-lock.v1",
            "upstream": {"repository": "MetaCubeX/meta-rules-dat", "commit": commit, "license": "GPL-3.0"},
            "rulesets": ruleset_entries,
        }, sort_keys=True) + "\n"
        installed_rulesets = self.device / "etc/nikki/run/rulesets"
        installed_rulesets.mkdir(parents=True, exist_ok=True)
        for source in ruleset_source.glob("*.mrs"):
            shutil.copy2(source, installed_rulesets / source.name)
        supervisor_init = r"""#!/bin/sh
state=${FAKE_STATE:?}
printf '%s\n' "$1" >>"$state/supervisor-actions"
case "$1" in
    enabled) test -f "$state/supervisor-enabled" ;;
    enable) : >"$state/supervisor-enabled" ;;
    disable) rm -f "$state/supervisor-enabled" ;;
    status) test -f "$state/supervisor-running" ;;
    start|restart)
        if [ "${FAKE_FAIL_SUPERVISOR_START_ONCE:-}" = "1" ] && [ ! -f "$state/supervisor-start-failed" ]; then
            : >"$state/supervisor-start-failed"
            exit 1
        fi
        : >"$state/supervisor-running"
        ;;
    stop) rm -f "$state/supervisor-running" ;;
    *) exit 1 ;;
esac
"""
        files = {
            "usr/libexec/opl-netfleet/main.uc": "new-main\n",
            "usr/libexec/opl-netfleet/supervisor.uc": "new-supervisor\n",
            "usr/libexec/opl-netfleet/output.uc": "new-output\n",
            "usr/libexec/rpcd/opl-netfleet": "new-rpcd\n",
            "etc/init.d/opl-netfleet": supervisor_init,
            "etc/opl-netfleet/policy.example.json": '{"schema_version":2,"new":true}\n',
            "etc/opl-netfleet/rulesets.lock.json": ruleset_lock,
            "www/luci-static/resources/netfleet/api.js": "new-api\n",
            "www/luci-static/resources/netfleet/native.css": "new-native\n",
            "www/luci-static/resources/view/netfleet/overview.js": "new-view\n",
            "usr/share/luci/menu.d/luci-app-netfleet.json": '{"new":true}\n',
            "usr/share/rpcd/acl.d/luci-app-netfleet.json": '{"new":true}\n',
        }
        for relative, content in files.items():
            path = payload / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
            path.chmod(0o755 if relative in {
                "usr/libexec/opl-netfleet/main.uc",
                "usr/libexec/opl-netfleet/supervisor.uc",
                "usr/libexec/rpcd/opl-netfleet",
                "etc/init.d/opl-netfleet",
            } else 0o644)

        with (self.bundle / "FILES.sha256").open("w") as stream:
            for path in sorted(item for item in payload.rglob("*") if item.is_file()):
                stream.write(f"{sha256(path)}  {path.relative_to(payload)}\n")
        with tarfile.open(self.bundle / "payload.tar", "w") as archive:
            for path in sorted(payload.rglob("*")):
                archive.add(path, arcname=path.relative_to(payload), recursive=False)
        shutil.copy2(REMOTE, self.bundle / "deploy-openwrt-remote.sh")
        (self.bundle / "rulesets.lock.json").write_text(ruleset_lock)
        manifest = {
            "schema": "opl-netfleet-deploy-bundle.v5",
            "source_commit": "a" * 40,
            "source_tree": "b" * 40,
            "policy_schema": 2,
            "file_count": len(files),
            "runtime_payload_sha256": "f" * 64,
            "release_mode": "source",
            "release_format": "source",
            "instance": False,
            "activation_qualified": True,
            "qualification_sha256": "e" * 64,
            "rulesets_lock_sha256": sha256(self.bundle / "rulesets.lock.json"),
        }
        (self.bundle / "bundle.json").write_text(json.dumps(manifest) + "\n")
        with (self.bundle / "SHA256SUMS").open("w") as stream:
            for name in ("FILES.sha256", "bundle.json", "deploy-openwrt-remote.sh", "rulesets.lock.json", "payload.tar"):
                stream.write(f"{sha256(self.bundle / name)}  {name}\n")

    def _change_bundle_identity(self):
        manifest = json.loads((self.bundle / "bundle.json").read_text())
        manifest["source_commit"] = "c" * 40
        manifest["source_tree"] = "d" * 40
        (self.bundle / "bundle.json").write_text(json.dumps(manifest) + "\n")
        with (self.bundle / "SHA256SUMS").open("w") as stream:
            for name in ("FILES.sha256", "bundle.json", "deploy-openwrt-remote.sh", "rulesets.lock.json", "payload.tar"):
                stream.write(f"{sha256(self.bundle / name)}  {name}\n")

    def _change_presentation_payload(self):
        payload = self.base / "payload"
        (payload / "www/luci-static/resources/view/netfleet/overview.js").write_text(
            "updated-view\n"
        )
        (payload / "usr/share/rpcd/acl.d/luci-app-netfleet.json").write_text(
            '{"presentation":true}\n'
        )
        with (self.bundle / "FILES.sha256").open("w") as stream:
            for path in sorted(item for item in payload.rglob("*") if item.is_file()):
                stream.write(f"{sha256(path)}  {path.relative_to(payload)}\n")
        with tarfile.open(self.bundle / "payload.tar", "w") as archive:
            for path in sorted(payload.rglob("*")):
                archive.add(path, arcname=path.relative_to(payload), recursive=False)
        self._change_bundle_identity()

    def _make_instance_bundle(self):
        policy = self.bundle / "policy.json"
        policy.write_text(json.dumps({
            "schema_version": 2,
            "main": {"target": "fixture", "enabled": True},
            "policy_source": {"kind": "profile", "ref": "subscription:base"},
            "recovery_profile": {"ref": "subscription:base"},
        }) + "\n")
        policy.chmod(0o600)
        subscriptions = self.bundle / "subscriptions.json"
        subscriptions.write_text(json.dumps({
            "schema_version": 1,
            "subscriptions": [{
                "section": "base",
                "name": "Base Provider",
                "url": "https://subscription.invalid/secret",
                "user_agent": "mihomo",
            }],
        }) + "\n")
        subscriptions.chmod(0o600)
        mixin = self.bundle / "nikki-mixin.yaml"
        mixin.write_text("nikki-rules: []\n")
        mixin.chmod(0o600)
        platform = self.bundle / "platform.json"
        platform.write_text(json.dumps(platform_fixture(), sort_keys=True) + "\n")
        platform.chmod(0o600)
        manifest = json.loads((self.bundle / "bundle.json").read_text())
        manifest["schema"] = "opl-netfleet-deploy-bundle.v5"
        manifest["instance"] = True
        manifest["policy_sha256"] = sha256(policy)
        manifest["subscriptions_sha256"] = sha256(subscriptions)
        manifest["nikki_mixin_sha256"] = sha256(mixin)
        manifest["platform_sha256"] = sha256(platform)
        (self.bundle / "bundle.json").write_text(json.dumps(manifest) + "\n")
        with (self.bundle / "SHA256SUMS").open("w") as stream:
            for name in (
                "FILES.sha256", "bundle.json", "deploy-openwrt-remote.sh", "rulesets.lock.json", "payload.tar",
                "policy.json", "subscriptions.json", "nikki-mixin.yaml", "platform.json",
            ):
                stream.write(f"{sha256(self.bundle / name)}  {name}\n")

    def _make_bundle_policy_instance(self):
        self._make_instance_bundle()
        policy = self.bundle / "policy.json"
        value = json.loads(policy.read_text())
        value["policy_source"] = {"kind": "bundle", "ref": "bundle:base-v1"}
        policy.write_text(json.dumps(value) + "\n")
        source = self.base / "payload" / "etc/opl-netfleet/policy-sources/base-v1.json"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text('{"proxy-groups":[{"name":"Base","type":"select","proxies":["DIRECT"]}],"rules":["MATCH,Base"]}\n')
        with (self.bundle / "FILES.sha256").open("w") as stream:
            for path in sorted(item for item in (self.base / "payload").rglob("*") if item.is_file()):
                stream.write(f"{sha256(path)}  {path.relative_to(self.base / 'payload')}\n")
        with tarfile.open(self.bundle / "payload.tar", "w") as archive:
            for path in sorted((self.base / "payload").rglob("*")):
                archive.add(path, arcname=path.relative_to(self.base / "payload"), recursive=False)
        manifest = json.loads((self.bundle / "bundle.json").read_text())
        manifest["policy_sha256"] = sha256(policy)
        manifest["file_count"] = len((self.bundle / "FILES.sha256").read_text().splitlines())
        (self.bundle / "bundle.json").write_text(json.dumps(manifest) + "\n")
        with (self.bundle / "SHA256SUMS").open("w") as stream:
            for name in (
                "FILES.sha256", "bundle.json", "deploy-openwrt-remote.sh", "rulesets.lock.json", "payload.tar",
                "policy.json", "subscriptions.json", "nikki-mixin.yaml", "platform.json",
            ):
                stream.write(f"{sha256(self.bundle / name)}  {name}\n")

    def _make_package_bundle(self):
        payload = self.base / "payload"
        package_files = {
            "opl-netfleet": "opl-netfleet_0.4.3-r1.apk",
            "luci-app-netfleet": "luci-app-netfleet_0.4.3-r1.apk",
        }
        for name in package_files.values():
            (self.bundle / name).write_text(name + "\n")
        key = self.bundle / "opl-netfleet-apk.pem"
        key.write_text("fixture-key\n")
        (self.bundle / "packages.adb").write_bytes(b"fixture-feed-index\n")
        manifest = json.loads((self.bundle / "bundle.json").read_text())
        package_manifest = {
            "schema": "opl-netfleet-package-manifest.v2",
            "source_commit": manifest["source_commit"],
            "source_tree": manifest["source_tree"],
            "package_version": "0.4.3",
            "package_release": "1",
            "package_format": "apk",
            "package_arch": "noarch",
            "build_target_arch": "aarch64_generic",
            "policy_schema": 2,
            "runtime_payload_sha256": manifest["runtime_payload_sha256"],
            "files_manifest": {"name": "FILES.sha256", "sha256": sha256(self.bundle / "FILES.sha256")},
            "artifact_files": package_files,
            "artifacts": [
                {"package": name, "name": file, "sha256": sha256(self.bundle / file), "size": (self.bundle / file).stat().st_size}
                for name, file in package_files.items()
            ],
            "apk_public_key": {"name": key.name, "sha256": sha256(key)},
            "feed_index": {"name": "packages.adb", "sha256": sha256(self.bundle / "packages.adb")},
        }
        (self.bundle / "package-manifest.json").write_text(json.dumps(package_manifest) + "\n")
        manifest.update({"schema": "opl-netfleet-deploy-bundle.v5", "release_mode": "package", "release_format": "apk"})
        (self.bundle / "bundle.json").write_text(json.dumps(manifest) + "\n")
        with (self.bundle / "SHA256SUMS").open("w") as stream:
            for name in (
                "FILES.sha256", "bundle.json", "deploy-openwrt-remote.sh", "rulesets.lock.json",
                "package-manifest.json", *package_files.values(), key.name, "packages.adb",
            ):
                stream.write(f"{sha256(self.bundle / name)}  {name}\n")
        return payload

    def _make_fresh_device(self):
        for relative in (
            "usr/libexec/opl-netfleet",
            "usr/libexec/rpcd/opl-netfleet",
            "etc/init.d/opl-netfleet",
            "etc/opl-netfleet/policy.example.json",
            "etc/opl-netfleet/policy.json",
            "etc/opl-netfleet/installed.json",
            "etc/nikki/run/rulesets",
            "etc/nikki/profiles/opl-netfleet",
            "var/lib/opl-netfleet",
            "www/luci-static/resources/netfleet",
            "www/luci-static/resources/view/netfleet",
            "usr/share/luci/menu.d/luci-app-netfleet.json",
            "usr/share/rpcd/acl.d/luci-app-netfleet.json",
        ):
            path = self.device / relative
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink(missing_ok=True)
        uci_file = self.device / "etc/config/nikki"
        fresh_uci = platform_uci_fixture("")
        fresh_uci["config.enabled"] = "0"
        fresh_uci["mixin.mixin_file_content"] = "0"
        uci_file.write_text(json.dumps(fresh_uci, sort_keys=True) + "\n")
        (self.device / "etc/nikki/mixin.yaml").unlink(missing_ok=True)
        shutil.rmtree(self.device / "etc/nikki/subscriptions", ignore_errors=True)
        for name in ("supervisor-enabled", "supervisor-running", "prepared", "enabled-once", "rpcd-registered"):
            (self.state / name).unlink(missing_ok=True)

    def _run(
        self,
        *,
        fail_action: str | None = None,
        fail_rpcd_restart: bool = False,
        fail_supervisor_start: bool = False,
        fail_subscription: str | None = None,
        drop_ubus_on_failure: bool = False,
        reject_candidate_preflight: bool = False,
        proxy_runtime: bool = False,
        preserve_state: bool = True,
        presentation_only: bool = False,
        stage_only: bool = False,
        instance: bool = False,
        apk_arch: str = "aarch64",
    ):
        env = os.environ.copy()
        env.update({
            "PATH": f"{self.bin}:{env['PATH']}",
            "FAKE_STATE": str(self.state),
            "FAKE_UCI_FILE": str(self.device / "etc/config/nikki"),
            "FAKE_RULESET_SOURCE": str(self.state / "ruleset-source"),
            "OPL_NETFLEET_DEPLOY_ROOT": str(self.device),
            "OPL_NETFLEET_DEPLOY_TESTING": "1",
            "FAKE_PACKAGE_CANDIDATE": str(self.base / "payload"),
            "FAKE_APK_ARCH": apk_arch,
        })
        if fail_action:
            env["FAKE_FAIL_ACTION"] = fail_action
        if fail_rpcd_restart:
            env["FAKE_FAIL_RPCD_RESTART"] = "1"
        if fail_supervisor_start:
            env["FAKE_FAIL_SUPERVISOR_START_ONCE"] = "1"
        if fail_subscription:
            env["FAKE_FAIL_SUBSCRIPTION"] = fail_subscription
        if drop_ubus_on_failure:
            env["FAKE_DROP_UBUS_ON_FAILURE"] = "1"
        if reject_candidate_preflight:
            env["FAKE_REJECT_CANDIDATE_PREFLIGHT"] = "1"
        if proxy_runtime:
            env["FAKE_PROXY_RUNTIME"] = "1"
        mode = "--presentation-only" if presentation_only else ("--stage-only" if stage_only else (
            "--preserve-state" if preserve_state else "--leave-disabled"
        ))
        arguments = ["sh", str(REMOTE), "--bundle", str(self.bundle), mode]
        if instance:
            arguments.append("--instance")
        return subprocess.run(
            arguments,
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

    def _rewrite_bundle_manifest(self, **changes):
        manifest = json.loads((self.bundle / "bundle.json").read_text())
        manifest.update(changes)
        (self.bundle / "bundle.json").write_text(json.dumps(manifest) + "\n")
        names = [line.split(None, 1)[1].strip() for line in (self.bundle / "SHA256SUMS").read_text().splitlines()]
        with (self.bundle / "SHA256SUMS").open("w") as stream:
            for name in names:
                stream.write(f"{sha256(self.bundle / name)}  {name}\n")

    def _rewrite_package_manifest(self, **changes):
        manifest = json.loads((self.bundle / "package-manifest.json").read_text())
        manifest.update(changes)
        (self.bundle / "package-manifest.json").write_text(json.dumps(manifest) + "\n")
        self._rewrite_bundle_manifest()

    def _profile(self) -> str:
        return json.loads((self.device / "etc/config/nikki").read_text()).get("config.profile", "")

    def test_fresh_device_instance_install_finishes_active(self):
        self._make_fresh_device()
        self._make_instance_bundle()

        result = self._run(instance=True)

        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        receipt = json.loads(result.stdout)
        self.assertTrue(receipt["instance"])
        self.assertTrue(receipt["final_active"])
        self.assertEqual("file:OPL-NetFleet.json", self._profile())
        self.assertEqual("1", json.loads((self.device / "etc/config/nikki").read_text())["config.enabled"])
        self.assertTrue((self.device / "etc/opl-netfleet/policy.json").is_file())
        self.assertEqual(0o600, (self.device / "etc/opl-netfleet/policy.json").stat().st_mode & 0o777)
        self.assertTrue((self.device / "etc/nikki/subscriptions/base.yaml").is_file())
        self.assertEqual("1", json.loads((self.device / "etc/config/nikki").read_text())["mixin.mixin_file_content"])
        actions = (self.state / "actions").read_text().splitlines()
        self.assertLess(actions.index("prepare-recovery"), actions.index("compile"))
        self.assertLess(actions.index("compile"), actions.index("enable"))

        before = actions.copy()
        nikki_before = (self.state / "nikki-actions").read_text().splitlines()
        replay = self._run(instance=True)
        self.assertEqual(0, replay.returncode, replay.stderr + replay.stdout)
        self.assertEqual("already_installed", json.loads(replay.stdout)["state"])
        after = (self.state / "actions").read_text().splitlines()
        self.assertEqual(before.count("prepare-recovery"), after.count("prepare-recovery"))
        self.assertEqual(before.count("compile"), after.count("compile"))
        self.assertEqual(before.count("enable"), after.count("enable"))
        self.assertEqual(nikki_before, (self.state / "nikki-actions").read_text().splitlines())

    def test_instance_applies_platform_and_installs_locked_rulesets(self):
        self._make_fresh_device()
        self._make_instance_bundle()
        legacy_rulesets = self.device / "etc/opl-netfleet/rulesets"
        legacy_rulesets.mkdir(parents=True)
        (legacy_rulesets / "cn-domain.mrs").write_bytes(b"stale")
        uci_file = self.device / "etc/config/nikki"
        data = json.loads(uci_file.read_text())
        data.update({
            "mixin.api_listen": "[::]:9090",
            "mixin.allow_lan": "0",
            "mixin.dns_mode": "fake-ip",
            "mixin.fake_ip_cache": "1",
            "mixin.tun_enabled": "1",
            "proxy.tcp_mode": "redirect",
            "proxy.udp_mode": "tun",
            "@sniff[0].overwrite_destination": "1",
            "@sniff[1].overwrite_destination": "1",
            "@sniff[2].overwrite_destination": "1",
        })
        uci_file.write_text(json.dumps(data, sort_keys=True) + "\n")

        result = self._run(instance=True)

        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        effective = json.loads(uci_file.read_text())
        self.assertEqual("0.0.0.0:9090", effective["mixin.api_listen"])
        self.assertEqual("1", effective["mixin.allow_lan"])
        self.assertEqual("redir-host", effective["mixin.dns_mode"])
        self.assertEqual("0", effective["mixin.fake_ip_cache"])
        self.assertEqual("0", effective["mixin.tun_enabled"])
        self.assertEqual("tproxy", effective["proxy.tcp_mode"])
        self.assertEqual("tproxy", effective["proxy.udp_mode"])
        self.assertTrue(all(effective[f"@sniff[{index}].overwrite_destination"] == "0" for index in range(3)))
        for source in (self.state / "ruleset-source").glob("*.mrs"):
            self.assertEqual(sha256(source), sha256(self.device / "etc/nikki/run/rulesets" / source.name))
        self.assertFalse(legacy_rulesets.exists())

    def test_ruleset_download_failure_precedes_device_mutation(self):
        self._make_fresh_device()
        self._make_instance_bundle()
        (self.state / "ruleset-source/cn-ip.mrs").unlink()
        uci_before = (self.device / "etc/config/nikki").read_bytes()

        result = self._run(instance=True)

        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("ruleset_download_failed", receipt["error"])
        self.assertEqual("not_needed", receipt["rollback"])
        self.assertEqual(uci_before, (self.device / "etc/config/nikki").read_bytes())
        self.assertFalse((self.device / "etc/opl-netfleet/installed.json").exists())

    def test_rulesets_download_through_the_running_authenticated_mixed_proxy(self):
        self._make_instance_bundle()
        shutil.rmtree(self.device / "etc/nikki/run/rulesets", ignore_errors=True)

        result = self._run(instance=True, proxy_runtime=True)

        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        calls = [json.loads(line) for line in (self.state / "curl-args.jsonl").read_text().splitlines()]
        controller_calls = [args for args in calls if any("127.0.0.1:9090/configs" in arg for arg in args)]
        download_calls = [args for args in calls if "-o" in args]
        self.assertEqual(20, len(download_calls))
        self.assertEqual(20, len(controller_calls))
        for args in download_calls:
            self.assertEqual("http://127.0.0.1:7890", args[args.index("--proxy") + 1])
            self.assertEqual("fixture-user:fixture-password", args[args.index("--proxy-user") + 1])

    def test_platform_apply_failure_restores_original_uci_and_payload(self):
        self._make_fresh_device()
        self._make_instance_bundle()
        uci_file = self.device / "etc/config/nikki"
        data = json.loads(uci_file.read_text())
        del data["@sniff[2].protocol"]
        data["mixin.dns_mode"] = "fake-ip"
        uci_file.write_text(json.dumps(data, sort_keys=True) + "\n")
        uci_before = uci_file.read_bytes()

        result = self._run(instance=True)

        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("platform_config_failed", receipt["error"])
        self.assertEqual("restored_previous_bytes_native_profile", receipt["rollback"])
        self.assertEqual(uci_before, uci_file.read_bytes())
        self.assertFalse((self.device / "etc/opl-netfleet/installed.json").exists())

    def test_fresh_instance_accepts_a_packaged_policy_bundle_without_a_source_subscription(self):
        self._make_fresh_device()
        self._make_bundle_policy_instance()

        result = self._run(instance=True)

        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        self.assertEqual("file:OPL-NetFleet.json", self._profile())
        self.assertTrue((self.device / "etc/opl-netfleet/policy-sources/base-v1.json").is_file())
        actions = (self.state / "nikki-actions").read_text().splitlines()
        self.assertEqual(["update:base"], actions)

    def test_identical_instance_replay_removes_only_the_inert_nikki_default_placeholder(self):
        self._make_fresh_device()
        self._make_instance_bundle()
        first = self._run(instance=True)
        self.assertEqual(0, first.returncode, first.stderr + first.stdout)

        uci_file = self.device / "etc/config/nikki"
        data = json.loads(uci_file.read_text())
        data.update({
            "subscription": "subscription",
            "subscription.name": "default",
            "subscription.url": "https://example.invalid/unused",
            "subscription.user_agent": "clash",
            "subscription.prefer": "remote",
        })
        uci_file.write_text(json.dumps(data, sort_keys=True) + "\n")
        (self.state / "actions").write_text("")
        (self.state / "nikki-actions").write_text("")

        replay = self._run(instance=True)

        self.assertEqual(0, replay.returncode, replay.stderr + replay.stdout)
        self.assertEqual("already_installed", json.loads(replay.stdout)["state"])
        result = json.loads(uci_file.read_text())
        self.assertNotIn("subscription", result)
        self.assertFalse(any(key.startswith("subscription.") for key in result))
        self.assertEqual("file:OPL-NetFleet.json", self._profile())
        self.assertNotIn("disable", (self.state / "actions").read_text().splitlines())
        self.assertEqual([], (self.state / "nikki-actions").read_text().splitlines())

    def test_instance_replay_preserves_a_non_placeholder_subscription_section(self):
        self._make_fresh_device()
        self._make_instance_bundle()
        first = self._run(instance=True)
        self.assertEqual(0, first.returncode, first.stderr + first.stdout)

        uci_file = self.device / "etc/config/nikki"
        data = json.loads(uci_file.read_text())
        data.update({
            "subscription": "subscription",
            "subscription.name": "User managed",
            "subscription.user_agent": "clash",
        })
        uci_file.write_text(json.dumps(data, sort_keys=True) + "\n")

        replay = self._run(instance=True)

        self.assertEqual(0, replay.returncode, replay.stderr + replay.stdout)
        self.assertEqual("subscription", json.loads(uci_file.read_text())["subscription"])

    def test_package_release_installs_through_apk_and_keeps_the_owner_transaction(self):
        self._make_package_bundle()

        result = self._run()

        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        self.assertEqual(
            ["opl-netfleet_0.4.3-r1.apk luci-app-netfleet_0.4.3-r1.apk"],
            (self.state / "package-actions").read_text().splitlines(),
        )
        self.assertEqual("new-main\n", (self.device / "usr/libexec/opl-netfleet/main.uc").read_text())
        self.assertTrue((self.device / "etc/apk/keys/opl-netfleet-apk.pem").is_file())
        installed = json.loads((self.device / "etc/opl-netfleet/installed.json").read_text())
        self.assertEqual("package", installed["release_mode"])

    def test_legacy_aarch64_generic_package_accepts_aarch64_target(self):
        self._make_package_bundle()
        self._rewrite_package_manifest(
            package_version="0.4.0",
            package_arch="aarch64_generic",
            build_target_arch=None,
        )

        result = self._run(apk_arch="aarch64")

        self.assertEqual(0, result.returncode, result.stderr + result.stdout)

    def test_native_package_arch_mismatch_is_rejected_before_install(self):
        self._make_package_bundle()
        self._rewrite_package_manifest(
            package_version="0.4.0",
            package_arch="x86_64",
            build_target_arch=None,
        )

        result = self._run(apk_arch="aarch64")

        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("package_arch_mismatch", receipt["error"])
        self.assertEqual([], (self.state / "package-actions").read_text().splitlines())

    def test_fresh_device_default_stage_does_not_enable_netfleet(self):
        self._make_fresh_device()
        self._make_instance_bundle()

        result = self._run(instance=True, stage_only=True)

        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        receipt = json.loads(result.stdout)
        self.assertFalse(receipt["final_active"])
        self.assertEqual("subscription:base", self._profile())
        actions = (self.state / "actions").read_text().splitlines()
        self.assertIn("compile", actions)
        self.assertNotIn("enable", actions)

    def test_default_stage_rejects_active_target_before_mutation(self):
        profile_before = self._profile()
        main_before = (self.device / "usr/libexec/opl-netfleet/main.uc").read_bytes()

        result = self._run(stage_only=True)

        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("active_target_requires_explicit_mode", receipt["error"])
        self.assertEqual(profile_before, self._profile())
        self.assertEqual(main_before, (self.device / "usr/libexec/opl-netfleet/main.uc").read_bytes())
        self.assertEqual([], (self.state / "actions").read_text().splitlines())

    def test_activation_requires_qualified_bundle_before_mutation(self):
        self._rewrite_bundle_manifest(
            activation_qualified=False,
            qualification_sha256="",
        )
        profile_before = self._profile()

        result = self._run()

        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("activation_qualification_required", receipt["error"])
        self.assertEqual(profile_before, self._profile())
        self.assertEqual([], (self.state / "actions").read_text().splitlines())

    def test_payload_archive_cannot_write_outside_owned_paths(self):
        payload = self.base / "payload"
        extra = payload / "var/run/netfleet-should-not-install"
        extra.parent.mkdir(parents=True)
        extra.write_text("forbidden\n")
        with tarfile.open(self.bundle / "payload.tar", "w") as archive:
            for path in sorted(payload.rglob("*")):
                archive.add(path, arcname=path.relative_to(payload), recursive=False)
        self._rewrite_bundle_manifest()

        result = self._run()

        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        self.assertFalse((self.device / "var/run/netfleet-should-not-install").exists())

    def test_instance_upgrade_reads_preflight_from_the_installed_owner(self):
        self._make_instance_bundle()

        result = self._run(instance=True, reject_candidate_preflight=True)

        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        receipt = json.loads(result.stdout)
        self.assertTrue(receipt["previous_active"])
        self.assertTrue(receipt["final_active"])
        self.assertEqual("file:OPL-NetFleet.json", self._profile())

    def test_subscription_failure_restores_the_unconfigured_native_device(self):
        self._make_fresh_device()
        self._make_instance_bundle()
        original_uci = (self.device / "etc/config/nikki").read_bytes()

        result = self._run(instance=True, fail_subscription="base")

        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("instance_subscription_update_failed", receipt["error"])
        self.assertEqual("restored_previous_bytes_native_profile", receipt["rollback"])
        self.assertEqual(original_uci, (self.device / "etc/config/nikki").read_bytes())
        self.assertFalse((self.device / "etc/nikki/subscriptions/base.yaml").exists())
        self.assertFalse((self.device / "usr/libexec/opl-netfleet").exists())

    def test_missing_nikki_service_is_rejected_before_target_state_changes(self):
        self._make_fresh_device()
        self._make_instance_bundle()
        (self.device / "etc/init.d/nikki").unlink()
        original_uci = (self.device / "etc/config/nikki").read_bytes()

        result = self._run(instance=True)

        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("unsupported_target", receipt["error"])
        self.assertEqual("nikki_service", receipt["detail"])
        self.assertEqual(original_uci, (self.device / "etc/config/nikki").read_bytes())
        self.assertFalse((self.device / "usr/libexec/opl-netfleet").exists())

    def test_fresh_device_base_prepare_failure_preserves_original_native_state(self):
        self._make_fresh_device()
        self._make_instance_bundle()

        result = self._run(instance=True, fail_action="prepare-recovery")

        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("recovery_profile_prepare_failed", receipt["error"])
        self.assertEqual("recovery_profile_unhealthy", receipt["detail"])
        self.assertEqual("restored_previous_bytes_native_profile", receipt["rollback"])
        self.assertEqual("", self._profile())
        self.assertFalse((self.device / "usr/libexec/opl-netfleet").exists())
        self.assertFalse((self.device / "etc/opl-netfleet/policy.json").exists())

    def test_native_prepare_failure_requires_live_owner_readback_for_rollback(self):
        self._make_instance_bundle()
        data = json.loads((self.device / "etc/config/nikki").read_text())
        data["config.profile"] = "subscription:base"
        (self.device / "etc/config/nikki").write_text(json.dumps(data, sort_keys=True) + "\n")
        cache = self.device / "etc/nikki/subscriptions/base.yaml"
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text("proxies: []\nproxy-groups: []\nrules: []\n")

        result = self._run(instance=True, fail_action="prepare-recovery")

        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("recovery_profile_unhealthy", receipt["detail"])
        self.assertEqual("restored_previous_bytes_native_profile", receipt["rollback"])
        self.assertEqual("subscription:base", self._profile())

        failed = self._run(
            instance=True,
            fail_action="prepare-recovery",
            drop_ubus_on_failure=True,
        )

        self.assertNotEqual(0, failed.returncode)
        failed_receipt = json.loads(failed.stdout)
        self.assertEqual("recovery_profile_unhealthy", failed_receipt["detail"])
        self.assertEqual("original_native_profile_not_recoverable", failed_receipt["rollback"])

    def test_prepare_base_receipt_exposes_only_the_safe_exception_line(self):
        self._make_fresh_device()
        self._make_instance_bundle()

        result = self._run(instance=True, fail_action="prepare-recovery-unexpected")

        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("recovery_profile_prepare_failed", receipt["error"])
        self.assertEqual("unexpected_error_lines_321_97", receipt["detail"])
        self.assertNotIn("stacktrace", result.stdout)

    def test_fresh_device_enable_failure_restores_original_profile_and_bytes(self):
        self._make_fresh_device()
        self._make_instance_bundle()

        result = self._run(instance=True, fail_action="enable")

        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("enable_failed", receipt["error"])
        self.assertEqual("enable_failed", receipt["detail"])
        self.assertEqual("restored_previous_bytes_native_profile", receipt["rollback"])
        self.assertEqual("", self._profile())
        self.assertFalse((self.device / "usr/libexec/opl-netfleet").exists())
        self.assertFalse((self.device / "etc/opl-netfleet/policy.json").exists())

    def test_active_instance_update_failure_restores_old_bytes_and_native_profile(self):
        self._make_instance_bundle()
        original_policy = (self.device / "etc/opl-netfleet/policy.json").read_bytes()
        original_evidence = (self.device / "var/lib/opl-netfleet/evidence.json").read_bytes()

        result = self._run(instance=True, fail_action="enable")

        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("enable_failed", receipt["error"])
        self.assertEqual("enable_failed", receipt["detail"])
        self.assertEqual("restored_previous_bytes_native_profile", receipt["rollback"])
        self.assertEqual("subscription:base", self._profile())
        self.assertEqual("old-main\n", (self.device / "usr/libexec/opl-netfleet/main.uc").read_text())
        self.assertEqual(original_policy, (self.device / "etc/opl-netfleet/policy.json").read_bytes())
        self.assertEqual(original_evidence, (self.device / "var/lib/opl-netfleet/evidence.json").read_bytes())
        self.assertFalse((self.device / "etc/opl-netfleet/evidence.json").exists())
        self.assertFalse((self.device / "etc/nikki/subscriptions/base.yaml").exists())
        self.assertEqual(2, (self.state / "actions").read_text().splitlines().count("disable"))

    def test_active_instance_rollback_preserves_openwrt_var_symlink(self):
        self._make_instance_bundle()
        tmp_var = self.device / "tmp"
        tmp_var.mkdir(exist_ok=True)
        shutil.move(str(self.device / "var/lib"), str(tmp_var / "lib"))
        shutil.rmtree(self.device / "var")
        (self.device / "var").symlink_to("tmp", target_is_directory=True)
        original_events = (self.device / "var/lib/opl-netfleet/events.json").read_bytes()

        result = self._run(instance=True, fail_action="enable")

        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("restored_previous_bytes_native_profile", receipt["rollback"])
        self.assertTrue((self.device / "var").is_symlink())
        self.assertEqual(Path("tmp"), (self.device / "var").readlink())
        self.assertEqual(original_events, (self.device / "var/lib/opl-netfleet/events.json").read_bytes())

    def test_active_upgrade_and_idempotent_replay(self):
        first = self._run()
        self.assertEqual(0, first.returncode, first.stderr + first.stdout)
        receipt = json.loads(first.stdout)
        self.assertEqual("installed", receipt["state"])
        self.assertTrue(receipt["final_active"])
        self.assertEqual("new-main\n", (self.device / "usr/libexec/opl-netfleet/main.uc").read_text())
        self.assertEqual("new-view\n", (self.device / "www/luci-static/resources/view/netfleet/overview.js").read_text())
        self.assertEqual("new-native\n", (self.device / "www/luci-static/resources/netfleet/native.css").read_text())
        self.assertFalse((self.device / "www/luci-static/resources/netfleet/ui").exists())
        self.assertFalse((self.device / "www/luci-static/resources/view/netfleet/log.js").exists())
        self.assertEqual('{"schema_version":1,"events":[]}\n', (self.device / "var/lib/opl-netfleet/events.json").read_text())
        self.assertFalse((self.device / "var/lib/opl-netfleet/evidence.json").exists())
        self.assertEqual('{"old":true}\n', (self.device / "etc/opl-netfleet/evidence.json").read_text())
        self.assertEqual("300", json.loads((self.device / "etc/config/rpcd").read_text())["@rpcd[0].timeout"])
        self.assertEqual("file:OPL-NetFleet.json", self._profile())
        self.assertEqual(["restart"], (self.state / "rpcd-actions").read_text().splitlines())
        before = (self.state / "actions").read_text().splitlines()
        self.assertEqual(2, before.count("probe"))

        second = self._run()
        self.assertEqual(0, second.returncode, second.stderr + second.stdout)
        self.assertEqual("already_installed", json.loads(second.stdout)["state"])
        after = (self.state / "actions").read_text().splitlines()
        self.assertEqual(before.count("disable"), after.count("disable"))
        self.assertEqual(before.count("enable"), after.count("enable"))
        self.assertEqual(["restart"], (self.state / "rpcd-actions").read_text().splitlines())

    def test_higher_rpcd_timeout_is_preserved_while_changed_menu_reloads(self):
        rpcd = self.device / "etc/config/rpcd"
        rpcd.write_text(json.dumps({"@rpcd[0].timeout": "360"}) + "\n")

        result = self._run()

        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        self.assertEqual("360", json.loads(rpcd.read_text())["@rpcd[0].timeout"])
        self.assertEqual(["restart"], (self.state / "rpcd-actions").read_text().splitlines())

    def test_same_version_reloads_rpcd_when_config_methods_are_missing(self):
        first = self._run()
        self.assertEqual(0, first.returncode, first.stderr + first.stdout)
        before = (self.state / "actions").read_text().splitlines()
        (self.state / "rpcd-legacy").write_text("1\n")

        second = self._run()
        self.assertEqual(0, second.returncode, second.stderr + second.stdout)
        self.assertEqual("already_installed", json.loads(second.stdout)["state"])
        after = (self.state / "actions").read_text().splitlines()
        self.assertEqual(before.count("disable"), after.count("disable"))
        self.assertEqual(before.count("enable"), after.count("enable"))
        self.assertEqual(["restart", "restart"], (self.state / "rpcd-actions").read_text().splitlines())

    def test_same_version_reloads_rpcd_when_luci_core_surface_is_missing(self):
        first = self._run()
        self.assertEqual(0, first.returncode, first.stderr + first.stdout)
        before = (self.state / "actions").read_text().splitlines()
        (self.state / "luci-missing").write_text("1\n")

        second = self._run()
        self.assertEqual(0, second.returncode, second.stderr + second.stdout)
        self.assertEqual("already_installed", json.loads(second.stdout)["state"])
        after = (self.state / "actions").read_text().splitlines()
        for action in ("disable", "compile", "enable", "refresh"):
            self.assertEqual(before.count(action), after.count(action))
        self.assertEqual(["restart", "restart"], (self.state / "rpcd-actions").read_text().splitlines())

    def test_same_version_repairs_stale_luci_http_bridge_without_data_plane_cycle(self):
        first = self._run()
        self.assertEqual(0, first.returncode, first.stderr + first.stdout)
        before = (self.state / "actions").read_text().splitlines()
        rpcd_before = (self.state / "rpcd-actions").read_text().splitlines()
        uhttpd_before = (self.state / "uhttpd-actions").read_text().splitlines()
        (self.state / "uhttpd-stale").write_text("1\n")

        second = self._run()

        self.assertEqual(0, second.returncode, second.stderr + second.stdout)
        self.assertEqual("already_installed", json.loads(second.stdout)["state"])
        after = (self.state / "actions").read_text().splitlines()
        for action in ("disable", "compile", "enable", "refresh"):
            self.assertEqual(before.count(action), after.count(action))
        self.assertEqual(rpcd_before, (self.state / "rpcd-actions").read_text().splitlines())
        self.assertEqual(
            uhttpd_before + ["restart"],
            (self.state / "uhttpd-actions").read_text().splitlines(),
        )
        self.assertFalse((self.state / "uhttpd-stale").exists())

    def test_equivalent_payload_reconciles_identity_without_data_plane_cycle(self):
        first = self._run()
        self.assertEqual(0, first.returncode, first.stderr + first.stdout)
        before = (self.state / "actions").read_text().splitlines()
        self._change_bundle_identity()

        second = self._run()
        self.assertEqual(0, second.returncode, second.stderr + second.stdout)
        receipt = json.loads(second.stdout)
        self.assertEqual("payload_reconciled", receipt["state"])
        self.assertEqual("c" * 40, receipt["source_commit"])
        after = (self.state / "actions").read_text().splitlines()
        self.assertEqual(before.count("disable"), after.count("disable"))
        self.assertEqual(before.count("enable"), after.count("enable"))
        installed = json.loads((self.device / "etc/opl-netfleet/installed.json").read_text())
        self.assertEqual("c" * 40, installed["source_commit"])

    def test_presentation_only_update_does_not_cycle_data_plane(self):
        self._make_instance_bundle()
        first = self._run(instance=True)
        self.assertEqual(0, first.returncode, first.stderr + first.stdout)
        before = (self.state / "actions").read_text().splitlines()
        self._change_presentation_payload()
        self._rewrite_bundle_manifest(activation_qualified=False, qualification_sha256="")

        second = self._run(presentation_only=True, instance=True)

        self.assertEqual(0, second.returncode, second.stderr + second.stdout)
        receipt = json.loads(second.stdout)
        self.assertEqual("presentation_updated", receipt["state"])
        self.assertTrue(receipt["final_active"])
        self.assertEqual(
            "updated-view\n",
            (self.device / "www/luci-static/resources/view/netfleet/overview.js").read_text(),
        )
        self.assertEqual(
            '{"presentation":true}\n',
            (self.device / "usr/share/rpcd/acl.d/luci-app-netfleet.json").read_text(),
        )
        after = (self.state / "actions").read_text().splitlines()
        self.assertEqual(before.count("disable"), after.count("disable"))
        self.assertEqual(before.count("compile"), after.count("compile"))
        self.assertEqual(before.count("enable"), after.count("enable"))
        installed = json.loads((self.device / "etc/opl-netfleet/installed.json").read_text())
        self.assertEqual("c" * 40, installed["source_commit"])

    def test_presentation_only_accepts_semantically_equal_policy_and_mixin(self):
        self._make_instance_bundle()
        first = self._run(instance=True)
        self.assertEqual(0, first.returncode, first.stderr + first.stdout)
        policy = self.device / "etc/opl-netfleet/policy.json"
        policy.write_text(json.dumps(json.loads(policy.read_text()), sort_keys=True, indent=2) + "\n")
        (self.device / "etc/nikki/mixin.yaml").write_text("nikki-rules: [ ]\n")
        before = (self.state / "actions").read_text().splitlines()
        self._change_presentation_payload()
        self._rewrite_bundle_manifest(activation_qualified=False, qualification_sha256="")

        second = self._run(presentation_only=True, instance=True)

        self.assertEqual(0, second.returncode, second.stderr + second.stdout)
        self.assertEqual("presentation_updated", json.loads(second.stdout)["state"])
        after = (self.state / "actions").read_text().splitlines()
        for action in ("disable", "compile", "enable"):
            self.assertEqual(before.count(action), after.count(action))

    def test_presentation_only_rejects_semantic_policy_mismatch(self):
        self._make_instance_bundle()
        first = self._run(instance=True)
        self.assertEqual(0, first.returncode, first.stderr + first.stdout)
        policy = self.device / "etc/opl-netfleet/policy.json"
        value = json.loads(policy.read_text())
        value["main"]["enabled"] = False
        policy.write_text(json.dumps(value, sort_keys=True) + "\n")
        self._change_presentation_payload()

        second = self._run(presentation_only=True, instance=True)

        self.assertNotEqual(0, second.returncode)
        self.assertEqual("presentation_only_precondition_failed", json.loads(second.stdout)["error"])

    def test_presentation_only_rejects_runtime_mismatch_before_mutation(self):
        self._make_instance_bundle()
        first = self._run(instance=True)
        self.assertEqual(0, first.returncode, first.stderr + first.stdout)
        main_before = (self.device / "usr/libexec/opl-netfleet/main.uc").read_bytes()
        identity_before = (self.device / "etc/opl-netfleet/installed.json").read_bytes()
        actions_before = (self.state / "actions").read_text().splitlines()
        self._rewrite_bundle_manifest(
            source_commit="c" * 40,
            source_tree="d" * 40,
            runtime_payload_sha256="0" * 64,
            activation_qualified=False,
            qualification_sha256="",
        )

        second = self._run(presentation_only=True, instance=True)

        self.assertNotEqual(0, second.returncode)
        receipt = json.loads(second.stdout)
        self.assertEqual("presentation_only_precondition_failed", receipt["error"])
        self.assertEqual(main_before, (self.device / "usr/libexec/opl-netfleet/main.uc").read_bytes())
        self.assertEqual(identity_before, (self.device / "etc/opl-netfleet/installed.json").read_bytes())
        actions_after = (self.state / "actions").read_text().splitlines()
        for action in ("disable", "compile", "enable"):
            self.assertEqual(actions_before.count(action), actions_after.count(action))

    def test_equivalent_payload_supervisor_failure_keeps_identity_and_service_state(self):
        first = self._run()
        self.assertEqual(0, first.returncode, first.stderr + first.stdout)
        installed_before = (self.device / "etc/opl-netfleet/installed.json").read_bytes()
        self._change_bundle_identity()
        (self.state / "supervisor-enabled").unlink()
        (self.state / "supervisor-running").unlink()

        second = self._run(fail_supervisor_start=True)
        self.assertNotEqual(0, second.returncode)
        receipt = json.loads(second.stdout)
        self.assertEqual("supervisor_start_failed", receipt["error"])
        self.assertEqual(installed_before, (self.device / "etc/opl-netfleet/installed.json").read_bytes())
        self.assertFalse((self.state / "supervisor-enabled").exists())
        self.assertFalse((self.state / "supervisor-running").exists())

    def test_active_artifact_repairs_unusable_control_plane_without_data_plane_cycle(self):
        (self.device / "usr/libexec/opl-netfleet/main.uc").chmod(0o644)
        before = (self.state / "actions").read_text().splitlines()

        result = self._run()
        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        receipt = json.loads(result.stdout)
        self.assertEqual("control_plane_repaired", receipt["state"])
        self.assertTrue(receipt["final_active"])
        after = (self.state / "actions").read_text().splitlines()
        self.assertEqual(before.count("disable"), after.count("disable"))
        self.assertEqual(before.count("compile"), after.count("compile"))
        self.assertEqual(before.count("enable"), after.count("enable"))
        self.assertEqual("file:opl-netfleet/mvp.json", self._profile())
        self.assertEqual("new-main\n", (self.device / "usr/libexec/opl-netfleet/main.uc").read_text())
        self.assertTrue(os.access(self.device / "usr/libexec/opl-netfleet/main.uc", os.X_OK))

    def test_failed_control_plane_repair_restores_absence_and_keeps_active_profile(self):
        shutil.rmtree(self.device / "usr/libexec/opl-netfleet")

        (self.state / "rpcd-stale").write_text("1\n")
        result = self._run(fail_rpcd_restart=True)
        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("rpcd_surface_unavailable", receipt["error"])
        self.assertEqual("restored_previous_control_plane_active_profile", receipt["rollback"])
        self.assertEqual("file:opl-netfleet/mvp.json", self._profile())
        self.assertFalse((self.device / "usr/libexec/opl-netfleet/main.uc").exists())

    def test_rpcd_restart_failure_restores_old_bytes_and_stays_native(self):
        (self.state / "rpcd-stale").write_text("1\n")
        result = self._run(fail_rpcd_restart=True)
        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("rpcd_surface_unavailable", receipt["error"])
        self.assertEqual("old-rpcd\n", (self.device / "usr/libexec/rpcd/opl-netfleet").read_text())
        self.assertEqual("30", json.loads((self.device / "etc/config/rpcd").read_text())["@rpcd[0].timeout"])
        self.assertEqual("subscription:base", self._profile())
        self.assertFalse((self.device / "etc/opl-netfleet/installed.json").exists())

    def test_same_version_leave_disabled_is_not_short_circuited(self):
        first = self._run()
        self.assertEqual(0, first.returncode, first.stderr + first.stdout)
        before = (self.state / "actions").read_text().splitlines()

        second = self._run(preserve_state=False)
        self.assertEqual(0, second.returncode, second.stderr + second.stdout)
        receipt = json.loads(second.stdout)
        self.assertEqual("installed", receipt["state"])
        self.assertFalse(receipt["final_active"])
        self.assertEqual("subscription:base", self._profile())
        after = (self.state / "actions").read_text().splitlines()
        self.assertEqual(before.count("disable") + 1, after.count("disable"))
        self.assertEqual(before.count("enable"), after.count("enable"))

    def test_disable_failure_never_overwrites_payload(self):
        result = self._run(fail_action="disable")
        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("disable_failed", receipt["error"])
        self.assertEqual("old-main\n", (self.device / "usr/libexec/opl-netfleet/main.uc").read_text())
        self.assertEqual("file:opl-netfleet/mvp.json", self._profile())
        self.assertFalse((self.device / "etc/opl-netfleet/installed.json").exists())

    def test_enable_failure_restores_old_bytes_and_stays_native(self):
        result = self._run(fail_action="enable")
        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("enable_failed", receipt["error"])
        self.assertEqual("enable_failed", receipt["detail"])
        self.assertEqual("restored_previous_bytes_native_profile", receipt["rollback"])
        self.assertEqual("old-main\n", (self.device / "usr/libexec/opl-netfleet/main.uc").read_text())
        self.assertEqual("subscription:base", self._profile())
        self.assertFalse((self.device / "etc/opl-netfleet/installed.json").exists())

    def test_compile_failure_reports_the_action_error_and_restores_native(self):
        result = self._run(fail_action="compile")

        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("compile_failed", receipt["error"])
        self.assertEqual("compile_failed", receipt["detail"])
        self.assertEqual("restored_previous_bytes_native_profile", receipt["rollback"])
        self.assertEqual("subscription:base", self._profile())

    def test_supervisor_start_failure_restores_bytes_service_and_identity(self):
        result = self._run(fail_supervisor_start=True)
        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("supervisor_start_failed", receipt["error"])
        self.assertEqual("restored_previous_bytes_native_profile", receipt["rollback"])
        self.assertEqual("old-main\n", (self.device / "usr/libexec/opl-netfleet/main.uc").read_text())
        self.assertEqual("subscription:base", self._profile())
        self.assertTrue((self.state / "supervisor-enabled").exists())
        self.assertTrue((self.state / "supervisor-running").exists())
        self.assertFalse((self.device / "etc/opl-netfleet/installed.json").exists())

    def test_native_probe_failure_restores_previous_active_path_without_install(self):
        (self.state / "fail-native-probe").write_text("1\n")
        result = self._run()
        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("native_baseline_probe_failed", receipt["error"])
        self.assertEqual("restored_previous_active_profile", receipt["rollback"])
        self.assertEqual("old-main\n", (self.device / "usr/libexec/opl-netfleet/main.uc").read_text())
        self.assertEqual("file:opl-netfleet/mvp.json", self._profile())
        actions = (self.state / "actions").read_text().splitlines()
        self.assertLess(actions.index("compile"), actions.index("enable"))

    def test_final_probe_failure_restores_old_bytes_and_stays_native(self):
        (self.state / "fail-final-probe").write_text("1\n")
        result = self._run()
        self.assertNotEqual(0, result.returncode)
        receipt = json.loads(result.stdout)
        self.assertEqual("protected_probe_failed_after_deploy", receipt["error"])
        self.assertEqual("restored_previous_bytes_native_profile", receipt["rollback"])
        self.assertEqual("old-main\n", (self.device / "usr/libexec/opl-netfleet/main.uc").read_text())
        self.assertEqual("subscription:base", self._profile())


if __name__ == "__main__":
    unittest.main()
