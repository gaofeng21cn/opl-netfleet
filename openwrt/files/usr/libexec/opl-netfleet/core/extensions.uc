export const API_VERSION = 1;

export function descriptor_error(value) {
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

export function resolve(definitions, command) {
	let found = null;
	for (let definition in definitions) {
		if (definition?.commands?.[command] == null) continue;
		if (descriptor_error(definition) != null) return { error: "extension_descriptor_invalid" };
		if (found != null) return { error: "extension_command_conflict" };
		found = { id: definition.id, ...definition.commands[command] };
	}
	return found;
};

export function admission(definition, observed, command, backend) {
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

export function component(definition, observed, versions, backend) {
	const dependencies = map(definition.dependencies, name => ({ id: name, installed_version: versions?.[name] ?? null,
		available: versions == null ? null : versions[name] != null }));
	const missing = length(filter(dependencies, value => value.available == false)) > 0;
	const backend_supported = length(filter(values(definition.commands), value =>
		value.access == "write" && value.method != "disable" && index(value.backends, backend) >= 0)) > 0;
	const compatible = observed.api_version == API_VERSION && observed.error == null;
	const package_unknown = versions == null || definition.kind == "optional" && versions[definition.package] == null;
	const state = !observed.available ? "not_installed" : !compatible ? "incompatible" :
		!backend_supported ? "backend_unsupported" : missing ? "dependency_missing" : package_unknown ? "unknown" : "ready";
	return { id: definition.id, label: definition.label, kind: definition.kind, package: definition.package,
		installed_version: definition.kind == "resource" ? observed.installed_version : versions?.[definition.package] ?? null,
		api_version: observed.api_version, required_api_version: API_VERSION, compatible: compatible,
		available: observed.available, state: state, dependencies: dependencies,
		reason: !observed.available ? "extension_component_not_installed" : observed.error ?? (!compatible ? "extension_api_incompatible" :
			!backend_supported ? "extension_backend_unsupported" : missing ? "extension_dependency_missing" : package_unknown ? "extension_package_unknown" : null),
		ui: definition.ui, permission_class: definition.permission_class };
};
