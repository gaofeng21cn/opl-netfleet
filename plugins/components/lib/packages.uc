// Interpret the APK solver's C-locale transaction lines, not UI labels.
export function changes(output) {
	const result = [];
	for (let line in split(output ?? '', '\n')) {
		if (!match(line, /^\( *[0-9]+\/[0-9]+\) /)) continue;
		const row = match(line, /^\( *[0-9]+\/[0-9]+\) (Installing|Upgrading|Downgrading|Purging|Reinstalling) ([a-z0-9][a-z0-9+_.-]*) \(([^)]+)\)$/);
		if (row == null) die('package_plan_unreadable');
		const versions = split(row[3], ' -> ');
		push(result, { action: row[1], name: row[2], version: versions[length(versions) - 1] });
	}
	return result;
};

function eligible_update_name(name, owned) {
	return type(name) == 'string' && (match(name, /^opl-netfleet-plugin-[a-z][a-z0-9-]*$/) != null ||
		name == 'luci-app-netfleet' || owned[name] != null);
}

export function validate(changed, request, installed, product, owned, native_backend) {
	owned ??= {};
	if (type(request) != 'object') die('invalid_plugin_package_request');
	if (request.action == 'update' && type(request.items) == 'array') {
		if (request.confirm != true || request.name != null || !length(request.items) || length(request.items) > 64)
			die('invalid_plugin_package_request');
		const targets = {}, target_names = [];
		for (let item in request.items) {
			if (type(item) != 'object' || type(item.name) != 'string' || type(item.version) != 'string' || !length(item.version) ||
				type(item.before_version) != 'string' || !length(item.before_version))
				die('invalid_plugin_package_request');
			if (!eligible_update_name(item.name, owned)) die('plugin_package_protected');
			if (targets[item.name] != null) die('invalid_plugin_package_request');
			if ((installed[item.name] ?? null) != item.before_version) die('installed_version_changed');
			if (item.version == item.before_version) die('candidate_changed');
			targets[item.name] = item.version;
			push(target_names, item.name);
		}
		const has_compat = targets['opl-netfleet-https-compat'] != null && owned['opl-netfleet-https-compat'] == 'https-compat';
		const has_mihomo = targets['opl-netfleet-plugin-mihomo'] != null;
		const names = [], candidates = {};
		for (let row in changed) {
			if (index(names, row.name) >= 0) die('package_plan_unreadable');
			if (targets[row.name] != null) {
				if (row.action != 'Upgrading' || row.version != targets[row.name]) die('candidate_changed');
			} else {
				const retained_dependency = native_backend === true && installed[row.name] != null && row.action == 'Upgrading' &&
					((has_compat && index(['opl-netfleet-plugin-mihomo', 'opl-netfleet'], row.name) >= 0) ||
					 (has_mihomo && row.name == 'opl-netfleet'));
				if (index(['Installing', 'Upgrading'], row.action) < 0 ||
					(index(['opl-netfleet', 'opl-netfleet-kernel', 'mihomo-meta', 'opl-netfleet-plugin-mihomo'], row.name) >= 0 && !retained_dependency) ||
					(installed[row.name] != null && row.name != 'luci-app-netfleet' && !owned[row.name] &&
					 !match(row.name, /^opl-netfleet-plugin-[a-z][a-z0-9-]*$/) && !retained_dependency))
					die('plugin_dependency_change_required');
			}
			candidates[row.name] = row.version;
			push(names, row.name);
		}
		for (let name in target_names) if (index(names, name) < 0) die('candidate_changed');
		return { names, candidates };
	}
	if ((!match(request.name ?? '', /^opl-netfleet-plugin-[a-z][a-z0-9-]*$/) &&
		!(request.name == 'luci-app-netfleet' && request.action == 'update') &&
		!(owned[request.name] && request.action == 'update')) ||
		(index(product, request.name) >= 0 && request.action != 'update')) die('plugin_package_protected');
	if (index(['install', 'update', 'remove'], request.action) < 0 || request.confirm != true)
		die('invalid_plugin_package_request');
	if ((installed[request.name] ?? null) != (request.before_version ?? null)) die('installed_version_changed');
	if ((request.action == 'install') != (installed[request.name] == null)) die('installed_version_changed');
	const names = [], candidates = {};
	for (let row in changed) {
		if (index(names, row.name) >= 0) die('package_plan_unreadable');
		if (request.action == 'remove') {
			if (row.action != 'Purging' || row.name != request.name) die('plugin_package_required');
			candidates[row.name] = null;
		} else {
			if (row.name == request.name) {
				if (row.version != request.version || index(['Installing', 'Upgrading'], row.action) < 0)
					die('candidate_changed');
			} else {
				// The native HTTPS dependency closure can retain its data plane;
				// the transaction separately verifies both payload contracts before writes.
				const retained_dependency = native_backend === true && request.action == 'update' &&
					installed[row.name] != null && row.action == 'Upgrading' &&
					(request.name == 'opl-netfleet-https-compat' && owned[request.name] == 'https-compat' &&
					 index(['opl-netfleet-plugin-mihomo', 'opl-netfleet'], row.name) >= 0 ||
					 request.name == 'opl-netfleet-plugin-mihomo' && row.name == 'opl-netfleet');
				if (index(['Installing', 'Upgrading'], row.action) < 0 ||
					index(['opl-netfleet', 'opl-netfleet-kernel', 'mihomo-meta', 'opl-netfleet-plugin-mihomo'], row.name) >= 0 && !retained_dependency ||
					(installed[row.name] != null && row.name != 'luci-app-netfleet' && !owned[row.name] && !match(row.name, /^opl-netfleet-plugin-[a-z][a-z0-9-]*$/) && !retained_dependency))
					die('plugin_dependency_change_required');
			}
			candidates[row.name] = row.version;
		}
		push(names, row.name);
	}
	if (index(names, request.name) < 0) die('candidate_changed');
	return { names, candidates };
};

