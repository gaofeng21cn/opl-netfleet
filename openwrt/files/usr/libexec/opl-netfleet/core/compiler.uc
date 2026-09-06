import { ordered_capabilities, ordered_regions, region_switch_margin, leaf_switch_margin, canonical_cidr } from "./policy.uc";

function clone(value) {
	const value_type = type(value);
	if (value_type == "array") {
		const result = [];
		for (let i = 0; i < length(value); i++) {
			push(result, clone(value[i]));
		}
		return result;
	}
	if (value_type == "object") {
		const result = {};
		const names = keys(value);
		for (let i = 0; i < length(names); i++) {
			result[names[i]] = clone(value[names[i]]);
		}
		return result;
	}
	return value;
};

function group_index(groups, name) {
	for (let i = 0; i < length(groups); i++) {
		if (groups[i]?.name == name) {
			return i;
		}
	}
	return -1;
};

function generated_name_conflicts(groups, name, permitted_index) {
	for (let i = 0; i < length(groups); i++) {
		if (groups[i]?.name == name && i != permitted_index) return true;
	}
	return false;
};

function binding_capability(binding) {
	return binding?.capability;
};

function binding_kind(binding) {
	return binding?.kind;
};

function rewritten_member(member, replacements) {
	return replacements[member] ?? member;
};

function rewrite_group_members(group, replacements) {
	if (type(group?.proxies) != "array") return group;
	for (let i = 0; i < length(group.proxies); i++) {
		group.proxies[i] = rewritten_member(group.proxies[i], replacements);
	}
	return group;
};

function rule_target(parts) {
	if (length(parts) < 2) return -1;
	let index = length(parts) - 1;
	if (lc(trim(parts[index])) == "no-resolve" && index > 0) index--;
	return index;
};

function rewrite_rule(rule, replacements) {
	if (type(rule) != "string") return rule;
	const parts = split(rule, ",");
	const index = rule_target(parts);
	if (index < 0) return rule;
	const target = trim(parts[index]);
	if (replacements[target] == null) return rule;
	parts[index] = replacements[target];
	return join(",", parts);
};

function rewrite_rule_list(rules, replacements) {
	if (type(rules) != "array") return;
	for (let i = 0; i < length(rules); i++) {
		rules[i] = rewrite_rule(rules[i], replacements);
	}
};

function capability_group_name(policy, capability) {
	return policy?.capabilities?.[capability]?.display_name ?? capability;
};

function inject_routing_rules(compiled, policy) {
	const configured = policy?.routing_rules ?? [];
	if (length(configured) == 0) return 0;
	const rendered = [];
	for (let i = 0; i < length(configured); i++) {
		const route = configured[i];
		const target = route.target == "direct" ? "DIRECT" : capability_group_name(policy, route.capability);
		if (route.kind == "ip_cidr") {
			const cidr = canonical_cidr(route.value);
			const kind = index(cidr, ":") >= 0 ? "IP-CIDR6" : "IP-CIDR";
			push(rendered, `${kind},${cidr},${target},no-resolve`);
		} else push(rendered, `DOMAIN-SUFFIX,${lc(route.value)},${target}`);
	}
	const source = type(compiled.rules) == "array" ? compiled.rules : [];
	let direct_prefix = 0;
	for (; direct_prefix < length(source); direct_prefix++) {
		const parts = split(source[direct_prefix], ",");
		const target = rule_target(parts);
		if (target < 0 || trim(parts[target]) != "DIRECT") break;
	}
	const result = [];
	for (let i = 0; i < direct_prefix; i++) {
		if (index(rendered, source[i]) < 0) push(result, source[i]);
	}
	for (let i = 0; i < length(rendered); i++) push(result, rendered[i]);
	for (let i = direct_prefix; i < length(source); i++) {
		if (index(rendered, source[i]) < 0) push(result, source[i]);
	}
	compiled.rules = result;
	return length(rendered);
};

function legacy_closure(original_groups, entry_group, entry_groups) {
	const known = {};
	for (let i = 0; i < length(original_groups); i++) {
		if (type(original_groups[i]?.name) == "string") known[original_groups[i].name] = original_groups[i];
	}
	const pending = [];
	const result = {};
	const members = known[entry_group]?.proxies ?? [];
	for (let i = 0; i < length(members); i++) {
		if (known[members[i]] != null && entry_groups[members[i]] != true) push(pending, members[i]);
	}
	while (length(pending) > 0) {
		const name = shift(pending);
		if (result[name] == true) continue;
		result[name] = true;
		const members = known[name]?.proxies ?? [];
		for (let i = 0; i < length(members); i++) {
			if (known[members[i]] != null && entry_groups[members[i]] != true) push(pending, members[i]);
		}
	}
	return result;
};

