export const API_VERSION = 1;

export function valid_id(id) {
	return type(id) == "string" && length(id) <= 48 && match(id, /^[a-z][a-z0-9]*(-[a-z0-9]+)*$/) != null &&
		index(["https-compat", "zashboard"], id) < 0;
};

export function descriptor_error(value, id) {
	if (type(value) != "object" || !valid_id(value.id) || value.id != id ||
		value.schema != "opl-netfleet-plugin.v1" || type(value.api_version) != "int" || value.api_version < 1 ||
		type(value.label) != "string" || !length(value.label) || length(value.label) > 120 ||
		type(value.version) != "string" || !match(value.version, /^[0-9][A-Za-z0-9.+~-]{0,63}$/) ||
		value.package != `opl-netfleet-plugin-${id}` || type(value.dependencies) != "array" ||
		type(value.backends) != "array" || !length(value.backends) || type(value.permissions) != "array" ||
		type(value.actions) != "object") return "plugin_manifest_invalid";
	for (let key in keys(value)) if (index(["schema", "id", "label", "version", "api_version", "package", "dependencies", "backends", "permissions", "actions"], key) < 0)
		return "plugin_manifest_invalid";
	for (let name in value.dependencies) if (type(name) != "string" || !match(name, /^[a-z][a-z0-9+-]*$/)) return "plugin_manifest_invalid";
	for (let backend in value.backends) if (index(["native-mihomo", "nikki-mihomo"], backend) < 0) return "plugin_manifest_invalid";
	for (let permission in value.permissions) if (index(["diagnostics", "network", "resources"], permission) < 0) return "plugin_manifest_invalid";
	for (let action, access in value.actions) if (!valid_id(action) || index(["get", "load", "unload", "reload"], action) >= 0 || index(["read", "write"], access) < 0)
		return "plugin_manifest_invalid";
	return null;
};

export function action_access(manifest, action) {
	if (action == "get") return "read";
	if (index(["load", "unload", "reload"], action) >= 0) return "write";
	return manifest.actions[action];
};
