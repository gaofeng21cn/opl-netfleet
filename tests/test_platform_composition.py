"""Keep the OpenWrt and macOS composition roots resolvable and in step.

Both platforms compose the same shared business plugins under their own system
root. The kernel resolves a service by following ``system.bindings`` into an
enabled plugin and then each service's ``requires`` list, so a shared service
that grows a platform-specific dependency keeps working on the platform that
owns it and breaks the other one only when a user reaches that code path.

These checks mirror the kernel resolver statically from the manifests and the
two ``system.json`` files, so they run on any machine and in CI without UCode,
a device, or a built app.
"""

import json
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SHARED_ROOT = ROOT / "openwrt/files/usr/libexec/opl-netfleet"
OPENWRT_SYSTEM = ROOT / "openwrt/files/usr/share/opl-netfleet/system.json"
DESKTOP_ROOT = ROOT / "desktop/ucode"
MACOS_SYSTEM = DESKTOP_ROOT / "system.json"
MACOS_HOST = ROOT / "desktop/runtime/server.mjs"
PLUGIN_SCHEMA = "opl-netfleet-service-plugin.v1"
SYSTEM_SCHEMA = "opl-netfleet-system.v1"


def kernel_api_version():
    source = (SHARED_ROOT / "kernel/schema.uc").read_text()
    match = re.search(r"export const API_VERSION = (\d+);", source)
    if match is None:
        raise AssertionError("kernel API_VERSION is unreadable")
    return int(match.group(1))


def load_plugins(roots):
    """Overlay plugin roots the way the host copies them: later roots win."""
    plugins = {}
    for root in roots:
        for manifest in sorted((root / "plugins").glob("*/manifest.json")):
            data = json.loads(manifest.read_text())
            data["__root"] = root
            plugins[data["id"]] = data
    return plugins


class Composition:
    """The subset of kernel resolution that decides whether a service loads."""

    def __init__(self, system_path, roots):
        self.system_path = system_path
        self.system = json.loads(system_path.read_text())
        self.plugins = load_plugins(roots)
        self.bindings = self.system["bindings"]
        self.enabled = self.system["enabled"]

    def resolves(self, name, major, trail=None):
        """Return None when the service and its dependency closure resolve."""
        trail = trail or ()
        if name in trail:
            return f"dependency cycle: {' -> '.join(trail + (name,))}"
        provider = self.bindings.get(name)
        if provider is None:
            return f"{name} is unbound"
        if self.enabled.get(provider) is not True:
            return f"{name} is bound to disabled plugin {provider}"
        plugin = self.plugins.get(provider)
        if plugin is None:
            return f"{name} is bound to missing plugin {provider}"
        service = (plugin.get("services") or {}).get(name)
        if service is None:
            return f"{name} is bound to {provider}, which does not provide it"
        if service.get("version") != major:
            return f"{name} expects v{major} but {provider} provides v{service.get('version')}"
        for dependency, version in (service.get("requires") or {}).items():
            reason = self.resolves(dependency, version, trail + (name,))
            if reason is not None:
                return f"{name} requires {dependency}: {reason}"
        return None

    def bound_services(self):
        for name, provider in self.bindings.items():
            if self.enabled.get(provider) is True:
                yield name

    def commands(self):
        declared = {}
        for plugin_id, plugin in self.plugins.items():
            if self.enabled.get(plugin_id) is not True:
                continue
            for name, spec in (plugin.get("commands") or {}).items():
                declared[name] = (plugin_id, spec)
        return declared

    def unresolved(self):
        problems = []
        for name in self.bound_services():
            service = None
            plugin = self.plugins.get(self.bindings[name], {})
            service = (plugin.get("services") or {}).get(name)
            if service is None:
                problems.append(f"{name} is bound to {self.bindings[name]}, which does not provide it")
                continue
            reason = self.resolves(name, service.get("version"))
            if reason is not None:
                problems.append(reason)
        return problems


class PlatformCompositionTests(unittest.TestCase):
    def setUp(self):
        self.api_version = kernel_api_version()
        self.openwrt = Composition(OPENWRT_SYSTEM, [SHARED_ROOT])
        self.macos = Composition(MACOS_SYSTEM, [SHARED_ROOT, DESKTOP_ROOT])

    def test_plugin_manifests_match_the_kernel_api(self):
        seen = 0
        for root in (SHARED_ROOT, DESKTOP_ROOT):
            for manifest in sorted((root / "plugins").glob("*/manifest.json")):
                data = json.loads(manifest.read_text())
                label = manifest.relative_to(ROOT)
                self.assertEqual(PLUGIN_SCHEMA, data.get("schema"), label)
                self.assertEqual(self.api_version, data.get("api_version"), label)
                self.assertEqual(data["id"], manifest.parent.name, label)
                seen += 1
        self.assertGreater(seen, 20)

    def test_both_system_roots_share_one_schema(self):
        self.assertEqual(SYSTEM_SCHEMA, self.openwrt.system.get("schema"))
        self.assertEqual(SYSTEM_SCHEMA, self.macos.system.get("schema"))

    def test_every_enabled_plugin_is_installed(self):
        for label, composition in (("openwrt", self.openwrt), ("macos", self.macos)):
            enabled = {name for name, state in composition.enabled.items() if state}
            missing = sorted(enabled - set(composition.plugins))
            self.assertEqual([], missing, f"{label} enables plugins without a manifest")

    def test_openwrt_bound_services_resolve(self):
        self.assertEqual([], self.openwrt.unresolved())

    def test_macos_bound_services_resolve(self):
        self.assertEqual([], self.macos.unresolved())

    def test_missing_service_and_disabled_dependency_are_rejected(self):
        self.macos.bindings["missing.interface"] = "models"
        self.assertTrue(any("missing.interface" in problem for problem in self.macos.unresolved()))
        del self.macos.bindings["missing.interface"]
        self.macos.enabled["models"] = False
        self.assertTrue(any("disabled plugin models" in problem for problem in self.macos.unresolved()))

    def test_macos_host_commands_are_provided_by_its_composition(self):
        invoked = sorted(set(re.findall(r"ucode\('([a-z][a-z-]+)'", MACOS_HOST.read_text())))
        self.assertGreater(len(invoked), 8)
        declared = self.macos.commands()
        for name in invoked:
            self.assertIn(name, declared, f"desktop host invokes undeclared command {name}")
            plugin_id, spec = declared[name]
            plugin = self.macos.plugins[plugin_id]
            service = spec["service"]
            self.assertIn(service, plugin.get("services") or {}, f"{name} targets {plugin_id}.{service}")
            reason = self.macos.resolves(service, plugin["services"][service]["version"])
            self.assertIsNone(reason, f"{name}: {reason}")

    def test_platform_owned_services_are_rebound_not_shadowed(self):
        """A platform module only takes effect through an explicit rebinding."""
        platform_services = set(self.macos.plugins["platform-macos"].get("services") or {})
        shared_services = set()
        for plugin_id, plugin in self.macos.plugins.items():
            if plugin_id == "platform-macos":
                continue
            shared_services |= set(plugin.get("services") or {})
        overlapping = sorted(platform_services & shared_services)
        self.assertGreater(len(overlapping), 5, "platform and shared services are expected to overlap")
        for name in overlapping:
            self.assertEqual(
                "platform-macos", self.macos.bindings.get(name),
                f"{name} has a macOS implementation that is not bound",
            )
        for name in sorted(platform_services - shared_services - set(self.macos.bindings)):
            self.fail(f"{name} is provided by platform-macos but never bound")


if __name__ == "__main__":
    unittest.main()