export function backoff_seconds(failures) {
	const count = type(failures) == 'int' && failures > 0 ? failures : 1;
	const shift = count > 5 ? 4 : count - 1;
	const delay = 3600 * (1 << shift);
	return delay > 86400 ? 86400 : delay;
};

export function select_auto_update(rows, versions, candidates, inventory, retained, native_backend, is_newer) {
	const deferred = [];
	const cmp = is_newer ?? ((a, b) => a != null && b != null && a != b);
	for (let base in ['opl-netfleet-kernel', ...(native_backend ? ['mihomo-meta'] : [])]) {
		if (versions?.[base] != null && cmp(candidates?.[base], versions[base]))
			push(deferred, { name: base, version: candidates[base], reason: 'manual_maintenance_required' });
	}
	const lifecycle_pkgs = {};
	for (let item in inventory ?? []) {
		if (item?.lifecycle != null) {
			if (type(item.package) == 'string') lifecycle_pkgs[item.package] = true;
			if (type(item.product?.engine) == 'string') lifecycle_pkgs[item.product.engine] = true;
		}
	}
	const retained_list = retained ?? [];
	const wave1 = [], wave2 = [];
	for (let row in rows ?? []) {
		if (row?.installed_version == null || row.update_available != true || row.available_version == null) continue;
		const entry = { name: row.name, before_version: row.installed_version, version: row.available_version };
		const in_retained = index(retained_list, row.name) >= 0 && row.name != 'opl-netfleet';
		if (lifecycle_pkgs[row.name] || in_retained) {
			if (native_backend === true && in_retained) push(wave2, entry);
			else push(deferred, { name: row.name, version: row.available_version, reason: 'manual_maintenance_required' });
		} else {
			push(wave1, entry);
		}
	}
	const items = length(wave1) > 0 ? wave1 : wave2;
	const wave = length(wave1) > 0 ? 'plugins' : length(wave2) > 0 ? 'retained' : null;
	return { wave, items, deferred };
};
