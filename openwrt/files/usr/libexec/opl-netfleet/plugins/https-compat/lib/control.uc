import * as fs from "fs";

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let inspection, dispatch, command_compatibility_get, command_compatibility_ca, command_compatibility_apply, command_compatibility_enable, command_compatibility_disable, command_compatibility_probe;

const API_VERSION = context.use("models.extensions").API_VERSION;
const admission = context.use("models.extensions").admission;
const KIND = context.use("platform.runtime").KIND;
const shell_quote = context.use("platform.process").shell_quote;

const OWNER = "/usr/libexec/opl-netfleet-compat/control.py";
const DECLARATION = "/usr/libexec/opl-netfleet-compat/extension.json";

const extension = {
	id: "https-compat", label: "HTTPS 兼容", api_version: API_VERSION, kind: "optional",
	package: "opl-netfleet-https-compat", dependencies: ["python3", "ca-bundle", "coreutils-timeout"],
	permission_class: "network_interception", ui: ["components", "diagnostics"],
	commands: {
		"compatibility-get": { method: "get", access: "read", backends: ["native-mihomo", "nikki-mihomo"] },
		"compatibility-ca": { method: "ca", access: "read", backends: ["native-mihomo"] },
		"compatibility-apply": { method: "apply", access: "write", backends: ["native-mihomo"] },
		"compatibility-enable": { method: "enable", access: "write", backends: ["native-mihomo"] },
		"compatibility-disable": { method: "disable", access: "write", backends: ["native-mihomo", "nikki-mihomo"] },
		"compatibility-probe": { method: "probe", access: "write", backends: ["native-mihomo"] }
	}
};

inspection = function() {
	const available = fs.stat(OWNER)?.type == "file";
	const file = fs.lstat(DECLARATION);
	if (file == null) return { available: available, api_version: null, error: available ? "extension_manifest_missing" : null };
	if (file.type != "file" || file.size > 4096) return { available: available, api_version: null, error: "extension_manifest_invalid" };
	try {
		const data = json(fs.readfile(DECLARATION));
		if (data?.id == extension.id && type(data.api_version) == "int" && data.api_version > 0)
			return { available: available, api_version: data.api_version, error: null };
	} catch (error) {}
	return { available: available, api_version: null, error: "extension_manifest_invalid" };
};

dispatch = function(action, envelope) {
	if (!length(filter(values(extension.commands), entry => entry.method == action)))
		return { ok: false, error: "extension_action_not_allowed" };
	if (fs.stat(OWNER) == null) return action == "get" ? { ok: true, result: {
		installed: false, requested: false, intercepting: false, reason: "component_not_installed",
		revision: null, config: { schema: 1, enabled: false, devices: [], rules: [] }, trust: {}, rules: {}, events: []
	} } : { ok: false, error: "compatibility_component_not_installed" };
	const command = `/usr/bin/python3 ${OWNER} ${shell_quote(action)}` + (envelope ? ` ${shell_quote(envelope)}` : "");
	const process = fs.popen(command + " 2>/dev/null");
	if (process == null) return { ok: false, error: "compatibility_owner_unavailable" };
	const raw = process.read("all");
	process.close();
	try {
		const response = json(raw);
		if (action == "get" && response?.ok == true && type(response.result) == "object") {
			const installed = inspection();
			response.result.managed = installed.api_version == API_VERSION && installed.error == null && KIND == "native-mihomo";
			response.result.management_reason = installed.error ?? (installed.api_version != API_VERSION ? "extension_api_incompatible" :
				KIND != "native-mihomo" ? "extension_backend_unsupported" : null);
		}
		return response;
	} catch (error) { return { ok: false, error: "compatibility_owner_no_response" }; }
};

command_compatibility_get = function(argv) {
	const observed = inspection();
	const error = admission(extension, observed, argv[0], KIND);
	if (error != null) return { ok: false, error: error };
	return dispatch("get", argv[1]);
};

command_compatibility_ca = function(argv) {
	const observed = inspection();
	const error = admission(extension, observed, argv[0], KIND);
	if (error != null) return { ok: false, error: error };
	return dispatch("ca", argv[1]);
};

command_compatibility_apply = function(argv) {
	const observed = inspection();
	const error = admission(extension, observed, argv[0], KIND);
	if (error != null) return { ok: false, error: error };
	return dispatch("apply", argv[1]);
};

command_compatibility_enable = function(argv) {
	const observed = inspection();
	const error = admission(extension, observed, argv[0], KIND);
	if (error != null) return { ok: false, error: error };
	return dispatch("enable", argv[1]);
};

command_compatibility_disable = function(argv) {
	const observed = inspection();
	const error = admission(extension, observed, argv[0], KIND);
	if (error != null) return { ok: false, error: error };
	return dispatch("disable", argv[1]);
};

command_compatibility_probe = function(argv) {
	const observed = inspection();
	const error = admission(extension, observed, argv[0], KIND);
	if (error != null) return { ok: false, error: error };
	return dispatch("probe", argv[1]);
};

return { extension, inspection, dispatch, command_compatibility_get, command_compatibility_ca, command_compatibility_apply, command_compatibility_enable, command_compatibility_disable, command_compatibility_probe };
};
