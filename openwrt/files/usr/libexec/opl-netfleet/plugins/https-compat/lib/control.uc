import * as fs from "fs";

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let inspection, dispatch, command_compatibility_get, command_compatibility_ca, command_compatibility_apply, command_compatibility_enable, command_compatibility_disable, command_compatibility_probe;

const API_VERSION = context.use("models.extensions").API_VERSION;
const admission = context.use("models.extensions").admission;
const KIND = context.use("platform.runtime").KIND;
const shell_quote = context.use("platform.process").shell_quote;
const files = context.use("platform.files");

const OWNER = "/usr/libexec/opl-netfleet-compat/control.uc";
let implementation;
function native_owner() {
	implementation ??= loadfile(OWNER)()(context);
	return implementation;
}
const DECLARATION = "/usr/libexec/opl-netfleet-compat/extension.json";

const extension = {
	id: "https-compat", label: "HTTPS 兼容", api_version: API_VERSION, kind: "optional",
	package: "opl-netfleet-https-compat", dependencies: ["ucode-mod-digest", "ucode-mod-socket", "ucode-mod-uloop", "openssl-util", "ca-bundle", "coreutils-timeout"],
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
	if (!length(filter(values(extension.commands), entry => entry.method == action)) && index(['suspend', 'resume'], action) < 0)
		return { ok: false, error: "extension_action_not_allowed" };
	if (fs.stat(OWNER) == null && index(['suspend', 'resume'], action) >= 0) return { ok: true, result: { installed: false } };
	if (fs.stat(OWNER) == null) return action == "get" ? { ok: true, result: {
		installed: false, requested: false, intercepting: false, reason: "component_not_installed",
		revision: null, config: { schema: 1, enabled: false, devices: [], rules: [] }, trust: {}, rules: {}, events: []
	} } : { ok: false, error: "compatibility_component_not_installed" };
	try {
        const input = envelope ? json(fs.readfile(envelope))?.request ?? {} : {};
        const response = { ok: true, result: native_owner().dispatch(action, input) };
		if (action == "get" && response?.ok == true && type(response.result) == "object") {
			const installed = inspection();
			response.result.managed = installed.api_version == API_VERSION && installed.error == null && KIND == "native-mihomo";
			response.result.management_reason = installed.error ?? (installed.api_version != API_VERSION ? "extension_api_incompatible" :
				KIND != "native-mihomo" ? "extension_backend_unsupported" : null);
		}
		return response;
	} catch (error) { return { ok: false, error: match(error.message ?? "", /^[a-z_]+$/) ? error.message : "compatibility_owner_no_response" }; }
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

function action(name, params) {
	if (index(['suspend', 'resume'], name) < 0) {
		const error = admission(extension, inspection(), `compatibility-${name}`, KIND);
		if (error != null) return { ok: false, error };
	}
	const directory = fs.mkdtemp('/tmp/netfleet-compat-action.XXXXXX');
	if (directory == null) return { ok: false, error: 'compatibility_request_unavailable' };
	const path = `${directory}/request.json`;
	let result;
	try {
		result = fs.chmod(directory, 0700) && files.atomic_json(path, { request: params ?? {} })
			? dispatch(name, path) : { ok: false, error: 'compatibility_request_unavailable' };
	} catch (error) { result = { ok: false, error: 'compatibility_request_unavailable' }; }
	fs.unlink(path); fs.rmdir(directory);
	return result;
};

function internal(argv) {
    const action = { 'compatibility-engine-prepare': 'prepare-engine', 'compatibility-drain': 'drain',
        'compatibility-tick': 'tick' }[argv[0]];
    if (argv[0] == 'compatibility-private-backup' && length(argv) == 2)
        return { ok: true, result: native_owner().dispatch('private-backup', { path: argv[1] }) };
    if (argv[0] == 'compatibility-watch') return native_owner().watch();
    if (!action || length(argv) != 1) return { ok: false, error: 'compatibility_action_invalid' };
    return { ok: true, result: native_owner().dispatch(action, {}) };
}
return { internal, extension, inspection, dispatch, command_compatibility_get, command_compatibility_ca, command_compatibility_apply, command_compatibility_enable, command_compatibility_disable, command_compatibility_probe,
	config_get: () => dispatch('get'), config_set: params => action('apply', params),
	enable: params => action('enable', params), disable: params => action('disable', params),
	probe: params => action('probe', params), public_ca: () => dispatch('ca'),
	drain: () => action('suspend', { lifecycle: true }), resume: state => action('resume', state)
};
};
