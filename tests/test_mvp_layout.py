from pathlib import Path
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).parents[1]
RUNTIME = ROOT / "openwrt" / "files" / "usr" / "libexec" / "opl-netfleet"
LUCI = ROOT / "openwrt" / "luci-app-netfleet"
PAYLOAD_SPEC = importlib.util.spec_from_file_location("netfleet_payload", ROOT / "openwrt/plugin_payload.py")
PAYLOAD = importlib.util.module_from_spec(PAYLOAD_SPEC)
PAYLOAD_SPEC.loader.exec_module(PAYLOAD)


class MvpLayoutTests(unittest.TestCase):
    def test_dynamic_ui_packages_require_the_composition_host(self):
        with tempfile.TemporaryDirectory(prefix="netfleet-host-compatibility-") as temporary:
            root = Path(temporary)
            (root / "include").mkdir()
            (root / "rules.mk").touch()
            (root / "include/package.mk").touch()
            for source, package, required in ((ROOT / "openwrt", "opl-netfleet", True),
                                              (ROOT / "openwrt", "opl-netfleet-plugin-product-ui", True),
                                              (ROOT / "openwrt", "opl-netfleet-plugin-models", False),
                                              (LUCI, "luci-app-netfleet", True)):
                harness = root / "metadata.mk"
                harness.write_text(f"$(info __BEGIN__)\n$(info $(Package/{package}))\n$(info __END__)\nall:;@:\n")
                result = subprocess.run([
                    "make", "--no-print-directory", "-f", str(source / "Makefile"), "-f", str(harness),
                    f"TOPDIR={root}", f"INCLUDE_DIR={root / 'include'}", "all",
                ], cwd=source, capture_output=True, text=True, check=True)
                definition = result.stdout.split("__BEGIN__\n", 1)[1].split("__END__", 1)[0]
                minimum = "0.8.8" if package in ("opl-netfleet-plugin-product-ui", "luci-app-netfleet") else "0.8.1"
                floor = f"EXTRA_DEPENDS:=opl-netfleet-kernel (>={minimum})"
                self.assertEqual(required, floor in definition, package)

    def test_platform_quota_adapter_requires_shared_quota_model(self):
        with tempfile.TemporaryDirectory(prefix="netfleet-quota-dependency-") as temporary:
            root = Path(temporary)
            (root / "include").mkdir()
            (root / "rules.mk").touch()
            (root / "include/package.mk").touch()
            harness = root / "metadata.mk"
            harness.write_text("$(info __BEGIN__)\n$(info $(Package/opl-netfleet-plugin-platform-openwrt))\n$(info __END__)\nall:;@:\n")
            result = subprocess.run(["make", "--no-print-directory", "-f", str(ROOT / "openwrt/Makefile"),
                                     "-f", str(harness), f"TOPDIR={root}", f"INCLUDE_DIR={root / 'include'}", "all"],
                                    cwd=ROOT / "openwrt", capture_output=True, text=True, check=True)
            self.assertIn("opl-netfleet-plugin-models (>=0.7.8)", result.stdout)

    def test_payload_revision_matches_runtime_directory_order_and_content(self):
        with tempfile.TemporaryDirectory(prefix="netfleet-payload-revision-") as temporary:
            root = Path(temporary)
            (root / "a").mkdir()
            (root / "a/leaf.txt").write_bytes(b"nested\n")
            (root / "a.txt").write_bytes(b"sibling\n")
            (root / "manifest.json").write_bytes(b'{}\n')
            identities = b"".join(
                f"{hashlib.sha256(content).hexdigest()}  {name}\n".encode("ascii")
                for name, content in (("a/leaf.txt", b"nested\n"), ("a.txt", b"sibling\n"),
                                      ("manifest.json", b'{}\n'))
            )
            revision = PAYLOAD.payload_revision(root)
            self.assertEqual(hashlib.sha256(identities).hexdigest(), revision)
            (root / "a.txt").chmod(0o755)
            self.assertEqual(revision, PAYLOAD.payload_revision(root))
            (root / "a/leaf.txt").write_bytes(b"updated\n")
            self.assertNotEqual(revision, PAYLOAD.payload_revision(root))
            (root / "a/link").symlink_to(root / "a.txt")
            with self.assertRaises(ValueError):
                PAYLOAD.payload_revision(root)

    def test_luci_shell_and_product_ui_install_as_separate_packages(self):
        with tempfile.TemporaryDirectory(prefix="netfleet-ui-layout-") as temporary:
            root = Path(temporary)
            (root / "include").mkdir()
            (root / "rules.mk").touch()
            (root / "include/package.mk").touch()
            stage = root / "stage"
            for source, package in ((ROOT / "openwrt", "opl-netfleet-plugin-product-ui"),
                                    (LUCI, "luci-app-netfleet")):
                harness = root / f"{package}.mk"
                harness.write_text(
                    "INSTALL_DIR:=mkdir -p\nINSTALL_DATA:=install -m 0644\nCP:=cp -R\n"
                    "all:\n\t$(call Package/" + package + "/install," + str(stage) + ")\n")
                subprocess.run([
                    "make", "--no-print-directory", "-f", str(source / "Makefile"),
                    "-f", str(harness), f"TOPDIR={root}", f"INCLUDE_DIR={root / 'include'}", "all",
                ], cwd=source, capture_output=True, text=True, check=True)
            public = stage / "www/luci-static/resources/netfleet"
            package_version = re.search(r"^PKG_VERSION:=(\S+)$", (LUCI / "Makefile").read_text(), re.M).group(1)
            shell_modules = public / f"v{package_version.replace('.', '_')}"
            self.assertEqual({"api.js", "plugin-host.js"}, {path.name for path in shell_modules.glob("*.js")})
            self.assertEqual([], list(public.glob("*.js")))
            product = RUNTIME / "plugins/product-ui/resources"
            revision = PAYLOAD.payload_revision(product.parent)
            installed_product = public / "plugins/product-ui" / revision / "resources"
            self.assertEqual({path.relative_to(product): path.read_bytes()
                              for path in product.rglob("*") if path.is_file()},
                             {path.relative_to(installed_product): path.read_bytes()
                              for path in installed_product.rglob("*") if path.is_file()})
            self.assertFalse((public / "plugins/product-ui/resources").exists())
            menu = json.loads((stage / "usr/share/luci/menu.d/luci-app-netfleet.json").read_text())
            view = menu["admin/services/netfleet/overview"]["action"]["path"]
            self.assertTrue((stage / f"www/luci-static/resources/view/{view}.js").is_file())
            self.assertFalse((stage / "www/luci-static/resources/view/netfleet/overview.js").exists())

    def test_kernel_package_installs_host_adapters(self):
        with tempfile.TemporaryDirectory(prefix="netfleet-kernel-layout-") as temporary:
            root = Path(temporary)
            (root / "include").mkdir()
            (root / "rules.mk").touch()
            (root / "include/package.mk").touch()
            harness = root / "install.mk"
            harness.write_text(
                "INSTALL_DIR:=mkdir -p\nINSTALL_BIN:=install -m 0755\nINSTALL_DATA:=install -m 0644\n"
                "all:\n\t$(call Package/opl-netfleet-kernel/install," + str(root / "stage") + ")\n")
            subprocess.run([
                "make", "--no-print-directory", "-f", str(ROOT / "openwrt/Makefile"),
                "-f", str(harness), f"TOPDIR={root}", f"INCLUDE_DIR={root / 'include'}", "all",
            ], cwd=ROOT / "openwrt", capture_output=True, text=True, check=True)
            installed = root / "stage/usr/libexec/opl-netfleet/adapters"
            expected = {path.name: path.read_bytes() for path in (RUNTIME / "adapters").glob("*.uc")}
            self.assertIn("openwrt.uc", expected)
            self.assertEqual(expected, {path.name: path.read_bytes() for path in installed.glob("*.uc")})
            self.assertEqual((ROOT / "openwrt/files/usr/libexec/rpcd/opl-netfleet.plugins").read_bytes(),
                             (root / "stage/usr/libexec/rpcd/opl-netfleet.plugins").read_bytes())

    def test_default_composition_preserves_lightweight_algorithm_installation(self):
        script = ROOT / "openwrt/plugin-packages.py"
        spec = importlib.util.spec_from_file_location("netfleet_package_composition", script)
        package_composition = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(package_composition)
        plugins, services, graph = package_composition.composition()

        def closure(identity):
            result = {identity}
            for required in graph[identity]:
                result.update(closure(required))
            return result

        algorithm = services["selection.algorithm"][0]
        self.assertEqual({"selection-algorithm", "models"}, closure(algorithm))
        self.assertFalse(any(plugins[name]["package_dependencies"] for name in closure(algorithm)))
        self.assertIn(algorithm, graph["selection"])
        self.assertEqual("platform-openwrt", services["platform.profile"][0])
        self.assertEqual("platform-storage", services["platform.storage"][0])
        self.assertFalse(plugins["platform"]["package_dependencies"])
        self.assertNotIn("platform-openwrt", closure("platform-storage"))

        system = json.loads(subprocess.check_output(["python3", str(script), "system"], text=True))
        checked_in = json.loads((ROOT / "openwrt/files/usr/share/opl-netfleet/system.json").read_text())
        self.assertEqual(checked_in, system)
        self.assertEqual(set(plugins), set(system["enabled"]))
        self.assertEqual({"opl-netfleet-kernel", *(plugin["package"] for identity, plugin in plugins.items() if identity not in package_composition.OPTIONAL_PLUGINS)},
                         set(system["product_packages"]))
        self.assertFalse(system["enabled"]["https-compat"])
        defaults = subprocess.check_output(["python3", str(script), "default-ids"], text=True).split()
        self.assertNotIn("https-compat", defaults)
        for identity in defaults:
            self.assertNotIn("https-compat", closure(identity))

    def test_default_package_installs_only_public_plugin_resources_to_web_root(self):
        with tempfile.TemporaryDirectory(prefix="netfleet-package-layout-") as temporary:
            root = Path(temporary)
            (root / "include").mkdir()
            (root / "rules.mk").touch()
            (root / "include/package.mk").touch()
            for name in ("Makefile", "plugin-packages.py", "plugin_payload.py"):
                shutil.copyfile(ROOT / "openwrt" / name, root / name)
            plugin = root / "files/usr/libexec/opl-netfleet/plugins/layout-test"
            (plugin / "lib").mkdir(parents=True)
            (plugin / "config").mkdir()
            (plugin / "resources/nested").mkdir(parents=True)
            (plugin / "manifest.json").write_text(json.dumps({
                "schema": "opl-netfleet-service-plugin.v1", "id": "layout-test",
                "package": "opl-netfleet-plugin-layout-test", "version": "1.0.0",
                "label": "Package layout fixture", "api_version": 1,
                "services": {"layout-test.reader": {
                    "version": 1, "module": "lib/private.uc", "requires": {},
                }}, "commands": {}, "package_dependencies": [],
            }))
            (plugin / "lib/private.uc").write_text("return function(context) { return {}; };\n")
            (plugin / "config/private.json").write_text('{"private":true}\n')
            (plugin / "resources/page.js").write_text('export default {};\n')
            (plugin / "resources/nested/page.css").write_text('body { color: black; }\n')
            harness = root / "install.mk"
            harness.write_text(
                "INSTALL_DIR:=mkdir -p\nCP:=cp -R\n"
                "all:\n\t$(call Package/opl-netfleet-plugin-layout-test/install," + str(root / "stage") + ")\n")
            subprocess.run([
                "make", "--no-print-directory", "-f", str(root / "Makefile"),
                "-f", str(harness), f"TOPDIR={root}", f"INCLUDE_DIR={root / 'include'}", "all",
            ], cwd=root, capture_output=True, text=True, check=True)
            runtime = root / "stage/usr/libexec/opl-netfleet/plugins/layout-test"
            plugin_public = root / "stage/www/luci-static/resources/netfleet/plugins/layout-test"
            public = plugin_public / PAYLOAD.payload_revision(runtime)
            self.assertTrue((runtime / "lib/private.uc").is_file())
            self.assertTrue((runtime / "config/private.json").is_file())
            self.assertEqual({Path("resources/page.js"), Path("resources/nested/page.css")}, {
                path.relative_to(public) for path in public.rglob("*") if path.is_file()
            })
            self.assertEqual((plugin / "resources/page.js").read_bytes(),
                             (public / "resources/page.js").read_bytes())
            self.assertFalse((plugin_public / "resources").exists())

    def test_required_runtime_surfaces_exist_without_a_second_worker(self):
        required = (
            RUNTIME / "main.uc",
            RUNTIME / "supervisor.uc",
            RUNTIME / "kernel" / "host.uc",
            RUNTIME / "kernel" / "schema.uc",
            RUNTIME / "kernel" / "io.uc",
            RUNTIME / "kernel" / "process.uc",
            ROOT / "openwrt/files/usr/share/opl-netfleet/system.json",
            ROOT / "openwrt" / "files" / "etc" / "init.d" / "opl-netfleet",
        )
        self.assertTrue(all(path.is_file() for path in required))
        system = json.loads((ROOT / "openwrt/files/usr/share/opl-netfleet/system.json").read_text())
        for service, plugin in system["bindings"].items():
            manifest = json.loads((RUNTIME / "plugins" / plugin / "manifest.json").read_text())
            self.assertIn(service, manifest["services"])
            self.assertTrue((RUNTIME / "plugins" / plugin / manifest["services"][service]["module"]).is_file())

        package_files = [
            path for path in (ROOT / "openwrt" / "files").rglob("*") if path.is_file()
        ]
        supervisors = [
            path
            for path in package_files
            if path.name == "opl-netfleet" and "/init.d/" in str(path)
        ]
        self.assertEqual(
            [ROOT / "openwrt" / "files" / "etc" / "init.d" / "opl-netfleet"],
            supervisors,
        )
        self.assertFalse(
            any("worker" in path.name or "projection" in path.name for path in package_files)
        )

        makefile = (ROOT / "openwrt" / "Makefile").read_text()
        self.assertIn("$(INSTALL_DIR) $(1)/usr/libexec/opl-netfleet/kernel", makefile)
        self.assertIn(
            "./files/usr/libexec/opl-netfleet/kernel/*.uc $(1)/usr/libexec/opl-netfleet/kernel/",
            makefile,
        )

    def test_shell_entrypoints_parse_and_expose_current_deployment_modes(self):
        scripts = sorted((ROOT / "scripts").rglob("*.sh"))
        for script in scripts:
            result = subprocess.run(
                ["bash", "-n", str(script)], text=True, capture_output=True, check=False
            )
            self.assertEqual(0, result.returncode, f"{script}: {result.stderr}")

        host = ROOT / "scripts" / "deploy-openwrt.sh"
        result = subprocess.run(
            [str(host), "--help"], text=True, capture_output=True, check=False
        )
        self.assertEqual(0, result.returncode, result.stderr)
        for option in (
            "--ref",
            "--packages",
            "--release",
            "--instance",
            "--leave-disabled",
            "--activate",
            "--presentation-only",
            "--qualification",
            "--dry-run",
        ):
            self.assertIn(option, result.stdout)

        deployment_source = host.read_text() + (
            ROOT / "scripts" / "deploy-openwrt-remote.sh"
        ).read_text()
        self.assertIn("OPL_NETFLEET_DEPLOY_LOCKED=1", deployment_source)
        self.assertRegex(deployment_source, r'sh "\$0" "\$@" (?:8>&- )?9>&-')
        for private_literal in ("192.168.",):
            self.assertNotIn(private_literal, deployment_source)

    def test_runtime_core_has_no_provider_or_business_literals(self):
        forbidden = ("192.168.", "provider.example.invalid")
        sources = list((RUNTIME / "plugins/models/lib").glob("*.uc"))
        self.assertTrue(sources)
        for source in sources:
            text = source.read_text()
            self.assertFalse(any(value in text for value in forbidden), source)

    def test_policy_bundle_and_ruleset_lock_are_structurally_consistent(self):
        config_root = ROOT / "openwrt" / "files" / "etc" / "opl-netfleet"
        policy = json.loads((config_root / "policy.example.json").read_text())
        baseline = json.loads((config_root / "policy-sources" / "base-v1.json").read_text())
        lock = json.loads((config_root / "rulesets.lock.json").read_text())

        self.assertEqual(2, policy["schema_version"])
        self.assertEqual(
            {"kind": "bundle", "ref": "bundle:base-v1"}, policy["policy_source"]
        )
        self.assertNotEqual(policy["policy_source"]["ref"], policy["recovery_profile"]["ref"])

        enabled = {
            name for name, provider in policy["providers"].items() if provider["enabled"]
        }
        self.assertTrue(enabled)
        self.assertTrue(
            {policy["providers"][name]["role"] for name in enabled}.issuperset(
                {"primary", "reserve"}
            )
        )
        self.assertTrue(enabled.issubset(policy["provider_regions"]))

        probe_ids = {probe["id"] for probe in policy["fail_open"]["probes"]}
        healthcheck = policy["fail_open"]["healthcheck"]
        self.assertIn(healthcheck["path_probe_id"], probe_ids)
        self.assertIn(healthcheck["guard_probe_id"], probe_ids)

        for platform_field in (
            "proxies",
            "proxy-providers",
            "mode",
            "ipv6",
            "allow-lan",
            "external-controller",
            "log-level",
        ):
            self.assertNotIn(platform_field, baseline)

        self.assertNotIn("dns", baseline)

        provider_ids = set(baseline["rule-providers"])
        self.assertEqual(provider_ids, {entry["id"] for entry in lock["rulesets"]})
        self.assertTrue(
            all(
                provider["path"] == f"./rulesets/{name}.mrs"
                for name, provider in baseline["rule-providers"].items()
            )
        )
        group_names = {group["name"] for group in baseline["proxy-groups"]}
        self.assertTrue(set(policy["bindings"]).issubset(group_names))

        game_defaults = {
            "Steam": "DIRECT",
            "Xbox": "DIRECT",
            "PlayStation": "DIRECT",
            "Nintendo Switch": "海外加速",
        }
        groups = {group["name"]: group for group in baseline["proxy-groups"]}
        for name, default in game_defaults.items():
            self.assertEqual(default, groups[name]["proxies"][0])
            self.assertTrue(any(rule.endswith(f",{name}") for rule in baseline["rules"]))
        self.assertTrue({"苹果服务", "国内媒体"}.issubset(policy["bindings"]))
        for name in ("苹果服务", "国内媒体"):
            self.assertEqual("standard", policy["bindings"][name]["capability"])
            self.assertEqual("policy", policy["bindings"][name]["kind"])
        self.assertNotIn("下载", policy["bindings"])
        self.assertNotIn("下载", groups)
        self.assertNotIn("Global", groups)

        tailscale_direct_rules = [
            "DOMAIN-SUFFIX,tailscale.com,DIRECT",
            "DOMAIN-SUFFIX,tailscale.io,DIRECT",
            "SRC-PORT,41641,DIRECT",
            "DST-PORT,41641,DIRECT",
            "DST-PORT,3478,DIRECT",
        ]
        self.assertEqual(tailscale_direct_rules, baseline["rules"][:5])

        ordered_rules = [
            "RULE-SET,private-domain,DIRECT",
            "RULE-SET,ai-domain,AI 出口",
            "RULE-SET,netflix-domain,Netflix",
            "RULE-SET,youtube-domain,YouTube",
            "RULE-SET,telegram-domain,Telegram",
            "RULE-SET,social-domain,社交媒体",
            "RULE-SET,steam-domain,Steam",
            "RULE-SET,xbox-domain,Xbox",
            "RULE-SET,playstation-domain,PlayStation",
            "RULE-SET,nintendo-domain,Nintendo Switch",
            "RULE-SET,microsoft-domain,微软服务",
            "RULE-SET,apple-domain,苹果服务",
            "RULE-SET,google-domain,谷歌服务",
            "RULE-SET,domestic-media-domain,国内媒体",
            "RULE-SET,cn-domain,DIRECT",
            "RULE-SET,geolocation-non-cn,海外加速",
            "MATCH,海外加速",
        ]
        self.assertEqual(
            sorted(baseline["rules"].index(rule) for rule in ordered_rules),
            [baseline["rules"].index(rule) for rule in ordered_rules],
        )
        self.assertLess(
            baseline["rules"].index("DST-PORT,3478,DIRECT"),
            baseline["rules"].index("RULE-SET,geolocation-non-cn,海外加速"),
        )

    def test_yaml_adapter_is_read_only(self):
        source = "\n".join(path.read_text() for path in RUNTIME.rglob("*.uc"))
        self.assertNotIn("yq -i", source)
        self.assertNotIn("eval-all", source)
        self.assertNotIn("yq -M -P -o yaml", source)
        self.assertIn("yq -M -p yaml -o json", source)

    def test_runtime_fail_open_health_and_lock_contract(self):
        policy = (RUNTIME / "plugins/models/lib/policy.uc").read_text()
        activation = (RUNTIME / "plugins/activation/lib/control.uc").read_text()
        compilation = (RUNTIME / "plugins/compilation/lib/control.uc").read_text()
        supervisor = (RUNTIME / "plugins/scheduler/lib/control.uc").read_text()
        supervisor_entry = (RUNTIME / "supervisor.uc").read_text()
        host = (RUNTIME / "kernel/host.uc").read_text()
        nikki = (RUNTIME / "plugins/mihomo/lib/backend.uc").read_text()
        runtime_makefile = (ROOT / "openwrt" / "Makefile").read_text()
        rpcd = (
            ROOT / "openwrt" / "files" / "usr" / "libexec" / "rpcd" / "opl-netfleet"
        ).read_text()
        api = (RUNTIME / "plugins/product-ui/resources/api.js").read_text()
        overview = (RUNTIME / "plugins/product-ui/resources/product-pages.js").read_text()

        self.assertIn("startup_grace_seconds: configured.startup_grace_seconds ?? 120", policy)
        self.assertIn("runtime_grace_seconds: configured.runtime_grace_seconds ?? 45", policy)
        self.assertIn("automation_config(policy).startup_grace_seconds", activation)
        self.assertIn('"dns_ingress_unavailable"', supervisor)
        self.assertIn("lan_runtime?.dns_ready == true", supervisor)
        self.assertIn('if (run_owner("recover", reason)) unhealthy_since = null', supervisor)
        self.assertIn("options.adapter.network_lock(options.network_lock, true)", host)
        self.assertNotIn("flock -n", supervisor)
        self.assertIn("result(30000)", supervisor)
        self.assertIn("result(config.poll_interval_seconds * 1000)", supervisor)
        self.assertIn("sleep(delay)", supervisor_entry)
        self.assertNotIn('system("sleep ', supervisor)
        self.assertIn("lan_runtime_state = function(dns_probe_url)", nikki)
        self.assertIn("dns_hijack_rule_present", nikki)
        self.assertIn('nslookup ${shell_quote(hostname)} 127.0.0.1', nikki)
        self.assertIn('(sleep 5; kill "$probe" 2>/dev/null) >/dev/null 2>&1 & watchdog=$!', nikki)
        self.assertNotIn("timeout 5 nslookup", nikki)
        self.assertIn('ucode "$main" enable luci 9>&-', rpcd)
        self.assertIn('ucode "$main" disable luci 9>&-', rpcd)
        self.assertIn('"onboarding_get":{}', rpcd)
        self.assertIn('"onboarding_apply":{"request":{}}', rpcd)
        self.assertIn('"probe":{}', rpcd)
        self.assertIn('config_request onboarding-apply 1', rpcd)
        self.assertIn('respond_owner ucode "$main" onboarding-get', rpcd)
        self.assertIn('respond_owner ucode "$main" probe', rpcd)
        self.assertIn('respond_owner ucode "$main" enable luci 9>&-', rpcd)
        self.assertIn('"owner_no_response"', rpcd)
        self.assertNotIn("exit 1", rpcd)
        self.assertIn('ucode "$$main" package-cleanup', runtime_makefile)
        self.assertNotIn('[ "$$1" = "remove" ]', runtime_makefile)
        commands = json.loads((RUNTIME / "plugins/compilation/manifest.json").read_text())["commands"]
        self.assertEqual("command_package_cleanup", commands["package-cleanup"]["method"])
        self.assertIn('remove_artifact()', compilation)
        self.assertIn('"provider_link_cleanup_failed"', compilation)
        self.assertIn('context.use("subscriptions.providers").load', compilation)
        self.assertNotIn("function load_provider_profiles", compilation)
        self.assertIn("return removed", (RUNTIME / "plugins/mihomo/lib/profile-storage.uc").read_text())
        for method in ("enable", "refresh", "selectAuto", "configApply", "onboardingApply"):
            self.assertRegex(api, rf"{method}: function\([^)]*\)\s*\{{\s*return withRpcTimeout\(300")
        self.assertNotIn("withRpcTimeout(120", api)
        self.assertNotIn("withRpcTimeout(90", api)
        self.assertIn("annotateRpcError", api)
        self.assertIn("request_aborted", api)
        self.assertIn("浏览器连接已中止", overview)

    def test_reference_ui_and_native_luci_remain_separate_surfaces(self):
        self.assertTrue((ROOT / "ui" / "package.json").is_file())
        self.assertTrue(
            (
                LUCI
                / "htdocs"
                / "luci-static"
                / "resources"
                / "view"
                / "netfleet"
                / "overview.js"
            ).is_file()
        )
        self.assertTrue((RUNTIME / "plugins/product-ui/resources/config.js").is_file())
        package_makefiles = (ROOT / "openwrt" / "Makefile").read_text() + (
            LUCI / "Makefile"
        ).read_text()
        self.assertNotIn("ui/src", package_makefiles)
        self.assertNotIn("vite", package_makefiles.lower())
        self.assertNotIn("react", package_makefiles.lower())

        menu = json.loads(
            (LUCI / "root" / "usr" / "share" / "luci" / "menu.d" / "luci-app-netfleet.json").read_text()
        )
        version = re.search(r"^PKG_VERSION:=(\S+)$", (LUCI / "Makefile").read_text(), re.M).group(1)
        self.assertEqual(
            f"netfleet/overview-v{version.replace('.', '_')}",
            menu["admin/services/netfleet/overview"]["action"]["path"],
        )
        acl = json.loads(
            (LUCI / "root" / "usr" / "share" / "rpcd" / "acl.d" / "luci-app-netfleet.json").read_text()
        )
        self.assertNotIn("luci.nikki", acl["luci-app-netfleet"]["read"]["ubus"])
        self.assertIn("dashboard_get", acl["luci-app-netfleet"]["read"]["ubus"]["opl-netfleet"])
        self.assertIn(
            "probe",
            acl["luci-app-netfleet"]["read"]["ubus"]["opl-netfleet"],
        )

        native_style = (RUNTIME / "plugins/product-ui/resources/native.css").read_text()
        pagination_rule = re.search(
            r"\.netfleet-native\s+\.netfleet-event-pagination\s*\{([^}]*)\}",
            native_style,
        )
        self.assertIsNotNone(pagination_rule)
        self.assertRegex(pagination_rule.group(1), r"padding-right:\s*16px")
        self.assertRegex(pagination_rule.group(1), r"padding-left:\s*16px")
        self.assertIn(
            "--nf-accent: var(--primary, var(--primary-color-high, #5e72e4))",
            native_style,
        )
        self.assertIn("background: var(--nf-accent-soft)", native_style)
        self.assertRegex(native_style, r"\.netfleet-native \.netfleet-business-list\s*\{[^}]*grid-template-columns:\s*repeat\(4,", re.S)
        self.assertNotIn(".netfleet-native .netfleet-exit-card", native_style)
        self.assertRegex(native_style, r"\.netfleet-native > h2\s*\{[^}]*padding:\s*0 !important", re.S)
        self.assertRegex(native_style, r"\.netfleet-native \.cbi-section > h3\s*\{[^}]*padding:\s*0 !important", re.S)
        self.assertRegex(native_style, r"\.netfleet-native \.cbi-section-descr\s*\{[^}]*padding:\s*0 !important", re.S)
        self.assertRegex(native_style, r"\.netfleet-native \.netfleet-exit-heading h3,[^}]*padding:\s*0 !important", re.S)
        self.assertRegex(native_style, r"\.netfleet-native \.netfleet-business-routing h4\s*\{[^}]*padding:\s*0 !important", re.S)
        self.assertRegex(native_style, r"\.netfleet-native \.cbi-tabmenu > li\s*\{[^}]*background:\s*transparent !important", re.S)
        self.assertRegex(native_style, r"\.netfleet-native \.netfleet-inline-link\s*\{[^}]*background:\s*transparent !important", re.S)
        self.assertNotIn("#6f9966", native_style)
        self.assertNotIn("rgba(90, 132, 84", native_style)

        reference_style = (ROOT / "ui" / "src" / "styles.css").read_text()
        self.assertIn(
            ".nf-app .is-ok { color: var(--nf-accent) !important; }",
            reference_style,
        )
        self.assertIn(
            ".nf-environment-grid .is-ok { color: var(--nf-green) !important; }",
            reference_style,
        )

    def test_native_luci_uses_display_cache_then_revalidates_once(self):
        overview = RUNTIME / "plugins/product-ui/resources/product-pages.js"
        harness = r"""
const assert = require('assert');
const fs = require('fs');
const source = fs.readFileSync(process.argv[1], 'utf8').split('return baseclass.extend({\n\tmount:')[0] + '\nreturn productController;';

function E(tag, attrs, children) {
    const node = {
        tag: tag,
        attrs: attrs || {},
        children: Array.isArray(children) ? children : children == null ? [] : [ children ],
		replaceChildren: function() { this.children = Array.from(arguments); },
		getAttribute: function(name) { return this.attrs[name] == null ? null : this.attrs[name]; },
		setAttribute: function(name, value) { this.attrs[name] = String(value); },
		addEventListener: function(name, callback) { this.attrs[name] = callback; },
		focus: function() { this.focused = true; }
    };
    node.classList = {
        add: name => { node.attrs.class = [...new Set(String(node.attrs.class || '').split(' ').concat(name))].join(' '); },
        remove: name => { node.attrs.class = String(node.attrs.class || '').split(' ').filter(item => item !== name).join(' '); }
    };
    return node;
}

function walk(value, visit) {
    if (Array.isArray(value)) {
        value.forEach(function(item) { walk(item, visit); });
        return;
    }
    if (!value || typeof value !== 'object')
        return;
    visit(value);
    walk(value.children, visit);
}

function nodeText(value) {
    if (Array.isArray(value))
        return value.map(nodeText).join('');
    if (value == null)
        return '';
    if (typeof value !== 'object')
        return String(value);
    return nodeText(value.children);
}

function findNode(root, predicate) {
    let found = null;
    walk(root, function(node) {
        if (!found && predicate(node))
            found = node;
    });
    return found;
}

function deferred() {
    let resolve;
    let reject;
    const promise = new Promise(function(ok, fail) { resolve = ok; reject = fail; });
    return { promise: promise, resolve: resolve, reject: reject };
}

function status(active, actions) {
    return {
        build: { version: '0.3.0', source_commit: 'a'.repeat(40), source_tree: 'b'.repeat(40) },
        active: active,
        actions: actions || {},
        capabilities: [],
        providers: [],
        regions: [],
        selection: {},
        runtime: {
            netfleet_present: active,
            mihomo_running: active,
            controller_available: true,
            supervisor: {},
            lan_runtime: { dashboard_lan_ready: active }
        }
    };
}

function event(index) {
    return {
        at: index + 1,
        action: 'select',
        trigger: 'scheduled',
        initiator: 'supervisor',
        capability: 'ordinary',
        region_id: 'hk',
        provider_id: 'primary',
        leaf: 'node-' + String(index),
        delay_ms: 20 + index,
        reason: 'fastest_eligible'
    };
}

function createStorage(seed) {
    const values = new Map(Object.entries(seed || {}));
    return {
        getItem: function(key) { return values.has(key) ? values.get(key) : null; },
        setItem: function(key, value) { values.set(key, String(value)); },
        removeItem: function(key) { values.delete(key); },
        value: function(key) { return values.get(key); }
    };
}

function createPage(storage, api, notifications) {
    const view = { extend: function(value) { return value; } };
    const ui = {
        addNotification: function(_, message, level) { notifications.push({ message: nodeText(message), level: level }); },
        showModal: function() {},
        hideModal: function() {}
    };
	const styleLink = E('link', { id: 'netfleet-native-style' });
	const document = { getElementById: function() { return styleLink; }, head: { appendChild: function() {} } };
    const netfleetConfig = {
        clone: function(value) { return JSON.parse(JSON.stringify(value)); },
        dirty: function() { return false; },
        render: function() { return E('div', {}, 'config'); }
    };
    let dashboardOpens = 0;
    const managed = {
		quotaResetLabel: function(day) { return Number.isInteger(day) && day >= 1 && day <= 31 ? '每月 ' + day + ' 日重置' : ''; },
        notify: ui.addNotification,
        preloadSubscriptions: function() { return Promise.resolve(); },
        readOperations: function() { return Promise.resolve(); },
        loadComponents: function() { return Promise.resolve(); },
        operationNode: function() { return null; }
    };
    api.nativeSetupGet = function() { return Promise.resolve({ ready: false }); };
    api.dashboardGet = function() { return Promise.resolve({ available: true, port: 9090, protocol: 'http', ui_name: 'zashboard', secret: 'private-secret' }); };
    const managementLoads = [];
    const management = { load: function(_, section) { managementLoads.push(section); return Promise.resolve(); }, maintenance: function() { return null; }, dashboard: function() { return null; } };
    const productSource = fs.readFileSync(require('path').resolve(require('path').dirname(process.argv[1]), 'product.js'), 'utf8');
    const product = new Function('baseclass', 'E', productSource)({ extend: value => value }, E);
    const factory = new Function('view', 'ui', 'managed', 'management', 'netfleet', 'netfleetConfig', 'E', 'L', 'window', 'document', 'compatibility', 'poll', 'product', 'resourceUrl', 'productViews', source);
    const page = factory(view, ui, managed, management, api, netfleetConfig, E, {
        resource: function(value) { return value; },
        url: function(value) { return '/cgi-bin/luci/' + value; }
    }, { localStorage: storage, location: { hostname: 'router.example' }, open: function() { dashboardOpens++; return { location: { replace: function(url) {
        const parsed = new URL(url);
        assert.strictEqual(parsed.hostname, 'router.example');
        assert.strictEqual(parsed.pathname, '/ui/zashboard/');
        assert.strictEqual(parsed.searchParams.get('secret'), 'private-secret');
    } }, close: function() {} }; } }, document, { refresh: () => Promise.resolve(), label: () => '未安装' }, { add: () => {} }, product, name => 'resources/' + name + '?v=revision-1', new Function('baseclass', 'ui', 'managed', 'E', fs.readFileSync(require('path').join(require('path').dirname(process.argv[1]), 'product-views.js'), 'utf8'))({ extend: value => value }, ui, managed, E));
    page.pageId = 'overview';
    page.navigated = null;
    page.context = { signal: new AbortController().signal, navigate(id) { page.navigated = id; } };
    page.styleLink = styleLink;
    page.dashboardOpens = function() { return dashboardOpens; };
    page.managementLoads = managementLoads;
    return page;
}

(async function() {
    const cacheKey = 'opl-netfleet:luci-display:v1';
    const cachedStatus = status(false, { can_enable: true });
    cachedStatus.providers = [ {
        id: 'primary', display_name: '正式机场', available_count: 0,
        available_region_count: 0, candidate_count: 3, region_count: 2
    } ];
    const cachedEvents = { events: [ event(0) ], core_lines: [] };
    const storage = createStorage({
        [cacheKey]: JSON.stringify({
            schema: 1,
            status: cachedStatus,
            events: cachedEvents,
            fetched_at_ms: Date.now() - 60000,
            read_duration_ms: 1664
        })
    });
    const liveStatus = deferred();
    const liveEvents = deferred();
    const liveConfig = deferred();
    const notifications = [];
    const page = createPage(storage, {
        onboardingGet: function() { return Promise.resolve({ required: false }); },
        status: function() { return liveStatus.promise; },
        events: function() { return liveEvents.promise; },
        configGet: function() { return liveConfig.promise; }
    }, notifications);

    let initialResolved = false;
    const initialPromise = page.load().then(function(value) { initialResolved = true; return value; });
    await new Promise(function(resolve) { setImmediate(resolve); });
    assert.strictEqual(initialResolved, true, 'cached load must not wait for RPC');
    const root = page.render(await initialPromise);
    assert(nodeText(root.children[0]).includes('NetFleet v0.3.0 · aaaaaaa'));
    assert.strictEqual(page.styleLink.attrs.href, 'resources/native.css?v=revision-1');
    assert.strictEqual(page.liveDataReady, false);
    assert(nodeText(root).includes('缓存数据，正在更新'));
    assert(nodeText(root).includes('NetFleet 当前未接管，机场和地区的实时可用性未测量'));
    assert(!nodeText(root).includes('不可用机场：'), 'inactive availability must not be reported as provider outage');
    const cachedEnable = findNode(root, function(node) { return node.tag === 'button' && nodeText(node) === '切换模式'; });
    assert(cachedEnable && cachedEnable.attrs.disabled === true, 'cached actions must stay disabled');

    liveStatus.resolve(status(true, { can_disable: true }));
    liveEvents.resolve({
        events: Array.from({ length: 25 }, function(_, index) { return event(index); }),
        core_lines: [ 'private log' ],
        core_lines_persistent: false
    });
    liveConfig.resolve({ revision: 'a'.repeat(64), active: true, pending_apply: false });
    await page.initialRefresh;
    await new Promise(function(resolve) { setImmediate(resolve); });
    assert.strictEqual(page.liveDataReady, true);
    assert.strictEqual(page.readDurationMs >= 0, true);
    const persisted = JSON.parse(storage.value(cacheKey));
    assert.deepStrictEqual(persisted.events.core_lines, [], 'raw logs must not be persisted');
    assert.strictEqual(persisted.status.active, true);
    const runtimeEntry = findNode(root, function(node) { return node.tag === 'a' && nodeText(node) === 'Zashboard ↗'; });
    assert(runtimeEntry && runtimeEntry.attrs['aria-disabled'] !== 'true', 'healthy dashboard entry must be enabled');
    const dashboardUrl = new URL(runtimeEntry.attrs.href);
    assert.strictEqual(dashboardUrl.hostname, 'router.example');
    assert.strictEqual(dashboardUrl.pathname, '/ui/zashboard/');
    assert.strictEqual(dashboardUrl.hash, '#/setup', 'saved backend credentials must not bypass the new connection');
    const tabs = findNode(root, function(node) { return node.tag === 'ul' && node.attrs.class === 'cbi-tabmenu'; });
    assert.strictEqual(tabs, null, 'plugin pages delegate navigation to the shell');
    assert.strictEqual(dashboardUrl.searchParams.get('secret'), 'private-secret');
    assert.strictEqual(runtimeEntry.attrs.target, '_blank');
    assert.strictEqual(runtimeEntry.attrs.rel, 'noopener');
    assert.strictEqual(page.dashboardOpens(), 0, 'normal navigation must not create an intermediate blank window');
    assert(!storage.value(cacheKey).includes('private-secret'), 'dashboard credentials must remain memory-only');
    await new Promise(function(resolve) { setImmediate(resolve); });
    page.status.runtime.lan_runtime.dashboard_lan_ready = false;
    page.redraw();
    const disabledRuntimeEntry = findNode(root, function(node) { return node.tag === 'button' && nodeText(node) === 'Zashboard ↗'; });
    assert(disabledRuntimeEntry && disabledRuntimeEntry.attrs.disabled === true, 'unready dashboard entry must be disabled');
    assert.strictEqual(disabledRuntimeEntry.attrs.title, 'Zashboard 的局域网访问条件尚未就绪');
    page.status.runtime.lan_runtime.dashboard_lan_ready = true;
    page.redraw();

    page.status.capabilities = [ {
        id: 'standard', display_name: '海外加速', base_group: '海外加速',
        data_path: 'preferred', provider_id: 'primary', region_id: 'hk', leaf: '香港-专线(AnyTLS)',
        alive: true, user_mode: 'automatic', reason: { kind: 'automatic_decision', delay_ms: 8, protected_probes_ok: true },
        business_routes: [
            { name: 'Netflix', default_route: 'capability' },
            { name: 'Nintendo Switch', default_route: 'capability' },
            { name: 'Steam', default_route: 'direct' },
            { name: '国内媒体', default_route: 'direct' }
        ],
        fail_open_stages: [
            { kind: 'provider_tier', role: 'primary', provider_ids: [ 'primary' ] },
            { kind: 'direct', provider_ids: [] }
        ]
    } ];
    page.status.providers = [ { id: 'primary', display_name: 'Alpha 正式机场' } ];
    page.status.regions = [ { id: 'hk', display_name: '🇭🇰 香港' } ];
    page.currentView = 'exits';
    page.redraw();
    const runningMetrics = findNode(findNode(root, node => node.attrs.class === 'netfleet-page-content'), function(node) {
        return node.tag === 'div' && String(node.attrs.class || '').includes('netfleet-metrics is-five');
    });
    assert(runningMetrics && runningMetrics.children.length === 5, 'running metrics must use the balanced five-item layout');
    assert(nodeText(root).includes('默认走此出口'));
    assert(nodeText(root).includes('默认直连，可在 Zashboard 临时切换'));
    assert(nodeText(root).includes('Netflix'));
	assert(nodeText(root).includes('Steam'));
	assert(!nodeText(root).includes('接管的原始策略组'));
	assert(String(root.children[3].attrs.class).includes('netfleet-source'), 'data source must follow page content');
	assert(String(root.children[1].attrs.class).includes('netfleet-page-actions'), 'page actions must precede content');

	page.status.providers = [ {
		id: 'primary', display_name: 'Alpha 正式机场', subscription_section: 'primary', selected: true,
		role: 'primary', billing: 'subscription', available_region_count: 2, region_count: 2,
		available_node_count: 47, node_count: 50, node_count_known: true,
		available_count: 3, candidate_count: 4, last_best_delay_ms: 18,
		average_best_delay_ms: 20, delay_sample_count: 3, delay_sampled_at: 1700000000,
		quota: { state: 'available', remaining_bytes: 1024, expires_at: '2027-01-01' }
	} ];
	page.status.subscription_refresh = {
		enabled: true, interval_seconds: 43200, provider_count: 1, last_run_at: 1700000000,
		last_result: 'unchanged'
	};
	page.status.subscriptions = [ {
		section: 'primary', ref: 'subscription:primary', display_name: 'Alpha 正式机场',
		cache_present: true, cache_sha256: 'c'.repeat(64), node_count: 52, last_attempt: 1700000000,
		last_success: 1700000000, last_result: 'updated'
	} ];
	page.currentView = 'providers';
	page.redraw();
	const providerPageText = nodeText(findNode(root, node => node.attrs.class === 'netfleet-page-content'));
	assert(providerPageText.includes('1 / 1 正常'));
	assert(providerPageText.includes('资源数：当前可用 / 已加载'));
	assert(providerPageText.includes('47/50 节点 · 订阅 52 条'));
	assert(!providerPageText.includes('3/4 节点'));
	assert(providerPageText.includes('缓存已更新'));
	assert(providerPageText.includes('管理订阅'));
	const subscriptionLink = findNode(findNode(root, node => node.attrs.class === 'netfleet-page-content'), function(node) {
		return node.tag === 'button' && nodeText(node) === '管理订阅';
	});
	assert(subscriptionLink && subscriptionLink.attrs.class === 'netfleet-inline-link');
	assert(!providerPageText.includes('订阅更新时间'), 'diagnostic fields load into the inspector on selection');
	assert(!providerPageText.includes('更新完成并已重载'));
	assert(!providerPageText.includes('订阅缓存'));
	const providerDetail = findNode(root, function(node) {
		return node.tag === 'aside' && node.attrs.id === 'netfleet-provider-inspector';
	});
	const providerDetailToggle = findNode(root, function(node) {
		return node.tag === 'button' && nodeText(node) === 'Alpha 正式机场';
	});
	assert(providerDetail && providerDetail.attrs.hidden === true, 'provider diagnostics must start closed');
	assert(providerDetailToggle && providerDetailToggle.attrs['aria-expanded'] === 'false');
	providerDetailToggle.attrs.click();
	assert.strictEqual(providerDetail.hidden, false);
    const providerTable = findNode(root, node => String(node.attrs.class || '').includes('netfleet-provider-table'));
    const headers = findNode(providerTable, node => node.tag === 'thead').children[0].children;
    const cells = findNode(providerTable, node => node.tag === 'tbody').children[0].children;
    assert.deepStrictEqual(headers.map(nodeText), ['机场','定位','可用资源','最近一次测速','订阅状态','剩余流量','到期时间']);
    assert.strictEqual(cells.length, headers.length);
    assert.strictEqual(nodeText(cells[4]), '缓存已更新');
    assert(nodeText(cells[6]).includes('2027'));

	assert.strictEqual(providerDetailToggle.attrs['aria-expanded'], 'true');
	assert(nodeText(providerDetail).includes('订阅更新时间'));
	assert(nodeText(providerDetail).includes('cccccccccccc'));
	assert(!findNode(providerDetail, node => node.tag === 'meter'), 'unknown quota totals must not invent a ratio');
	providerDetail.attrs.keydown({ key: 'Escape' });
	assert.strictEqual(providerDetail.hidden, true);
	assert(providerDetailToggle.focused, 'closing detail must return keyboard focus');
	const search = findNode(root, node => node.attrs['aria-label'] === '搜索机场');
	search.attrs.input({ target: { value: '不存在' } });
	assert(nodeText(root).includes('没有匹配的机场'));
	search.attrs.input({ target: { value: 'Alpha' } });
	assert(nodeText(root).includes('47/50 节点'));
	page.status.subscriptions[0].last_attempt = null;
	page.status.subscriptions[0].last_success = null;
	page.redraw();
	findNode(root, node => node.tag === 'button' && nodeText(node) === 'Alpha 正式机场').attrs.click();
	assert(nodeText(root).includes('最近尝试尚未执行'));
	assert(nodeText(root).includes('订阅更新时间尚未执行'));
	page.status.providers.push({ ...page.status.providers[0], id: 'faster', display_name: 'Beta', selected: false, average_best_delay_ms: 10, delay_sample_count: 2 });
	page.status.providers.push({ ...page.status.providers[0], id: 'single', display_name: 'Gamma', selected: false, average_best_delay_ms: 1, delay_sample_count: 1 });
	page.providerTableState.query = '';
	page.redraw();
	const sort = findNode(root, node => node.attrs['aria-label'] === '机场排序');
	sort.attrs.change({ target: { value: 'average' } });
	let names = [];
	walk(root, node => { if (node.tag === 'button' && node.attrs.class === 'netfleet-name-link') names.push(nodeText(node)); });
	assert.deepStrictEqual(names, ['Beta', 'Alpha 正式机场', 'Gamma'], 'one-sample averages must sort after real averages');
	const selectedOnly = findNode(root, node => node.tag === 'input' && node.attrs.type === 'checkbox');
	selectedOnly.attrs.change({ target: { checked: true } });
	names = [];
	walk(root, node => { if (node.tag === 'button' && node.attrs.class === 'netfleet-name-link') names.push(nodeText(node)); });
	assert.deepStrictEqual(names, ['Alpha 正式机场']);
	const refreshConnections = page.refreshConnections;
	let connectionReads = 0;
	page.refreshConnections = function() { connectionReads++; };
	findNode(root, node => node.tag === 'button' && nodeText(node) === '事件与诊断').attrs.click();
	assert.strictEqual(page.navigated, 'events');
	assert.strictEqual(connectionReads, 0, 'new plugin page owns its own reads');
	page.refreshConnections = refreshConnections;
	page.status.regions = [
		{ id: 'hk', display_name: 'HK 香港', selected: true, available_count: 1, available_provider_count: 1 },
		{ id: 'jp', display_name: 'JP 日本', available_count: 1, available_provider_count: 1 },
		{ id: 'ch', display_name: 'CH 瑞士', available_count: 0, available_provider_count: 0 }
	];
	page.currentView = 'regions';
	page.redraw();
	assert(nodeText(root).includes('已配置 3 个地区'));
	assert(nodeText(root).includes('显示 3 个'));
	assert(nodeText(root).includes('CH 瑞士'), 'the configured directory survives missing current paths');
	findNode(root, node => node.attrs['aria-label'] === '搜索地区').attrs.input({ target: { value: '日本' } });
	assert(nodeText(root).includes('已配置 3 个地区'));
	assert(nodeText(root).includes('显示 1 个'), 'filtering must not change the directory total');

	page.currentView = 'events';
    page.redraw();
    const eventPageText = nodeText(findNode(root, node => node.attrs.class === 'netfleet-page-content'));
    assert(eventPageText.includes('选路事件'));
    assert(!eventPageText.includes('Mihomo 原始日志'));
    assert(!eventPageText.includes('当前活动连接'));
    page.diagnosticSection = 'core'; page.redraw();
    const diagnosticMetrics = findNode(findNode(root, node => node.attrs.class === 'netfleet-page-content'), function(node) {
        return node.tag === 'div' && String(node.attrs.class || '') === 'netfleet-metrics';
    });
    assert(diagnosticMetrics && diagnosticMetrics.children.length === 4, 'diagnostic metrics must contain only four live states');
    const diagnosticNote = findNode(findNode(root, node => node.attrs.class === 'netfleet-page-content'), function(node) {
        return node.tag === 'div' && String(node.attrs.class || '').includes('netfleet-diagnostic-note');
    });
    assert(diagnosticNote && nodeText(diagnosticNote).includes('原始日志：临时窗口'));
    page.diagnosticSection = 'website'; page.redraw();
    const connectionDetails = findNode(root, function(node) {
        return node.tag === 'details' && String(node.attrs.class || '').includes('netfleet-connection-details');
    });
    assert(connectionDetails && connectionDetails.attrs.open === undefined, 'current connections must stay collapsed by default');
    assert(nodeText(connectionDetails).includes('详细规则命中链、连接流量和实时代理组观察请使用 Zashboard'));
    page.diagnosticSection = 'events'; page.redraw();
    let body = findNode(root, function(node) { return node.tag === 'tbody' && node.children.length === 20; });
    assert.strictEqual(body.children.length, 20, 'first page must contain 20 events');
    const pagination = findNode(root, function(node) {
        return node.tag === 'div' && String(node.attrs.class || '').includes('netfleet-event-pagination');
    });
    assert(pagination, 'event pagination must use its spacing class');
    const next = findNode(root, function(node) { return node.tag === 'button' && nodeText(node) === '下一页'; });
    assert(next && next.attrs.disabled !== true);
    next.attrs.click();
    body = findNode(root, function(node) { return node.tag === 'tbody' && node.children.length === 5; });
    assert.strictEqual(body.children.length, 5, 'second page must contain remaining events');
    assert.strictEqual(page.eventPage, 1);

    const failedStatus = deferred();
    const failedNotifications = [];
    const failedPage = createPage(storage, {
        onboardingGet: function() { return Promise.resolve({ required: false }); },
        status: function() { return failedStatus.promise; },
        events: function() { return Promise.resolve({ events: [] }); },
        configGet: function() { return Promise.resolve({ revision: 'b'.repeat(64), active: false, pending_apply: false }); }
    }, failedNotifications);
    const failedInitial = await failedPage.load();
    const failedRoot = failedPage.render(failedInitial);
    failedStatus.reject(new Error('offline'));
    await failedPage.initialRefresh;
    await new Promise(function(resolve) { setImmediate(resolve); });
    assert.strictEqual(failedPage.liveDataReady, false);
    assert(nodeText(failedRoot).includes('缓存数据，刷新失败'));
    const failedDisable = findNode(failedRoot, function(node) { return node.tag === 'button' && nodeText(node) === '切换模式'; });
    assert(failedDisable && failedDisable.attrs.disabled === true, 'failed refresh must not authorize actions');
    const retry = findNode(failedRoot, function(node) { return node.tag === 'button' && nodeText(node) === '刷新'; });
    assert(retry && retry.attrs.disabled !== true, 'refresh retry must remain available');
    assert.strictEqual(failedNotifications.length, 1);
})().catch(function(error) {
    console.error(error.stack || error);
    process.exit(1);
});
"""
        result = subprocess.run(
            ["node", "-e", harness, str(overview)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)

    def test_native_luci_config_renders_real_regions_and_owner_actions(self):
        config_module = RUNTIME / "plugins/product-ui/resources/config.js"
        harness = r"""
const assert = require('assert');
const fs = require('fs');
const source = fs.readFileSync(process.argv[1], 'utf8');

function E(tag, attrs, children) {
    return { tag: tag, attrs: attrs || {}, children: Array.isArray(children) ? children : children == null ? [] : [ children ] };
}
function text(value) {
    if (Array.isArray(value)) return value.map(text).join('');
    if (value === null) return 'null';
    if (value === undefined) return '';
    if (typeof value !== 'object') return String(value);
    return text(value.children);
}
function find(root, predicate) {
    if (Array.isArray(root)) {
        for (const item of root) { const found = find(item, predicate); if (found) return found; }
        return null;
    }
    if (!root || typeof root !== 'object') return null;
    if (predicate(root)) return root;
    return find(root.children, predicate);
}

const baseclass = { extend: function(value) { return value; } };
const ui = { hideModal: function() {} };
const factory = new Function('baseclass', 'ui', 'management', 'E', 'compatibility', source);
const config = factory(baseclass, ui, {}, E, { render: () => E('section', {}, 'HTTPS 兼容') });
const deviceConfig = {
    revision: 'a'.repeat(64), active: true, pending_apply: false,
    backend: { id: 'nikki-mihomo', display_name: 'Nikki + Mihomo' },
    policy_source: { kind: 'bundle', ref: 'bundle:base-v1', display_name: 'NetFleet 内置基础策略' },
    policy_source_options: [ { kind: 'bundle', ref: 'bundle:base-v1', display_name: 'NetFleet 内置基础策略' } ],
    policy_groups: [ '节点选择', '流媒体' ],
    recovery_profile: { ref: 'subscription:base', display_name: '当前原生配置' },
    recovery_profile_options: [ { ref: 'subscription:base', display_name: '当前原生配置' } ],
    providers: [],
    provider_options: [ { id: 'alpha', section: 'alpha', display_name: 'Alpha 机场', region_ids: [ 'japan', 'singapore' ] } ],
    regions: [
        { id: 'japan', flag: '🇯🇵', display_name: '日本', mode: 'automatic' },
        { id: 'switzerland', flag: '🇨🇭', display_name: '瑞士', mode: 'automatic' }
    ],
    region_options: [
        { id: 'japan', code: 'JP', display_name: '日本', display_order: 10 },
        { id: 'singapore', code: 'SG', display_name: '新加坡', display_order: 20 }
    ],
    capabilities: [ { id: 'standard', display_name: '常规出口', enabled: true, mode: 'automatic', region_ids: [ 'japan', 'switzerland' ], entry_group: '节点选择', policy_groups: [], base_groups: [ '节点选择' ] } ],
    routing_rules: [],
    automation: { enabled: true, selection_interval_seconds: 1800, subscription_refresh_enabled: true, subscription_refresh_interval_seconds: 43200 },
    safety: { region_switch_margin_ms: 150, leaf_switch_margin_ms: 150, runtime_grace_seconds: 45, latency_url: 'https://latency.invalid', path_probe_url: 'https://path.invalid', guard_probe_url: 'https://guard.invalid' }
};
const controller = {
    config: config.clone(deviceConfig), configDraft: config.clone(deviceConfig), configSection: 'regions',
    status: { providers: [], regions: [
        { id: 'japan', available_provider_count: 2, available_node_count: 4 },
        { id: 'switzerland', available_provider_count: 0, available_node_count: 0 }
    ], runtime: {} },
    busy: false, liveDataReady: true, redraw: function() {}, showConfigWizard: function() {},
    discardConfig: function() {}, previewConfigChanges: function() {},
    saveConfig: function() {}, confirmConfigApply: function() {}
};

let root = config.render(controller);
assert(text(root).includes('JP'));
const japanInput = find(root, function(node) { return node.tag === 'input' && node.attrs.value === '日本'; });
assert(japanInput);
assert(find(root, function(node) { return node.tag === 'input' && node.attrs.value === '瑞士'; }), 'configured regions must remain removable even when currently unavailable');
let save = find(root, function(node) { return node.tag === 'button' && text(node) === '保存配置'; });
assert(!save, 'active policy offers one apply action rather than an unusable save button');
let apply = find(root, function(node) { return node.tag === 'button' && text(node) === '应用更改'; });
assert(apply && apply.attrs.disabled === true);

controller.configSection = 'providers';
root = config.render(controller);
const addProvider = find(root, function(node) { return node.tag === 'button' && text(node) === '添加机场'; });
assert(addProvider, 'an available Nikki subscription must be addable');
addProvider.attrs.click();
assert.strictEqual(controller.configDraft.providers.length, 1);
assert.strictEqual(controller.configDraft.providers[0].section, 'alpha');
assert(controller.configDraft.regions.some(function(region) { return region.id === 'singapore'; }), 'adding a provider must bring in discovered regions');

controller.configSection = 'capabilities';
root = config.render(controller);
assert(text(root).includes('JP 日本'));
assert(text(root).includes('瑞士'));
assert(!text(root).includes('null'));

controller.configDraft.regions[0].display_name = '日本线路';
root = config.render(controller);
apply = find(root, function(node) { return node.tag === 'button' && text(node) === '应用更改'; });
assert(apply && apply.attrs.disabled !== true);
assert(config.changeText({ scope: 'region', id: 'japan', field: 'display_name', before: '日本', after: '日本线路' }, controller).includes('日本线路'));
assert(text(config.wizard(controller, 0)).includes('环境与恢复'));

controller.configDraft = config.clone(controller.config);
controller.configDraft.active = false;
root = config.render(controller);
apply = find(root, function(node) { return node.tag === 'button' && text(node) === '应用并接管'; });
assert(apply && apply.attrs.disabled !== true, 'inactive saved config must remain applicable');
"""
        result = subprocess.run(
            ["node", "-e", harness, str(config_module)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)

    def test_device_scripts_cannot_operate_power_or_firmware(self):
        forbidden = re.compile(
            r"(^|[;&|$(\s])(reboot|poweroff|sysupgrade|firstboot|mtd|sd_update)([;&|)\s]|$)"
        )
        scripts = sorted((ROOT / "scripts").rglob("*.sh"))
        scripts.extend(
            (
                ROOT / "openwrt" / "files" / "etc" / "init.d" / "opl-netfleet",
                ROOT / "openwrt" / "files" / "usr" / "libexec" / "rpcd" / "opl-netfleet",
            )
        )
        for script in scripts:
            self.assertIsNone(forbidden.search(script.read_text()), script)


if __name__ == "__main__":
    unittest.main()