function normalize_policy_group(original, members) {
	const ordered = [];
	if (original?.proxies?.[0] == "DIRECT") push(ordered, "DIRECT");
	for (let i = 0; i < length(members); i++) {
		if (index(ordered, members[i]) < 0) push(ordered, members[i]);
	}
	const result = {
		name: original.name,
		type: "select",
		proxies: ordered,
		"empty-fallback": "DIRECT"
	};
	if (type(original.icon) == "string" && length(original.icon) > 0) result.icon = original.icon;
	return result;
};

function entry_alias(name, target) {
	return {
		name: name,
		type: "select",
		proxies: [target],
		"empty-fallback": "DIRECT",
		hidden: true
	};
};

function standardize_profile(compiled, original_groups, enabled_bindings, enabled_capabilities, generated_groups) {
	const entry_groups = {};
	const policy_groups = {};
	const replacements = {};
	for (let i = 0; i < length(enabled_bindings); i++) {
		const binding = enabled_bindings[i];
		const capability_name = generated_groups[binding.capability]?.name;
		if (binding.kind == "entry") {
			entry_groups[binding.base_group] = true;
			replacements[binding.base_group] = capability_name;
		} else {
			policy_groups[binding.base_group] = binding.capability;
		}
	}
	const legacy_groups = {};
	const entries = keys(entry_groups);
	for (let i = 0; i < length(entries); i++) {
		const entry = entries[i];
		const closure = legacy_closure(original_groups, entry, entry_groups);
		const names = keys(closure);
		for (let j = 0; j < length(names); j++) {
			const name = names[j];
			if (policy_groups[name] != null) continue;
			const replacement = replacements[entry];
			if (replacements[name] != null && replacements[name] != replacement) {
				return { ok: false, error: `legacy group belongs to multiple capabilities: ${name}` };
			}
			replacements[name] = replacement;
			legacy_groups[name] = true;
		}
	}

	const source_groups = compiled["proxy-groups"];
	const standardized = [];
	const entry_alias_groups = [];
	for (let i = 0; i < length(source_groups); i++) {
		const group = source_groups[i];
		const original_group = i < length(original_groups);
		if (original_group && (entry_groups[group?.name] == true || legacy_groups[group?.name] == true)) continue;
		const capability = policy_groups[group?.name];
		if (capability != null) {
			push(standardized, normalize_policy_group(group, generated_groups[capability].user_members));
		} else {
			push(standardized, rewrite_group_members(group, replacements));
		}
	}
	for (let i = 0; i < length(entries); i++) {
		const name = entries[i];
		const target = replacements[name];
		if (type(target) == "string" && name != target) {
			push(entry_alias_groups, entry_alias(name, target));
		}
	}

	rewrite_rule_list(compiled.rules, replacements);
	const sub_rules = compiled["sub-rules"];
	if (type(sub_rules) == "object") {
		const names = keys(sub_rules);
		for (let i = 0; i < length(names); i++) rewrite_rule_list(sub_rules[names[i]], replacements);
	}

	const ordered = [];
	const added = {};
	function add_group(name) {
		if (added[name] == true) return;
		const index = group_index(standardized, name);
		if (index < 0) return;
		push(ordered, standardized[index]);
		added[name] = true;
	};
	for (let i = 0; i < length(enabled_capabilities); i++) add_group(generated_groups[enabled_capabilities[i]].name);
	for (let i = 0; i < length(original_groups); i++) {
		const name = original_groups[i]?.name;
		if (policy_groups[name] != null) add_group(name);
	}
	for (let i = 0; i < length(original_groups); i++) {
		const name = original_groups[i]?.name;
		if (name != "GLOBAL") add_group(name);
	}
	for (let i = 0; i < length(standardized); i++) {
		const name = standardized[i]?.name;
		if (name != "GLOBAL") add_group(name);
	}
	for (let i = 0; i < length(entry_alias_groups); i++) {
		push(ordered, entry_alias_groups[i]);
	}
	compiled["proxy-groups"] = ordered;
	return { ok: true };
};

