

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let sorted_keys, automatic_capability_order, automatic_selectors_ready, initial_choice, initial_user_choice, provider_sources, automatic_provider_sources, automatic_mode_active;



sorted_keys = function(object) {
	const result = [];
	const names = keys(object ?? {});
	for (let i = 0; i < length(names); i++) {
		push(result, names[i]);
		for (let j = length(result) - 1; j > 0 && result[j] < result[j - 1]; j--) {
			const previous = result[j - 1];
			result[j - 1] = result[j];
			result[j] = previous;
		}
	}
	return result;
};

automatic_capability_order = function(policy, manifest) {
	const pending = [];
	const generated = manifest?.generated_groups ?? {};
	const names = sorted_keys(generated);
	for (let i = 0; i < length(names); i++) {
		const name = names[i];
		if (policy.capabilities?.[name]?.enabled == true && generated[name]?.mode == "automatic") {
			push(pending, name);
		}
	}
	const result = [];
	const added = {};
	for (let pass = 0; pass < length(pending); pass++) {
		let progress = false;
		for (let i = 0; i < length(pending); i++) {
			const name = pending[i];
			const parent = policy.capabilities?.[name]?.prefer_region_from;
			if (added[name] == true || (parent != null && added[parent] != true)) {
				continue;
			}
			push(result, name);
			added[name] = true;
			progress = true;
		}
		if (!progress) break;
	}
	return length(result) == length(pending) ? result : [];
};

automatic_selectors_ready = function(readback, manifest, capability_names) {
	for (let i = 0; i < length(capability_names); i++) {
		const entry = manifest?.generated_groups?.[capability_names[i]];
		if (type(entry?.name) != "string" || type(entry?.automatic_name) != "string" ||
			readback?.selected?.[entry.name] != entry.automatic_name) {
			return false;
		}
	}
	return true;
};

initial_choice = function(manifest, capability) {
	const entry = manifest?.generated_groups?.[capability];
	const groups = entry?.candidate_groups ?? [];
	for (let i = 0; i < length(groups); i++) {
		if (groups[i]?.role == "primary") {
			return groups[i].name;
		}
	}
	return entry?.members?.[0] ?? null;
};

initial_user_choice = function(entry, candidate_group) {
	if (entry?.mode == "automatic") return entry?.automatic_name;
	let candidate_region = null;
	const candidates = entry?.candidate_groups ?? [];
	for (let i = 0; i < length(candidates); i++) {
		if (candidates[i]?.name == candidate_group) candidate_region = candidates[i]?.region;
	}
	const regions = entry?.region_groups ?? [];
	for (let i = 0; i < length(regions); i++) {
		if (regions[i]?.region == candidate_region) return regions[i].name;
	}
	return regions[0]?.name ?? entry?.direct_name ?? "DIRECT";
};

provider_sources = function(entry) {
	const result = [];
	const providers = entry?.providers ?? {};
	const names = keys(providers);
	for (let i = 0; i < length(names); i++) {
		const source = providers[names[i]]?.source_name;
		if (type(source) == "string" && length(source) > 0) {
			push(result, source);
		}
	}
	return result;
};

automatic_provider_sources = function(manifest, capability_names) {
	const result = [];
	const seen = {};
	for (let i = 0; i < length(capability_names); i++) {
		const sources = provider_sources(manifest?.generated_groups?.[capability_names[i]]);
		for (let j = 0; j < length(sources); j++) {
			if (seen[sources[j]] != true) {
				seen[sources[j]] = true;
				push(result, sources[j]);
			}
		}
	}
	return result;
};

automatic_mode_active = function(manifest, capability_names, state) {
	for (let i = 0; i < length(capability_names); i++) {
		const entry = manifest?.generated_groups?.[capability_names[i]];
		if (entry?.automatic_name == null || state?.proxies?.[entry?.name]?.now != entry.automatic_name) {
			return false;
		}
	}
	return length(capability_names) > 0;
};

return { sorted_keys, automatic_capability_order, automatic_selectors_ready, initial_choice, initial_user_choice, provider_sources, automatic_provider_sources, automatic_mode_active };
};
