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
PLUGINS = ROOT / "plugins"
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
                                              (ROOT / "openwrt", "opl-netfleet-plugin-models", True),
                                              (LUCI, "luci-app-netfleet", True)):
                harness = root / "metadata.mk"
                harness.write_text(f"$(info __BEGIN__)\n$(info $(Package/{package}))\n$(info __END__)\nall:;@:\n")
                result = subprocess.run([
                    "make", "--no-print-directory", "-f", str(source / "Makefile"), "-f", str(harness),
                    f"TOPDIR={root}", f"INCLUDE_DIR={root / 'include'}", "all",
                ], cwd=source, capture_output=True, text=True, check=True)
                definition = result.stdout.split("__BEGIN__\n", 1)[1].split("__END__", 1)[0]
                minimum = "0.9.13" if package.startswith("opl-netfleet-plugin-") else ("0.8.8" if package == "luci-app-netfleet" else "0.8.1")
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
            floor = re.search(r"opl-netfleet-plugin-models \(>=([0-9]+\.[0-9]+\.[0-9]+)\)", result.stdout)
            self.assertIsNotNone(floor)
            self.assertGreaterEqual(tuple(map(int, floor[1].split("."))), (0, 7, 8))

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
            shutil.copytree(PLUGINS / "product-ui", root / "compiled-plugins/product-ui")
            for source, package in ((ROOT / "openwrt", "opl-netfleet-plugin-product-ui"),
                                    (LUCI, "luci-app-netfleet")):
                harness = root / f"{package}.mk"
                harness.write_text(
                    "INSTALL_DIR:=mkdir -p\nINSTALL_DATA:=install -m 0644\nCP:=cp -R\n"
                    "all:\n\t$(call Package/" + package + "/install," + str(stage) + ")\n")
                subprocess.run([
                    "make", "--no-print-directory", "-f", str(source / "Makefile"),
                    "-f", str(harness), f"TOPDIR={root}", f"INCLUDE_DIR={root / 'include'}", f"PKG_BUILD_DIR={root}", "all",
                ], cwd=source, capture_output=True, text=True, check=True)
            public = stage / "www/luci-static/resources/netfleet"
            package_version = re.search(r"^PKG_VERSION:=(\S+)$", (LUCI / "Makefile").read_text(), re.M).group(1)
            shell_modules = public / f"v{package_version.replace('.', '_')}"
            self.assertEqual({"api.js", "plugin-host.js"}, {path.name for path in shell_modules.glob("*.js")})
            self.assertEqual([], list(public.glob("*.js")))
            product = PLUGINS / "product-ui/resources"
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
                "$(eval $(Package/opl-netfleet-kernel))\n"
                "all:\n\t@echo kernel-dependencies: $(DEPENDS)\n\t$(call Package/opl-netfleet-kernel/install," + str(root / "stage") + ")\n")
            result = subprocess.run([
                "make", "--no-print-directory", "-f", str(ROOT / "openwrt/Makefile"),
                "-f", str(harness), f"TOPDIR={root}", f"INCLUDE_DIR={root / 'include'}", "all",
            ], cwd=ROOT / "openwrt", capture_output=True, text=True, check=True)
            self.assertIn("+ucode-mod-digest", result.stdout.split("kernel-dependencies:", 1)[1].splitlines()[0])
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
        self.assertEqual(["ucode-mod-ubus"], plugins["platform"]["package_dependencies"])
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
            plugin = root / "plugins/layout-test"
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
            # This fixture exercises install layout; SDK tests cover compilation.
            shutil.copytree(plugin, root / "compiled-plugins/layout-test")
            harness = root / "install.mk"
            harness.write_text(
                "INSTALL_DIR:=mkdir -p\nCP:=cp -R\n"
                "all:\n\t$(call Package/opl-netfleet-plugin-layout-test/install," + str(root / "stage") + ")\n")
            subprocess.run([
                "make", "--no-print-directory", "-f", str(root / "Makefile"),
                "-f", str(harness), f"TOPDIR={root}", f"INCLUDE_DIR={root / 'include'}", f"PKG_BUILD_DIR={root}", "all",
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
            manifest = json.loads((PLUGINS / plugin / "manifest.json").read_text())
            self.assertIn(service, manifest["services"])
            self.assertTrue((PLUGINS / plugin / manifest["services"][service]["module"]).is_file())

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
        sources = list((PLUGINS / "models/lib").glob("*.uc"))
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
        source = "\n".join(path.read_text() for path in (*RUNTIME.rglob("*.uc"), *PLUGINS.rglob("*.uc")))
        self.assertNotIn("yq -i", source)
        self.assertNotIn("eval-all", source)
        self.assertNotIn("yq -M -P -o yaml", source)
        self.assertIn("yq -M -p yaml -o json", source)

    def test_runtime_fail_open_health_and_lock_contract(self):
        policy = (PLUGINS / "models/lib/policy.uc").read_text()
        activation = (PLUGINS / "activation/lib/control.uc").read_text()
        compilation = (PLUGINS / "compilation/lib/control.uc").read_text()
        supervisor = (PLUGINS / "scheduler/lib/control.uc").read_text()
        supervisor_entry = (RUNTIME / "supervisor.uc").read_text()
        host = (RUNTIME / "kernel/host.uc").read_text()
        nikki = (PLUGINS / "mihomo/lib/backend.uc").read_text()
        runtime_makefile = (ROOT / "openwrt" / "Makefile").read_text()
        rpcd = (
            ROOT / "openwrt" / "files" / "usr" / "libexec" / "rpcd" / "opl-netfleet"
        ).read_text()
        api = (PLUGINS / "product-ui/resources/api.js").read_text()
        overview = (PLUGINS / "product-ui/resources/product-pages.js").read_text()

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
        self.assertIn("lan_runtime_state = function(dns_probe_url, observation)", nikki)
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
        commands = json.loads((PLUGINS / "compilation/manifest.json").read_text())["commands"]
        self.assertEqual("command_package_cleanup", commands["package-cleanup"]["method"])
        self.assertIn('remove_artifact()', compilation)
        self.assertIn('"provider_link_cleanup_failed"', compilation)
        self.assertIn('context.use("subscriptions.providers").load', compilation)
        self.assertNotIn("function load_provider_profiles", compilation)
        self.assertIn("return removed", (PLUGINS / "mihomo/lib/profile-storage.uc").read_text())
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
        self.assertTrue((PLUGINS / "product-ui/resources/config.js").is_file())
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

        native_style = (PLUGINS / "product-ui/resources/native.css").read_text()
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

    def test_native_control_spec_has_one_shape_source(self):
        """设备页控件形状只取 token：圆角、控件高度与边框色都不再内联声明。"""
        native = (PLUGINS / "product-ui/resources/native.css").read_text()
        roots = re.findall(r"([^{}]+)\{([^{}]*)\}", native)

        # 形状 token 只在根块定义一次。
        declarations = re.findall(r"--(nf-radius-[\w-]+|nf-control-height|nf-check-size):\s*([^;]+);", native)
        self.assertEqual(
            sorted(declarations),
            [("nf-check-size", "17px"), ("nf-control-height", "40px"), ("nf-control-height", "44px"),
             ("nf-radius-bar", "2px"), ("nf-radius-control", "6px"), ("nf-radius-surface", "6px")],
        )
        # 只有窄屏触控断点抬高控件高度，圆角不随宽度改变。
        self.assertRegex(
            native,
            r"@media \(max-width: 700px\) \{\n\t/\*[^*]*\*/\n\t\.netfleet-native \{ --nf-control-height: 44px; \}",
        )

        # 圆角只有三种写法：0、圆形与 token；像素字面值不再出现。
        radii = {value.strip() for value in re.findall(r"border-radius:\s*([^;]+);", native)}
        self.assertEqual(sorted(value for value in radii if not value.startswith(("0", "var("))), ["50%"])

        # 边框色只走 token；语义强调色左边线单独放行。
        inline = []
        for selector, body in roots:
            for declaration in re.finditer(
                r"(?<![-\w])border(?:-(?:top|right|bottom|left|width|style|color))?:\s*([^;]+);", body
            ):
                value = " ".join(declaration.group(1).split())
                if any(token in value for token in ("var(--nf-border", "var(--nf-accent", "var(--nf-warning)",
                                                    "var(--primary-color", "transparent")):
                    continue
                if re.match(r"^(0|none)\b", value):
                    continue
                inline.append((selector.strip()[:60], value[:40]))
        self.assertEqual(inline, [])

        # 页面规则不得给表单控件重画边框：控件外观归 LuCI，NetFleet 只定尺寸。
        repainted = [selector.strip()[:60] for selector, body in roots
                     if re.search(r"(^|[\s,>~+])(input|select|textarea)(?![\w-])", selector)
                     and re.search(r"(?<![-\w])border(?:-(?:top|right|bottom|left|width|style|color|radius))?:\s*[^;]*[^0;]", body)]
        self.assertEqual(repainted, [])
        self.assertRegex(native, r"\.netfleet-check input \{[^}]*width: var\(--nf-check-size\)", re.S)

        # 引用的形状 token 必须真的定义过，否则声明会被浏览器静默丢弃。
        defined = set(re.findall(r"(--nf-[\w-]+):", native))
        self.assertEqual(sorted(set(re.findall(r"var\((--nf-[\w-]+)", native)) - defined), [])

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