function has(object, key) {
	return type(object) == "object" && key in object;
};

function region_display_name(policy, region) {
	const configured = policy?.regions?.[region] ?? {};
	const name = configured.display_name ?? region;
	return configured.flag == null ? name : `${configured.flag} ${name}`;
};

function provider_display_name(provider_sources, provider_name) {
	return provider_sources?.[provider_name]?.display_name ?? provider_name;
};

function provider_group_name(capability_name, provider_name) {
	return `${capability_name} · ${provider_name}`;
};

function provider_tier_name(capability_name, role) {
	return `${capability_name} · ${role == "primary" ? "主用机场" : "备用机场"}`;
};

function provider_source_name(provider_name) {
	return `NETFLEET-SOURCE-${provider_name}`;
};

function region_group_name(capability_name, region_name, provider_name) {
	return `${capability_name} · ${region_name} · ${provider_name}`;
};

function region_aggregate_name(capability_name, region_name) {
	return `${capability_name} · ${region_name}`;
};

function region_layer_name(capability_name, region_name, layer) {
	return `${capability_name} · ${region_name} · ${layer == "primary" ? "主用" : "备用"}`;
};

function preferred_group_name(capability_name) {
	return `${capability_name} · 当前优选`;
};

function proxy_path_group_name(capability_name) {
	return `${capability_name} · 代理路径`;
};

function automatic_group_name(capability_name) {
	return `${capability_name} · 自动选优`;
};

function direct_guard_group_name() {
	return "NetFleet · 直连护栏";
};

function provider_before(policy, left, right) {
	const left_role = policy.providers?.[left]?.role == "reserve" ? 1 : 0;
	const right_role = policy.providers?.[right]?.role == "reserve" ? 1 : 0;
	return left_role != right_role ? left_role < right_role : left < right;
};

function ordered_enabled_providers(policy) {
	const result = [];
	const names = keys(policy.providers ?? {});
	for (let i = 0; i < length(names); i++) {
		const name = names[i];
		if (policy.providers[name]?.enabled != true) {
			continue;
		}
		push(result, name);
		for (let j = length(result) - 1; j > 0 && provider_before(policy, result[j], result[j - 1]); j--) {
			const previous = result[j - 1];
			result[j - 1] = result[j];
			result[j] = previous;
		}
	}
	return result;
};

function automatic_capability(policy, capability) {
	return policy?.capabilities?.[capability]?.mode == "automatic";
};

function capability_generation_order(policy, capabilities) {
	const ordered = [];
	const added = {};
	for (let pass = 0; pass < length(capabilities); pass++) {
		let progress = false;
		for (let i = 0; i < length(capabilities); i++) {
			const capability = capabilities[i];
			const parent = policy.capabilities?.[capability]?.prefer_region_from;
			if (added[capability] == true || (parent != null && added[parent] != true)) continue;
			push(ordered, capability);
			added[capability] = true;
			progress = true;
		}
		if (!progress) break;
	}
	return length(ordered) == length(capabilities) ? ordered : null;
};

function array_has(values, value) {
	return type(values) == "array" && index(values, value) >= 0;
};

function push_unique(values, value) {
	if (index(values, value) < 0) {
		push(values, value);
	}
};

function capability_allows_region(policy, capability, region, automatic) {
	const capability_policy = policy?.capabilities?.[capability] ?? {};
	const region_policy = policy?.regions?.[region];
	if (region_policy == null ||
		(type(capability_policy.allowed_regions) == "array" &&
			!array_has(capability_policy.allowed_regions, region)) ||
		array_has(capability_policy.excluded_regions, region)) {
		return false;
	}
	return !automatic || region_policy.mode != "manual_only";
};

function protected_probe(policy, probe_id) {
	const probes = policy?.fail_open?.probes ?? [];
	for (let i = 0; i < length(probes); i++) {
		if (probes[i]?.id == probe_id) {
			return probes[i];
		}
	}
	return null;
};

function mapping_filter(mapping) {
	if (mapping?.filter != null) {
		return mapping.filter;
	}
	return null;
};

// Subscription metadata entries are not usable proxy identities. Keep the
// cache as the source of truth and let Mihomo exclude these generic labels.
const PSEUDO_PROXY_FILTER = "(?i)(traffic[ _-]?reset|expire[ _-]?date|remaining[ _-]?traffic|available[ _-]?traffic|used[ _-]?traffic|total[ _-]?traffic|quota|套餐|到期|剩余流量|流量|有效期|重置|线路统计|过滤掉)";

