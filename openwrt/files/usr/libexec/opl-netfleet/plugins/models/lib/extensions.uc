

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let descriptor_error, admission;



const API_VERSION = 1;

descriptor_error = function(value) {
	if (type(value) != "object" || !match(value.id ?? "", /^[a-z][a-z0-9-]*$/) ||
		type(value.label) != "string" || !length(value.label) || value.api_version != API_VERSION ||
		index(["optional", "resource"], value.kind) < 0 ||
		!match(value.package ?? "", /^[a-z][a-z0-9+-]*$/) ||
		index(["network_interception", "dashboard_resources"], value.permission_class) < 0)
		return "extension_descriptor_invalid";
	for (let key in ["dependencies", "ui"]) if (type(value[key]) != "array") return "extension_descriptor_invalid";
	for (let name in value.dependencies) if (type(name) != "string" || !match(name, /^[a-z][a-z0-9+-]*$/)) return "extension_descriptor_invalid";
	for (let slot in value.ui) if (index(["settings", "components", "diagnostics", "dashboard"], slot) < 0) return "extension_descriptor_invalid";
	if (type(value.commands) != "object" || !length(value.commands)) return "extension_descriptor_invalid";
	for (let command, entry in value.commands) {
		if (!match(command, /^[a-z][a-z0-9-]*$/) || type(entry) != "object" ||
			!match(entry.method ?? "", /^[a-z][a-z0-9-]*$/) || index(["read", "write"], entry.access) < 0 ||
			type(entry.backends) != "array" || !length(entry.backends)) return "extension_descriptor_invalid";
		for (let backend in entry.backends) if (index(["native-mihomo", "nikki-mihomo"], backend) < 0) return "extension_descriptor_invalid";
	}
	return null;
};

admission = function(definition, observed, command, backend) {
	const invalid = descriptor_error(definition);
	if (invalid != null) return invalid;
	const entry = definition.commands[command];
	if (entry == null) return "extension_action_not_allowed";
	// Bootstrap diagnostics and safe exit stay callable across interface upgrades.
	if (entry.method == "get" || entry.method == "disable") return null;
	if (index(entry.backends, backend) < 0) return "extension_backend_unsupported";
	if (!observed.available && definition.kind == "optional") return "extension_component_not_installed";
	if (observed.error != null) return observed.error;
	if (observed.api_version != API_VERSION) return "extension_api_incompatible";
	return null;
};

return { API_VERSION, descriptor_error, admission };
};
