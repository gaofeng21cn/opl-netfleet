import { API_VERSION, descriptor_error, resolve, admission, component } from "../openwrt/files/usr/libexec/opl-netfleet/core/extensions.uc";

function check(value, message) { if (!value) die(message); };
const module = { id: "fixture", label: "Fixture", api_version: API_VERSION, kind: "optional", package: "fixture-module",
	dependencies: ["fixture-engine"], permission_class: "network_interception", ui: ["settings", "components"], commands: {
		"fixture-get": { method: "get", access: "read", backends: ["native-mihomo", "nikki-mihomo"] },
		"fixture-enable": { method: "enable", access: "write", backends: ["native-mihomo"] },
		"fixture-disable": { method: "disable", access: "write", backends: ["native-mihomo", "nikki-mihomo"] }
	} };
const present = { available: true, api_version: 1, error: null };
const packages = { "fixture-engine": "1.0-r1", "fixture-module": "2.0-r1" };
check(descriptor_error(module) == null, "valid contribution admitted");
check(descriptor_error({ ...module, api_version: 2 }) != null, "host rejects unknown descriptor major");
check(resolve([module], "fixture-enable").method == "enable", "exact command routes to declared method");
check(resolve([module], "fixture-private-backup") == null, "private lifecycle cannot become RPC by naming convention");
check(resolve([module], "fixture-enable; echo injected") == null, "arbitrary command rejected");
check(resolve([module, { ...module, id: "second" }], "fixture-enable").error == "extension_command_conflict", "duplicate command cannot shadow a module");
check(admission(module, present, "fixture-enable", "native-mihomo") == null, "matching ABI admits normal operation");
check(admission(module, present, "fixture-enable", "nikki-mihomo") == "extension_backend_unsupported", "wrong backend cannot activate extension");
check(admission(module, { available: false }, "fixture-enable", "native-mihomo") == "extension_component_not_installed", "missing module cannot activate");
for (let observed in [{ ...present, api_version: 2 }, { ...present, api_version: null, error: "extension_manifest_missing" }]) {
	check(admission(module, observed, "fixture-enable", "native-mihomo") != null, "unknown interface blocks new work");
	check(admission(module, observed, "fixture-get", "native-mihomo") == null, "diagnostic revision stays reachable");
	check(admission(module, observed, "fixture-disable", "nikki-mihomo") == null, "safe exit remains reachable after backend/interface drift");
}
check(admission(module, present, "fixture-private-backup", "native-mihomo") == "extension_action_not_allowed", "undeclared method rejected");
const row = component(module, present, packages, "native-mihomo");
check(row.state == "ready" && row.installed_version == "2.0-r1" && row.dependencies[0].available, "installation and interface reflect actual inputs");
check(component(module, present, {}, "native-mihomo").state == "dependency_missing", "missing dependency distinct from API mismatch");
check(component(module, present, null, "native-mihomo").state == "unknown", "unreadable package DB is not missing dependency");
check(component(module, present, packages, "nikki-mihomo").state == "backend_unsupported", "wrong backend displayed distinctly");
check(component(module, { ...present, api_version: 2 }, packages, "native-mihomo").state == "incompatible", "ABI drift displayed distinctly");
check(component(module, { available: false }, packages, "native-mihomo").state == "not_installed", "stale package metadata cannot prove owner exists");
check(component({ ...module, kind: "resource" }, { ...present, installed_version: "v3.0.0" }, packages, "native-mihomo").installed_version == "v3.0.0", "resource version is not host package version");
print("extensions_contract_ok\n");
