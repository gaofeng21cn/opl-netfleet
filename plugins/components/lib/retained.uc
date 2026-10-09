// Compatibility for an existing data plane, independently of package versions.
function canonical(value) {
	if (type(value) == 'array') return map(value, canonical);
	if (type(value) != 'object') return value;
	const result = {};
	for (let key in sort(keys(value))) result[key] = canonical(value[key]);
	return result;
}
function equal(a, b) { return sprintf('%J', canonical(a)) == sprintf('%J', canonical(b)); }
export function manifest(before, after) {
	if (type(before) != 'object' || type(after) != 'object') return false;
	const a = { ...before }, b = { ...after };
	delete a.version; delete b.version;
	delete a.package_dependencies; delete b.package_dependencies;
	delete a.package_constraints; delete b.package_constraints;
	delete a.services; delete b.services;
	if (!equal(a, b)) return false;
	for (let name, service in before.services ?? {}) {
		const next = after.services?.[name];
		if (type(next) != 'object') return false;
		const old_shape = { ...service }, new_shape = { ...next };
		delete old_shape.requires; delete new_shape.requires;
		if (!equal(old_shape, new_shape)) return false;
		for (let dependency, version in service.requires ?? {})
			if (next.requires?.[dependency] != version) return false;
	}
	return true;
};
export function composition(before, after) {
	if (type(before) != 'object' || type(after) != 'object') return false;
	const a = { ...before }, b = { ...after };
	delete a.bindings; delete b.bindings;
	if (!equal(a, b)) return false;
	for (let name, id in before.bindings ?? {}) if (after.bindings?.[name] != id) return false;
	return true;
};
