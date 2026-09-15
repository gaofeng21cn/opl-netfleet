// Interpret the APK solver's C-locale transaction lines, not UI labels.
export function changes(output) {
	const result = [];
	for (let line in split(output ?? '', '\n')) {
		if (!match(line, /^\([0-9]+\/[0-9]+\) /)) continue;
		const row = match(line, /^\([0-9]+\/[0-9]+\) (Installing|Upgrading|Downgrading|Purging|Reinstalling) ([a-z0-9][a-z0-9+_.-]*) \(([^)]+)\)$/);
		if (row == null) die('package_plan_unreadable');
		const versions = split(row[3], ' -> ');
		push(result, { action: row[1], name: row[2], version: versions[length(versions) - 1] });
	}
	return result;
};

export function validate(changed, request, installed, product, owned) {
	owned ??= {};
	if ((!match(request.name ?? '', /^opl-netfleet-plugin-[a-z][a-z0-9-]*$/) &&
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
				// APK chooses dependencies. Admission only bounds their lifecycle impact.
				if (index(['Installing', 'Upgrading'], row.action) < 0 ||
					index(['opl-netfleet', 'opl-netfleet-kernel', 'mihomo-meta', 'opl-netfleet-plugin-mihomo'], row.name) >= 0 ||
					(installed[row.name] != null && !owned[row.name] && !match(row.name, /^opl-netfleet-plugin-[a-z][a-z0-9-]*$/)))
					die('plugin_dependency_change_required');
			}
			candidates[row.name] = row.version;
		}
		push(names, row.name);
	}
	if (index(names, request.name) < 0) die('candidate_changed');
	return { names, candidates };
};
