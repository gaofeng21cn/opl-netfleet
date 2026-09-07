import { use, release as release_services } from "./services.uc";
const API_VERSION = use("models.extensions").API_VERSION;
const descriptor_error = use("models.extensions").descriptor_error;
const admission = use("models.extensions").admission;

function check(value, message) { if (!value) die(message); };
const module = { id: "fixture", label: "Fixture", api_version: API_VERSION, kind: "optional", package: "fixture-module",
	dependencies: ["fixture-engine"], permission_class: "network_interception", ui: ["settings", "components"], commands: {
		"fixture-get": { method: "get", access: "read", backends: ["native-mihomo", "nikki-mihomo"] },
		"fixture-enable": { method: "enable", access: "write", backends: ["native-mihomo"] },
		"fixture-disable": { method: "disable", access: "write", backends: ["native-mihomo", "nikki-mihomo"] }
	} };
const present = { available: true, api_version: 1, error: null };
check(descriptor_error(module) == null, "valid contribution admitted");
check(descriptor_error({ ...module, api_version: 2 }) != null, "host rejects unknown descriptor major");
check(admission(module, present, "fixture-enable", "native-mihomo") == null, "matching ABI admits normal operation");
check(admission(module, present, "fixture-enable", "nikki-mihomo") == "extension_backend_unsupported", "wrong backend cannot activate extension");
check(admission(module, { available: false }, "fixture-enable", "native-mihomo") == "extension_component_not_installed", "missing module cannot activate");
for (let observed in [{ ...present, api_version: 2 }, { ...present, api_version: null, error: "extension_manifest_missing" }]) {
	check(admission(module, observed, "fixture-enable", "native-mihomo") != null, "unknown interface blocks new work");
	check(admission(module, observed, "fixture-get", "native-mihomo") == null, "diagnostic revision stays reachable");
	check(admission(module, observed, "fixture-disable", "nikki-mihomo") == null, "safe exit remains reachable after backend/interface drift");
}
check(admission(module, present, "fixture-private-backup", "native-mihomo") == "extension_action_not_allowed", "undeclared method rejected");
release_services();
print("extensions_contract_ok\n");