export function compile(profile, policy, policy_source_digest, recovery_profile_digest, policy_digest, provider_profiles) {
	const groups = profile["proxy-groups"];
	if (type(groups) != "array") {
		return { ok: false, errors: ["policy source has no proxy-groups array"] };
	}

	const binding_names = keys(policy.bindings);
	const enabled_bindings = [];
	const enabled_capabilities = [];
	const bindings_by_capability = {};
	for (let i = 0; i < length(binding_names); i++) {
		const base_group = binding_names[i];
		const policy_binding = policy.bindings[base_group];
		const capability = binding_capability(policy_binding);
		if (policy.capabilities?.[capability]?.enabled != true) {
			continue;
		}
		const base_index = group_index(groups, base_group);
		if (base_index < 0) {
			return { ok: false, errors: [`bound group not found: ${base_group}`] };
		}
		const original = groups[base_index];
		if (type(original.proxies) != "array" || length(original.proxies) == 0) {
			return { ok: false, errors: [`bound group has no selectable members: ${base_group}`] };
		}
		const binding = {
			base_group: base_group,
			capability: capability,
			kind: binding_kind(policy_binding),
			base_index: base_index
		};
		push(enabled_bindings, binding);
		if (bindings_by_capability[capability] == null) {
			bindings_by_capability[capability] = [];
		}
		push(bindings_by_capability[capability], binding);
	}
	const capability_names = ordered_capabilities(policy);
	for (let i = 0; i < length(capability_names); i++) {
		const capability = capability_names[i];
		if (policy.capabilities[capability]?.enabled == true && bindings_by_capability[capability] != null) {
			push(enabled_capabilities, capability);
		}
	}
	if (length(enabled_bindings) == 0) {
		return { ok: false, errors: ["no enabled capability binding"] };
	}
	const generation_capabilities = capability_generation_order(policy, enabled_capabilities);
	if (generation_capabilities == null) {
		return { ok: false, errors: ["enabled capability generation dependency is unavailable"] };
	}

	const compiled = clone(profile);
	const compiled_groups = compiled["proxy-groups"];
	const compiled_provider_sources = compiled["proxy-providers"] == null ? {} : clone(compiled["proxy-providers"]);
	if (type(compiled_provider_sources) != "object") {
		return { ok: false, errors: ["policy source proxy-providers must be an object"] };
	}

	const latency_check = policy.checks?.latency;
	const healthcheck = policy.fail_open?.healthcheck;
	if (latency_check == null || healthcheck == null) {
		return { ok: false, errors: ["checks.latency and fail_open.healthcheck are required"] };
	}
	const path_probe = protected_probe(policy, healthcheck.path_probe_id);
	const guard_probe = protected_probe(policy, healthcheck.guard_probe_id);
	if (path_probe == null || guard_probe == null) {
		return { ok: false, errors: ["fail_open healthcheck references an unknown protected probe"] };
	}
	const direct_guard = direct_guard_group_name();
	if (group_index(compiled_groups, direct_guard) >= 0) {
		return { ok: false, errors: [`generated direct guard identity already exists: ${direct_guard}`] };
	}
	push(compiled_groups, {
		name: direct_guard,
		type: "select",
		proxies: ["DIRECT"],
		"empty-fallback": "DIRECT",
		hidden: true
	});
	const provider_names = ordered_enabled_providers(policy);
	const provider_sources = {};
	for (let i = 0; i < length(provider_names); i++) {
		const provider_name = provider_names[i];
		const provider = policy.providers[provider_name];
		const source = provider_profiles == null ? null : provider_profiles[provider_name];
		if (source == null || type(source.profile) != "object" || type(source.profile.proxies) != "array" || length(source.profile.proxies) == 0) {
			return { ok: false, errors: [`provider cache has no proxies: ${provider_name}`] };
		}

		const source_name = provider_source_name(provider_name);
		if (has(compiled_provider_sources, source_name)) {
			return { ok: false, errors: [`generated provider source identity already exists: ${provider_name}`] };
		}
		compiled_provider_sources[source_name] = {
			type: "file",
			path: source.runtime_path ?? source.path,
			"exclude-filter": PSEUDO_PROXY_FILTER,
			"health-check": {
				enable: false,
				url: latency_check.url,
				timeout: latency_check.timeout_ms,
				lazy: true,
				"expected-status": latency_check.expected_status
			}
		};
		provider_sources[provider_name] = {
			section: provider.section,
			source: source.runtime_path ?? source.path,
			role: provider.role,
			display_name: source.display_name ?? provider_name,
			source_name: source_name
		};
	}

	const generated_groups = {};
	for (let binding_index = 0; binding_index < length(generation_capabilities); binding_index++) {
		const capability = generation_capabilities[binding_index];
		const capability_bindings = bindings_by_capability[capability] ?? [];
		let binding = null;
		let entry_count = 0;
		const policy_groups = [];
		const business_routes = [];
		const base_groups = [];
		for (let i = 0; i < length(capability_bindings); i++) {
			const item = capability_bindings[i];
			push(base_groups, item.base_group);
			if (item.kind == "entry") {
				binding = item;
				entry_count++;
			}
			else {
				push(policy_groups, item.base_group);
				push(business_routes, {
					name: item.base_group,
					default_route: groups[item.base_index]?.proxies?.[0] == "DIRECT" ? "direct" : "capability"
				});
			}
		}
		if (entry_count != 1) {
			return { ok: false, errors: [`capability must have exactly one entry binding: ${capability}`] };
		}
		const base_group = binding.base_group;
		const base_index = binding.base_index;
		const original = groups[base_index];

		const automatic = automatic_capability(policy, capability);
		const leaf_tolerance = leaf_switch_margin(policy, capability);
		const capability_name = capability_group_name(policy, capability);
		const preferred_group = preferred_group_name(capability_name);
		const proxy_path_group = proxy_path_group_name(capability_name);
		const automatic_group = automatic ? automatic_group_name(capability_name) : null;
		const provider_groups = [];
		const provider_groups_by_role = { primary: [], reserve: [] };
		const provider_ids_by_role = { primary: [], reserve: [] };
		const candidate_groups = [];
		const candidates_by_region = {};
		const generated_providers = {};
		let primary_provider_count = 0;

		const permitted_name_index = capability_name == base_group ? base_index : -1;
		if (generated_name_conflicts(compiled_groups, capability_name, permitted_name_index)) {
			return { ok: false, errors: [`generated capability display name already exists: ${capability_name}`] };
		}
		for (let i = 0; i < length(provider_names); i++) {
			const provider_name = provider_names[i];
			const provider = policy.providers[provider_name];
			const source = provider_sources[provider_name];
			const source_display = provider_display_name(provider_sources, provider_name);
			const mappings = policy.provider_regions?.[provider_name] ?? [];
			const authorized_filters = [];
			for (let j = 0; j < length(mappings); j++) {
				const mapping = mappings[j];
				if (!capability_allows_region(policy, capability, mapping.region, automatic)) continue;
				const filter = mapping_filter(mapping);
				if (filter == null) {
					return { ok: false, errors: [`authorized mapping has no filter: ${capability}/${provider_name}/${mapping.region}`] };
				}
				push_unique(authorized_filters, filter);
				const region_display = region_display_name(policy, mapping.region);
				const region_group = region_group_name(capability_name, region_display, source_display);
				if (group_index(compiled_groups, region_group) >= 0) {
					return { ok: false, errors: [`generated region group identity already exists: ${region_group}`] };
				}
				const candidate = {
					name: region_group,
					provider: provider_name,
					provider_display_name: source_display,
					region: mapping.region,
					region_display_name: region_display,
					role: provider.role,
					filter: filter,
					group: region_group
				};
				push(candidate_groups, candidate);
				if (candidates_by_region[mapping.region] == null) {
					candidates_by_region[mapping.region] = { primary: [], reserve: [] };
				}
				push(candidates_by_region[mapping.region][provider.role], region_group);
				push(compiled_groups, {
					name: region_group,
					type: "url-test",
					use: [source.source_name],
					filter: filter,
					"empty-fallback": "DIRECT",
					url: latency_check.url,
					"expected-status": latency_check.expected_status,
					timeout: latency_check.timeout_ms,
					"max-failed-times": healthcheck.max_failed_times,
					tolerance: leaf_tolerance,
					hidden: true
				});
			}
			if (length(authorized_filters) == 0) continue;

			const group_name = provider_group_name(capability_name, source_display);
			if (group_index(compiled_groups, group_name) >= 0) {
				return { ok: false, errors: [`generated provider group identity already exists: ${group_name}`] };
			}
			generated_providers[provider_name] = clone(source);
			generated_providers[provider_name].group = group_name;
			push(provider_groups, group_name);
			push(provider_groups_by_role[provider.role], group_name);
			push(provider_ids_by_role[provider.role], provider_name);
			if (provider.role == "primary") primary_provider_count++;
			push(compiled_groups, {
				name: group_name,
				type: "url-test",
				use: [source.source_name],
				filter: join("`", authorized_filters),
				"empty-fallback": "DIRECT",
				url: path_probe.url,
				"expected-status": path_probe.expected_status,
				timeout: healthcheck.timeout_ms,
				"max-failed-times": healthcheck.max_failed_times,
				tolerance: leaf_tolerance,
				hidden: true
			});
		}
		if (length(provider_groups) == 0) {
			return { ok: false, errors: [`no authorized provider groups were generated: ${capability}`] };
		}
		if (primary_provider_count == 0) {
			return { ok: false, errors: [`no authorized primary provider was generated: ${capability}`] };
		}
		const capability_members = [];
		for (let i = 0; i < length(candidate_groups); i++) push(capability_members, candidate_groups[i].group);
		const region_groups = [];
		const shared_region_capability = policy.capabilities[capability]?.prefer_region_from;
		const shared_regions = shared_region_capability == null ? null : generated_groups[shared_region_capability]?.region_groups;
		if (shared_region_capability != null && type(shared_regions) != "array") {
			return { ok: false, errors: [`shared region capability was not generated: ${shared_region_capability}`] };
		}
		for (let i = 0; shared_region_capability != null && i < length(shared_regions); i++) {
			if (capability_allows_region(policy, capability, shared_regions[i]?.region, automatic)) {
				push(region_groups, clone(shared_regions[i]));
			}
		}
		const region_names = shared_region_capability == null ? ordered_regions(policy) : [];
		for (let i = 0; i < length(region_names); i++) {
			const region_id = region_names[i];
			const layers = candidates_by_region[region_id];
			if (layers == null || length(layers.primary) + length(layers.reserve) == 0) continue;
			const region_display = region_display_name(policy, region_id);
			const aggregate = region_aggregate_name(capability_name, region_display);
			const aggregate_members = [];
			const layer_names = {};
			for (let layer_index = 0; layer_index < 2; layer_index++) {
				const layer = layer_index == 0 ? "primary" : "reserve";
				if (length(layers[layer]) == 0) continue;
				const layer_name = region_layer_name(capability_name, region_display, layer);
				if (group_index(compiled_groups, layer_name) >= 0) {
					return { ok: false, errors: [`generated region layer identity already exists: ${layer_name}`] };
				}
				push(compiled_groups, {
					name: layer_name,
					type: "url-test",
					proxies: layers[layer],
					"empty-fallback": "DIRECT",
					url: latency_check.url,
					"expected-status": latency_check.expected_status,
					timeout: latency_check.timeout_ms,
					"max-failed-times": healthcheck.max_failed_times,
					tolerance: 0,
					hidden: true
				});
				layer_names[layer] = layer_name;
				push(aggregate_members, layer_name);
			}
			push(aggregate_members, direct_guard);
			push(compiled_groups, {
				name: aggregate,
				type: "fallback",
				proxies: aggregate_members,
				"empty-fallback": "DIRECT",
				url: path_probe.url,
				"expected-status": path_probe.expected_status,
				timeout: healthcheck.timeout_ms,
				interval: healthcheck.interval_seconds,
				"max-failed-times": healthcheck.max_failed_times,
				lazy: true,
				hidden: true
			});
			push(region_groups, {
				region: region_id,
				display_name: region_display,
				name: aggregate,
				primary_name: layer_names.primary ?? null,
				reserve_name: layer_names.reserve ?? null,
				members: aggregate_members
			});
		}
		if (length(capability_members) == 0 || length(region_groups) == 0) {
			return { ok: false, errors: [`no selectable members were generated: ${capability}`] };
		}

		push(compiled_groups, {
			name: preferred_group,
			type: "select",
			proxies: capability_members,
			"empty-fallback": "DIRECT",
			url: latency_check.url,
			"expected-status": latency_check.expected_status,
			timeout: latency_check.timeout_ms,
			"max-failed-times": healthcheck.max_failed_times,
			hidden: true
		});
		const proxy_members = [preferred_group];
		const fail_open_stages = [{ kind: "preferred", group: preferred_group, provider_ids: [] }];
		for (let role_index = 0; role_index < 2; role_index++) {
			const role = role_index == 0 ? "primary" : "reserve";
			const members = provider_groups_by_role[role];
			if (length(members) == 0) continue;
			const tier_name = provider_tier_name(capability_name, role);
			if (group_index(compiled_groups, tier_name) >= 0) {
				return { ok: false, errors: [`generated provider tier identity already exists: ${tier_name}`] };
			}
			push(compiled_groups, {
				name: tier_name,
				type: "url-test",
				proxies: members,
				"empty-fallback": "DIRECT",
				url: path_probe.url,
				"expected-status": path_probe.expected_status,
				timeout: healthcheck.timeout_ms,
				"max-failed-times": healthcheck.max_failed_times,
				tolerance: 0,
				hidden: true
			});
			push(proxy_members, tier_name);
			push(fail_open_stages, {
				kind: "provider_tier",
				role: role,
				group: tier_name,
				provider_ids: clone(provider_ids_by_role[role])
			});
		}
		push(fail_open_stages, { kind: "direct", group: direct_guard, provider_ids: [] });
		push(compiled_groups, {
			name: proxy_path_group,
			type: "fallback",
			proxies: proxy_members,
			"empty-fallback": "DIRECT",
			url: path_probe.url,
			"expected-status": path_probe.expected_status,
			timeout: healthcheck.timeout_ms,
			interval: healthcheck.interval_seconds,
			"max-failed-times": healthcheck.max_failed_times,
			lazy: true,
			hidden: true
		});
		const automatic_members = [proxy_path_group, direct_guard];
		if (automatic) {
			push(compiled_groups, {
				name: automatic_group,
				type: "fallback",
				proxies: automatic_members,
				"empty-fallback": "DIRECT",
				url: guard_probe.url,
				"expected-status": guard_probe.expected_status,
				timeout: healthcheck.timeout_ms,
				interval: healthcheck.interval_seconds,
				"max-failed-times": healthcheck.max_failed_times,
				lazy: true,
				hidden: true
			});
		}
		const user_members = [];
		if (automatic) push(user_members, automatic_group);
		for (let i = 0; i < length(region_groups); i++) push(user_members, region_groups[i].name);
		push(user_members, "DIRECT");
		push(compiled_groups, {
			name: capability_name,
			type: "select",
			proxies: user_members,
			"empty-fallback": "DIRECT"
		});
		generated_groups[capability] = {
			name: capability_name,
			automatic_name: automatic_group,
			selector_name: preferred_group,
			proxy_path_name: proxy_path_group,
			base_type: original.type,
			base_group: base_group,
			base_groups: base_groups,
			entry_group: base_group,
			policy_groups: policy_groups,
			business_routes: business_routes,
			members: capability_members,
			user_members: user_members,
			region_groups: region_groups,
			proxy_members: proxy_members,
			fallback_members: automatic_members,
			fail_open_stages: fail_open_stages,
			direct_name: "DIRECT",
			direct_guard_name: direct_guard,
			providers: generated_providers,
			mode: automatic ? "automatic" : "manual",
			prefer_region_from: policy.capabilities[capability]?.prefer_region_from ?? null,
			candidate_groups: candidate_groups,
			region_switch_margin_ms: region_switch_margin(policy, capability),
			leaf_switch_margin_ms: leaf_tolerance
		};
	}
	const routing_rule_count = inject_routing_rules(compiled, policy);
	const standardized = standardize_profile(compiled, groups, enabled_bindings, enabled_capabilities, generated_groups);
	if (!standardized.ok) return { ok: false, errors: [standardized.error] };
	compiled["proxy-providers"] = compiled_provider_sources;
	const manifest = {
		kind: "opl-netfleet-manifest",
		schema_version: 2,
		state: "staged",
		provider_mode: "file-provider",
		policy_source: {
			kind: policy.policy_source.kind,
			ref: policy.policy_source.ref,
			sha256: policy_source_digest
		},
		recovery_profile: {
			ref: policy.recovery_profile.ref,
			sha256: recovery_profile_digest
		},
		policy_sha256: policy_digest,
		routing_rule_count: routing_rule_count,
		generated_groups: generated_groups
	};

	return { ok: true, profile: compiled, manifest: manifest };
};
