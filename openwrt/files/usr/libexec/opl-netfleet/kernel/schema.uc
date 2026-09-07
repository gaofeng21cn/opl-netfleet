export const API_VERSION = 1;
export function valid_id(id) {
	return type(id) == 'string' && length(id) <= 48 && match(id, /^[a-z][a-z0-9]*(-[a-z0-9]+)*$/) != null;
};
export function service_name(name) {
	return type(name) == 'string' && length(name) <= 128 && match(name, /^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$/) != null;
};
function method_name(name) { return type(name) == 'string' && match(name, /^[a-zA-Z][a-zA-Z0-9_]*$/) != null; };
export function action_access(manifest, action) {
	if (action == 'get') return 'read';
	if (index(['load','unload','reload'], action) >= 0) return 'write';
	return manifest.schema == 'opl-netfleet-service-plugin.v1' ? manifest.actions?.[action]?.access : manifest.actions?.[action];
};
function contributions_error(value) {
	if (value.configuration != null && (type(value.configuration) != 'object' || length(keys(value.configuration)) != 2 ||
		action_access(value, value.configuration.read) != 'read' || action_access(value, value.configuration.write) != 'write' ||
		value.actions?.[value.configuration.read] == null || value.actions?.[value.configuration.write] == null)) return 'plugin_configuration_invalid';
	if (value.ui != null) {
		if (type(value.ui) != 'array' || length(value.ui) > 32) return 'plugin_ui_invalid';
		const pages = {};
		for (let page in value.ui) {
			if (type(page) != 'object' || !valid_id(page.id) || pages[page.id] || type(page.title) != 'string' ||
				!length(page.title) || length(page.title) > 120 || match(page.title, /[[:cntrl:]]/) || type(page.module) != 'string' ||
				!match(page.module, /^resources\/[A-Za-z0-9_-]+(\/[A-Za-z0-9_-]+)*\.js$/) ||
				index(['host', 'instance'], page.scope ?? 'instance') < 0) return 'plugin_ui_invalid';
			for (let key in keys(page)) if (index(['id', 'title', 'module', 'scope'], key) < 0) return 'plugin_ui_invalid';
			pages[page.id] = true;
		}
	}
	return null;
};
export function descriptor_error(value, id) {
	if (type(value) != 'object' || !valid_id(value.id) || value.id != id ||
		type(value.api_version) != 'int' || value.api_version < 1 ||
		type(value.label) != 'string' || !length(value.label) || length(value.label) > 120 ||
		type(value.version) != 'string' || !match(value.version, /^[0-9][A-Za-z0-9.+~-]{0,63}$/) ||
		value.package != `opl-netfleet-plugin-${id}`) return 'plugin_manifest_invalid';
	if (value.schema == 'opl-netfleet-service-plugin.v1') {
		for (let key in keys(value)) if (index(['schema','id','label','version','api_version','package','services','commands','package_dependencies','lifecycle','actions','configuration','ui'], key) < 0) return 'plugin_manifest_invalid';
		if (type(value.services) != 'object' || (!length(value.services) && !length(value.ui ?? [])) || type(value.commands) != 'object') return 'plugin_manifest_invalid';
		if (value.package_dependencies != null && type(value.package_dependencies) != 'array') return 'plugin_manifest_invalid';
		for (let name in value.package_dependencies ?? []) if (type(name) != 'string' || !match(name, /^[a-z][a-z0-9+-]*$/)) return 'plugin_manifest_invalid';
		for (let name, service in value.services) {
			if (!service_name(name) || type(service) != 'object' || type(service.version) != 'int' || service.version < 1 ||
				type(service.module) != 'string' || !match(service.module, /^lib\/[A-Za-z0-9_-]+(\/[A-Za-z0-9_-]+)*\.uc$/) ||
				type(service.requires) != 'object') return 'plugin_manifest_invalid';
			for (let dep, version in service.requires) if (!service_name(dep) || type(version) != 'int' || version < 1) return 'plugin_manifest_invalid';
		}
		for (let name, command in value.commands) if (!valid_id(name) || type(command) != 'object' || value.services[command.service] == null ||
			!method_name(command.method) || index(['read','write'], command.access) < 0) return 'plugin_manifest_invalid';
		if (value.actions != null && type(value.actions) != 'object') return 'plugin_manifest_invalid';
		for (let name, action in value.actions ?? {}) if (!valid_id(name) || index(['get','load','unload','reload'], name) >= 0 ||
			type(action) != 'object' || length(keys(action)) != 3 || value.services[action.service] == null || !method_name(action.method) ||
			index(['read','write'], action.access) < 0) return 'plugin_manifest_invalid';
		if (value.lifecycle != null) {
			if (type(value.lifecycle) != 'object' || value.lifecycle.drain == null || value.lifecycle.resume == null) return 'plugin_manifest_invalid';
			if (index(['host','instance'], value.lifecycle.scope ?? 'host') < 0) return 'plugin_manifest_invalid';
			for (let action, hook in value.lifecycle) {
				if (action == 'scope') continue;
				if (index(['drain','resume'], action) < 0 || type(hook) != 'object' ||
					value.services[hook.service] == null || !method_name(hook.method)) return 'plugin_manifest_invalid';
			}
		}
		return contributions_error(value);
	}
	if (value.schema != 'opl-netfleet-plugin.v1' || type(value.dependencies) != 'array' || type(value.backends) != 'array' ||
		type(value.permissions) != 'array' || type(value.actions) != 'object') return 'plugin_manifest_invalid';
	for (let key in keys(value)) if (index(['schema','id','label','version','api_version','package','dependencies','backends','permissions','actions','configuration','ui'], key) < 0) return 'plugin_manifest_invalid';
	for (let name in value.dependencies) if (type(name) != 'string' || !match(name, /^[a-z][a-z0-9+-]*$/)) return 'plugin_manifest_invalid';
	for (let backend in value.backends) if (!valid_id(backend)) return 'plugin_manifest_invalid';
	for (let permission in value.permissions) if (index(['diagnostics','network','resources'], permission) < 0) return 'plugin_manifest_invalid';
	for (let action, access in value.actions) if (!valid_id(action) || index(['get','load','unload','reload'], action) >= 0 || index(['read','write'], access) < 0) return 'plugin_manifest_invalid';
	return contributions_error(value);
};
