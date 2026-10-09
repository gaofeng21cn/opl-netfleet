export const API_VERSION = 1;
export function valid_id(id) {
	return type(id) == 'string' && length(id) <= 48 && match(id, /^[a-z][a-z0-9]*(-[a-z0-9]+)*$/) != null;
};
export function service_name(name) {
	return type(name) == 'string' && length(name) <= 128 && match(name, /^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$/) != null;
};
function method_name(name) { return type(name) == 'string' && match(name, /^[a-zA-Z][a-zA-Z0-9_]*$/) != null; };
function contract_schema(value, depth) {
	if (depth > 6 || type(value) != 'object') return false;
	const allowed = ['type','required','properties','items','enum','additionalProperties'];
	for (let key in keys(value)) if (index(allowed, key) < 0) return false;
	if (value.type != null && index(['object','array','string','number','integer','boolean','null'], value.type) < 0) return false;
	if (value.required != null && (type(value.required) != 'array' || length(filter(value.required, name => type(name) != 'string')))) return false;
	if (value.properties != null) {
		if (type(value.properties) != 'object') return false;
		for (let name, child in value.properties) if (type(name) != 'string' || !contract_schema(child, depth + 1)) return false;
	}
	if (value.items != null && !contract_schema(value.items, depth + 1)) return false;
	if (value.enum != null && type(value.enum) != 'array') return false;
	if (value.additionalProperties != null && type(value.additionalProperties) != 'bool') return false;
	return true;
};
export function matches_schema(value, schema) {
	if (schema == null) return true;
	const kind = schema.type;
	if (kind == 'null' && value != null || kind == 'boolean' && type(value) != 'bool' ||
		kind == 'string' && type(value) != 'string' || kind == 'array' && type(value) != 'array' ||
		kind == 'object' && type(value) != 'object' || kind == 'integer' && type(value) != 'int' ||
		kind == 'number' && index(['int','double'], type(value)) < 0) return false;
	if (kind == 'array') {
		for (let item in value) if (!matches_schema(item, schema.items)) return false;
	}
	if (kind == 'object') {
		for (let name in schema.required ?? []) if (!exists(value, name)) return false;
		for (let name, child in value) {
			if (schema.properties?.[name] == null) { if (schema.additionalProperties == false) return false; continue; }
			if (!matches_schema(child, schema.properties[name])) return false;
		}
	}
	if (schema.enum != null && !length(filter(schema.enum, item => sprintf('%J', item) == sprintf('%J', value)))) return false;
	return true;
};
function manifest_metadata(value) {
	if (value == null) return true;
	if (type(value) != 'object') return false;
	for (let key in keys(value)) if (index(['label','description','required','unloadable','retained','owner','packages','dependencies','engine'], key) < 0) return false;
	for (let key in ['label','description','owner','engine']) if (value[key] != null && type(value[key]) != 'string') return false;
	for (let key in ['required','unloadable','retained']) if (value[key] != null && type(value[key]) != 'bool') return false;
	for (let field in ['packages','dependencies']) if (value[field] != null && (type(value[field]) != 'array' || length(filter(value[field], item => type(item) != 'string' || match(item, /^[a-z0-9][a-z0-9+_.-]*$/) == null)))) return false;
	return true;
};
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
				index(['host', 'instance'], page.scope ?? 'instance') < 0 ||
				index(['primary', 'plugin'], page.navigation ?? 'plugin') < 0) return 'plugin_ui_invalid';
			for (let key in keys(page)) if (index(['id', 'title', 'module', 'scope', 'navigation'], key) < 0) return 'plugin_ui_invalid';
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
		for (let key in keys(value)) if (index(['schema','id','label','version','api_version','package','services','commands','package_dependencies','lifecycle','actions','configuration','ui','presentation','product'], key) < 0) return 'plugin_manifest_invalid';
		if (!manifest_metadata(value.presentation) || !manifest_metadata(value.product)) return 'plugin_manifest_invalid';
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
			!method_name(command.method) || index(['read','write'], command.access) < 0 ||
			length(filter(keys(command), key => index(['service','method','access','params','result'], key) < 0)) ||
			(command.params != null && !contract_schema(command.params, 0)) || (command.result != null && !contract_schema(command.result, 0))) return 'plugin_manifest_invalid';
		if (value.actions != null && type(value.actions) != 'object') return 'plugin_manifest_invalid';
		for (let name, action in value.actions ?? {}) if (!valid_id(name) || index(['get','load','unload','reload'], name) >= 0 ||
				type(action) != 'object' || length(filter(keys(action), key => index(['service','method','access','lock','params','result'], key) < 0)) || value.services[action.service] == null || !method_name(action.method) ||
				index(['network','plugin'], action.lock ?? 'network') < 0 ||
			index(['read','write'], action.access) < 0 || (action.params != null && !contract_schema(action.params, 0)) || (action.result != null && !contract_schema(action.result, 0))) return 'plugin_manifest_invalid';
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
	for (let key in keys(value)) if (index(['schema','id','label','version','api_version','package','dependencies','backends','permissions','actions','configuration','ui','presentation','product'], key) < 0) return 'plugin_manifest_invalid';
	if (!manifest_metadata(value.presentation) || !manifest_metadata(value.product)) return 'plugin_manifest_invalid';
	for (let name in value.dependencies) if (type(name) != 'string' || !match(name, /^[a-z][a-z0-9+-]*$/)) return 'plugin_manifest_invalid';
	for (let backend in value.backends) if (!valid_id(backend)) return 'plugin_manifest_invalid';
	for (let permission in value.permissions) if (index(['diagnostics','network','resources'], permission) < 0) return 'plugin_manifest_invalid';
	for (let action, access in value.actions) if (!valid_id(action) || index(['get','load','unload','reload'], action) >= 0 || index(['read','write'], access) < 0) return 'plugin_manifest_invalid';
	return contributions_error(value);
};
