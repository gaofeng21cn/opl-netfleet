import { is_proxy_leaf, provider_group_current_leaf } from "./selector.uc";
import { identity_matches, measurement_identity } from "./evidence.uc";
import { ordered_capabilities, ordered_regions, region_switch_margin, leaf_switch_margin } from "./policy.uc";

function evidence_delay(evidence, group) {
	const entries = evidence?.entries ?? [];
	for (let i = 0; i < length(entries); i++) {
		if (entries[i]?.candidate == group && entries[i]?.ok == true && type(entries[i]?.delay_ms) == "int") {
			return entries[i].delay_ms;
		}
	}
	return null;
};

function current_evidence(evidence, policy, manifest, capability) {
	const identity = evidence?.identity;
	if (!identity_matches(identity, measurement_identity(policy, manifest))) {
		return null;
	}
	if (evidence?.schema_version == 3) {
		return evidence?.capabilities?.[capability] ?? null;
	}
	return evidence?.schema_version == 2 && evidence?.decision?.capability == capability ? evidence : null;
};

function aggregate_evidence(evidence, dimension, id) {
	const aggregate = evidence?.[dimension]?.[id];
	if (type(aggregate?.last_best_delay_ms) == "int" &&
		type(aggregate?.total_best_delay_ms) == "int" &&
		type(aggregate?.sample_count) == "int" && aggregate.sample_count > 0 &&
		type(aggregate?.sampled_at) == "int") {
		return {
			last_best_delay_ms: aggregate.last_best_delay_ms,
			average_best_delay_ms: int((aggregate.total_best_delay_ms + int(aggregate.sample_count / 2)) /
				aggregate.sample_count),
			sample_count: aggregate.sample_count,
			sampled_at: aggregate.sampled_at
		};
	}

	return null;
};

function follow_path(proxy_state, start) {
	const path = [];
	const seen = {};
	let current = start;
	for (let i = 0; i < 32 && type(current) == "string" && length(current) > 0; i++) {
		if (seen[current] == true) {
			break;
		}
		seen[current] = true;
		push(path, current);
		const next = proxy_state?.[current]?.now;
		if (type(next) != "string" || length(next) == 0 || next == current) {
			break;
		}
		current = next;
	}
	return path;
};

function candidate_by_group(entry, group) {
	const groups = entry?.candidate_groups ?? [];
	for (let i = 0; i < length(groups); i++) {
		if (groups[i]?.name == group) {
			return groups[i];
		}
	}
	return null;
};

function provider_by_group(entry, group) {
	const providers = entry?.providers ?? {};
	const names = keys(providers);
	for (let i = 0; i < length(names); i++) {
		if (providers[names[i]]?.group == group) {
			return names[i];
		}
	}
	return null;
};

function region_by_group(entry, group) {
	const regions = entry?.region_groups ?? [];
	for (let i = 0; i < length(regions); i++) {
		if (regions[i]?.name == group) return regions[i];
	}
	return null;
};

function binding_groups(policy, capability) {
	const result = [];
	const names = keys(policy?.bindings ?? {});
	for (let i = 0; i < length(names); i++) {
		if (policy.bindings[names[i]]?.capability == capability) {
			push(result, names[i]);
		}
	}
	return result;
};

function business_routes(entry, proxy_state) {
	if (type(entry?.business_routes) == "array") {
		return entry.business_routes;
	}

	const result = [];
	const groups = entry?.policy_groups ?? [];
	for (let i = 0; i < length(groups); i++) {
		const name = groups[i];
		const members = proxy_state?.[name]?.all;
		push(result, {
			name: name,
			default_route: type(members) == "array" && length(members) > 0 ?
				(members[0] == "DIRECT" ? "direct" : "capability") : null
		});
	}
	return result;
};

function binding_entry(policy, capability) {
	const names = keys(policy?.bindings ?? {});
	for (let i = 0; i < length(names); i++) {
		const binding = policy.bindings[names[i]];
		if (binding?.capability == capability && binding?.kind == "entry") return names[i];
	}
	return null;
};

function provider_nodes(provider_state, source_name) {
	const nodes = provider_state?.[source_name]?.proxies;
	if (type(nodes) != "array") {
		return null;
	}
	const result = {};
	for (let i = 0; i < length(nodes); i++) {
		const node = nodes[i];
		if (type(node?.name) == "string" && length(trim(node.name)) > 0) {
			result[node.name] = node?.alive == true;
		}
	}
	return result;
};

function group_nodes(proxy_state, provider_state, source_name, group_name) {
	const members = proxy_state?.[group_name]?.all;
	if (type(members) != "array") {
		return { known: false, members: {} };
	}
	const provider_members = provider_nodes(provider_state, source_name);
	const result = {};
	for (let i = 0; i < length(members); i++) {
		const member = members[i];
		if (provider_members != null && member in provider_members) {
			result[member] = provider_members[member];
		} else if (is_proxy_leaf(proxy_state, member)) {
			result[member] = proxy_state?.[member]?.alive == true;
		} else {
			return { known: false, members: {} };
		}
	}
	return { known: true, members: result };
};

function has_available_node(nodes) {
	const names = keys(nodes?.members ?? {});
	for (let i = 0; i < length(names); i++) {
		if (nodes.members[names[i]] == true) {
			return true;
		}
	}
	return false;
};

function last_leaf(proxy_state, path) {
	if (length(path) == 0) {
		return null;
	}
	const name = path[length(path) - 1];
	return is_proxy_leaf(proxy_state, name) ? name : null;
};

function path_alive(proxy_state, path) {
	if (length(path) == 0) return false;
	for (let i = 0; i < length(path); i++) {
		if (proxy_state?.[path[i]] == null || proxy_state[path[i]].alive == false) return false;
	}
	return true;
};

function native_path_for_capability(native, capability) {
	const paths = native?.paths ?? [];
	for (let i = 0; i < length(paths); i++) {
		if (paths[i]?.capability_id == capability) return paths[i];
	}
	return null;
};

function native_capability_runtime(native, capability) {
	const path = native_path_for_capability(native, capability);
	if (native?.mode == "native_profile") {
		return {
			data_path: "native_profile",
			user_mode: "native_profile",
			path: path?.path ?? [],
			selected_group: path?.path?.[1] ?? path?.base_group ?? null,
			leaf: path?.leaf ?? null,
			alive: path?.alive == true
		};
	}
	return {
		data_path: native?.mode ?? "profile_unavailable",
		user_mode: "native_profile",
		path: [],
		selected_group: null,
		leaf: null,
		alive: native?.mode == "passthrough"
	};
};

function native_runtime(policy, state, owner) {
	const result = {
		mode: "profile_unavailable",
		profile: owner.profile ?? null,
		profile_display_name: owner.profile_display_name ?? owner.profile ?? null,
		paths: []
	};
	if (owner.active == true) {
		result.mode = "netfleet_active";
		return result;
	}
	if (owner.cleanup?.ok == true && owner.nikki_enabled == false) {
		result.mode = "passthrough";
		return result;
	}
	if (owner.nikki_enabled != true) {
		result.mode = "nikki_stopped";
		return result;
	}
	if (owner.mihomo_running != true) {
		result.mode = "mihomo_stopped";
		return result;
	}
	const proxy_state = state?.proxies;
	if (proxy_state == null) {
		result.mode = "controller_unavailable";
		return result;
	}
	result.mode = "native_profile";
	const capabilities = ordered_capabilities(policy);
	for (let i = 0; i < length(capabilities); i++) {
		const capability = capabilities[i];
		const group = binding_entry(policy, capability);
		if (group == null) continue;
		const path = follow_path(proxy_state, group);
		const leaf = last_leaf(proxy_state, path);
		push(result.paths, {
			base_group: group,
			capability_id: capability,
			state: proxy_state[group] == null ? "group_unavailable" : "available",
			path: path,
			leaf: leaf,
			alive: proxy_state[group] != null && leaf != null && path_alive(proxy_state, path)
		});
	}
	return result;
};

function direct_name(entry) {
	return entry?.direct_name ?? "DIRECT";
};

function is_direct_terminal(proxy_state, value, entry) {
	return value == direct_name(entry) &&
		lc(`${proxy_state?.[value]?.type ?? ""}`) == "direct";
};

function path_has_direct(proxy_state, path, entry) {
	for (let i = 0; i < length(path); i++) {
		if (is_direct_terminal(proxy_state, path[i], entry)) {
			return true;
		}
	}
	return false;
};

export function resolve_runtime(entry, state) {
	const proxy_state = state?.proxies ?? {};
	const provider_state = state?.providers ?? {};
	const start = proxy_state?.[entry?.base_group] != null ? entry.base_group : entry?.name;
	const path = follow_path(proxy_state, start);
	const visible_choice = proxy_state?.[entry?.name]?.now ?? null;
	const manual_region = region_by_group(entry, visible_choice);
	const user_mode = visible_choice == entry?.automatic_name ? "automatic" :
		visible_choice == direct_name(entry) ? "direct" : manual_region == null ? "unknown" : "manual_region";
	const preferred_group = proxy_state?.[entry?.selector_name]?.now ?? null;
	const preferred_candidate = candidate_by_group(entry, preferred_group);
	const direct = path_has_direct(proxy_state, path, entry);
	let data_path = "unknown";
	let provider_id = null;
	let region_id = null;
	let role = null;
	let provider_source = null;
	let selected_group = length(path) > 1 ? path[1] : null;
	let selected_candidate = null;

	if (direct) {
		// A terminal DIRECT member is deliberately independent of failed proxy
		// ancestors.  It is the last available data-plane path, not a proxy leaf.
		data_path = user_mode == "direct" ? "direct_manual" : "direct_fallback";
		selected_group = direct_name(entry);
	} else {
		for (let i = 0; i < length(path); i++) {
			const candidate = candidate_by_group(entry, path[i]);
			if (candidate != null) {
				selected_candidate = candidate;
				data_path = user_mode == "manual_region" ? "manual_region" : "preferred";
				provider_id = candidate.provider;
				region_id = candidate.region;
				role = candidate.role;
				provider_source = entry?.providers?.[provider_id]?.source_name ?? null;
				selected_group = candidate.name;
				break;
			}
			const provider = provider_by_group(entry, path[i]);
			if (provider != null) {
				data_path = "provider_fallback";
				provider_id = provider;
				role = entry?.providers?.[provider]?.role ?? null;
				provider_source = entry?.providers?.[provider]?.source_name ?? null;
				selected_group = path[i];
				break;
			}
		}
	}

	const leaf = direct ? direct_name(entry) :
		(data_path == "preferred" || data_path == "manual_region" || data_path == "provider_fallback" ?
			provider_group_current_leaf(proxy_state, provider_state, provider_source, selected_group) :
			last_leaf(proxy_state, path));
	const preferred_source = entry?.providers?.[preferred_candidate?.provider]?.source_name ?? null;
	const preferred_leaf = preferred_candidate == null ? null :
		provider_group_current_leaf(proxy_state, provider_state, preferred_source, preferred_group);
	// Mihomo can leave an ancestor selector at alive=false while its selected
	// provider group already resolves to a manifest-bound leaf. The healthy
	// terminal URLTest group is the authoritative current-path readback; stale
	// ancestor or provider-inventory health must not override it.
	const alive = direct ? true : length(path) > 1 && leaf != null;
	return {
		data_path: data_path,
		user_mode: user_mode,
		visible_choice: visible_choice,
		path: path,
		selected_group: selected_group,
		provider_id: provider_id,
		region_id: region_id,
		role: role,
		leaf: leaf,
		alive: alive,
		preferred_group: preferred_group,
		preferred_provider_id: preferred_candidate?.provider ?? null,
		preferred_region_id: preferred_candidate?.region ?? null,
		preferred_leaf: preferred_leaf
	};
};

export function build(policy, manifest, state, evidence, owner) {
	const proxy_state = state?.proxies ?? {};
	const provider_state = state?.providers ?? {};
	const capabilities = [];
	const providers = {};
	const regions = {};
	const provider_names = keys(policy.providers ?? {});
	for (let i = 0; i < length(provider_names); i++) {
		const name = provider_names[i];
		const provider = policy.providers[name];
		providers[name] = {
			id: name,
			display_name: owner.provider_names?.[name] ?? name,
			role: provider?.role ?? "primary",
			billing: provider?.billing ?? "unknown",
			quota: owner.quotas?.[name] ?? { state: provider?.enabled == true ? "unknown" : "disabled" },
			candidate_count: 0,
			available_count: 0,
			region_count: 0,
			available_region_count: 0,
			best_delay_ms: null,
			last_best_delay_ms: null,
			average_best_delay_ms: null,
			delay_sample_count: 0,
			delay_sampled_at: null,
			selected: false
		};
	}
	const region_names = ordered_regions(policy);
	for (let i = 0; i < length(region_names); i++) {
		const name = region_names[i];
		regions[name] = {
			id: name,
			display_name: policy.regions[name]?.flag == null ?
				policy.regions[name]?.display_name ?? name :
				`${policy.regions[name].flag} ${policy.regions[name]?.display_name ?? name}`,
			mode: policy.regions[name]?.mode ?? "automatic",
			candidate_count: 0,
			available_count: 0,
			provider_count: 0,
			available_provider_count: 0,
			node_count: null,
			available_node_count: null,
			node_count_known: false,
			best_delay_ms: null,
			last_best_delay_ms: null,
			average_best_delay_ms: null,
			delay_sample_count: 0,
			delay_sampled_at: null,
			selected: false
		};
	}
	const region_nodes = {};
	const provider_regions = {};
	const region_providers = {};
	const generated = manifest?.generated_groups ?? {};
	const native = native_runtime(policy, state, owner);
	const capability_names = ordered_capabilities(policy);
	const automatic_capability_ids = [];
	let automatic_capability_id = null;
	for (let i = 0; i < length(capability_names); i++) {
		const name = capability_names[i];
		const capability_policy = policy.capabilities[name] ?? {};
		if (capability_policy.enabled == true && capability_policy.mode == "automatic") {
			push(automatic_capability_ids, name);
			if (capability_policy.prefer_region_from == null) automatic_capability_id = name;
		}
	}
	const root_evidence = current_evidence(evidence, policy, manifest, automatic_capability_id);
	for (let i = 0; i < length(capability_names); i++) {
		const name = capability_names[i];
		const capability_policy = policy.capabilities[name] ?? {};
		const entry = generated[name];
		const display_evidence = current_evidence(evidence, policy, manifest, name);
		if (entry == null) {
			const base_groups = binding_groups(policy, name);
			const inactive = owner.active != true && owner.netfleet_present != true ?
				native_capability_runtime(native, name) : null;
			push(capabilities, {
				id: name,
				display_name: capability_policy.display_name ?? name,
				enabled: capability_policy.enabled == true,
				compiled: false,
				mode: capability_policy.mode ?? "manual",
				group: null,
				base_group: base_groups[0] ?? null,
				base_groups: base_groups,
				business_routes: [],
				data_path: inactive?.data_path ?? (capability_policy.enabled == true ? "not_compiled" : "disabled"),
				user_mode: inactive?.user_mode ?? null,
				runtime_path: inactive?.path ?? [],
				selected_group: inactive?.selected_group ?? null,
				provider_id: null,
				region_id: null,
				role: null,
				leaf: inactive?.leaf ?? null,
				alive: inactive?.alive == true,
				preferred_group: null,
				preferred_provider_id: null,
				preferred_region_id: null,
				preferred_leaf: null,
				allowed_regions: capability_policy.allowed_regions ?? null,
				excluded_regions: capability_policy.excluded_regions ?? [],
				prefer_region_from: capability_policy.prefer_region_from ?? null,
				fail_open_stages: [],
				region_switch_margin_ms: region_switch_margin(policy, name),
				leaf_switch_margin_ms: leaf_switch_margin(policy, name),
				reason: { kind: capability_policy.enabled == true ? "not_compiled" : "disabled" }
			});
			continue;
		}
		const runtime = resolve_runtime(entry, state);
		if (owner.active != true && owner.netfleet_present != true) {
			const inactive = native_capability_runtime(native, name);
			runtime.data_path = inactive.data_path;
			runtime.user_mode = inactive.user_mode;
			runtime.path = inactive.path;
			runtime.selected_group = inactive.selected_group;
			runtime.leaf = inactive.leaf;
			runtime.alive = inactive.alive;
		}
		if (!owner.mihomo_running && owner.cleanup?.ok == true &&
			runtime.data_path == "unknown") {
			// Passthrough is a data-plane fact, not an ownership claim. Nikki stop
			// normally persists the recovery Profile before cleanup, so NetFleet may be
			// inactive while the current effective path is still direct passthrough.
			// A dead Mihomo process alone remains ambiguous without cleanup readback.
			runtime.data_path = "passthrough";
			runtime.selected_group = null;
			runtime.leaf = null;
			runtime.alive = true;
		}
		const groups = entry?.candidate_groups ?? [];
		for (let j = 0; j < length(groups); j++) {
			const group = groups[j];
			const group_state = proxy_state?.[group.name];
			const provider_source = entry?.providers?.[group.provider]?.source_name;
			const nodes = group_nodes(proxy_state, provider_state, provider_source, group.name);
			const available = group_state?.alive == true && nodes.known && has_available_node(nodes);
			const delay = evidence_delay(display_evidence, group.name);
			const provider = providers[group.provider];
			const region = regions[group.region];
			if (provider != null) {
				provider.candidate_count++;
				provider.available_count += available ? 1 : 0;
				if (provider_regions[group.provider] == null) {
					provider_regions[group.provider] = {};
				}
				if (provider_regions[group.provider][group.region] == null) {
					provider_regions[group.provider][group.region] = available;
				} else {
					provider_regions[group.provider][group.region] =
						provider_regions[group.provider][group.region] || available;
				}
				if (delay != null && (provider.best_delay_ms == null || delay < provider.best_delay_ms)) {
					provider.best_delay_ms = delay;
				}
			}
			if (region != null) {
				region.candidate_count++;
				region.available_count += available ? 1 : 0;
				if (region_providers[group.region] == null) {
					region_providers[group.region] = {};
				}
				if (region_providers[group.region][group.provider] == null) {
					region_providers[group.region][group.provider] = available;
				} else {
					region_providers[group.region][group.provider] =
						region_providers[group.region][group.provider] || available;
				}
				if (delay != null && (region.best_delay_ms == null || delay < region.best_delay_ms)) {
					region.best_delay_ms = delay;
				}
				if (region_nodes[group.region] == null) {
					region_nodes[group.region] = { known: nodes.known, members: {} };
				}
				if (!nodes.known) {
					region_nodes[group.region].known = false;
				} else if (region_nodes[group.region].known) {
					const node_names = keys(nodes.members);
					for (let k = 0; k < length(node_names); k++) {
						const node_name = node_names[k];
						const identity = `${group.provider}::${node_name}`;
						if (!(identity in region_nodes[group.region].members)) {
							region_nodes[group.region].members[identity] = nodes.members[node_name];
						} else {
							region_nodes[group.region].members[identity] =
								region_nodes[group.region].members[identity] || nodes.members[node_name];
						}
					}
				}
			}
			if (name == automatic_capability_id && runtime.data_path == "preferred" &&
				group.name == runtime.selected_group) {
				if (provider != null) provider.selected = true;
				if (region != null) region.selected = true;
			}
		}
		if (name == automatic_capability_id && runtime.data_path == "provider_fallback" &&
			providers[runtime.provider_id] != null) {
			providers[runtime.provider_id].selected = true;
		}

		let reason = capability_policy.enabled != true && owner.active ?
			{ kind: "disabled_config_active_artifact" } :
			{ kind: owner.active ? "initial_or_manual" : "native_profile" };
		if (runtime.data_path == "passthrough") {
			reason = {
				kind: "passthrough",
				preferred_provider_id: runtime.preferred_provider_id,
				preferred_region_id: runtime.preferred_region_id
			};
		} else if (owner.active && runtime.data_path == "direct_fallback") {
			reason = {
				kind: "direct_fallback",
				preferred_provider_id: runtime.preferred_provider_id,
				preferred_region_id: runtime.preferred_region_id
			};
		} else if (owner.active && runtime.data_path == "direct_manual") {
			reason = { kind: "direct_manual" };
		} else if (owner.active && runtime.data_path == "manual_region") {
			reason = {
				kind: "manual_region",
				region_id: runtime.region_id,
				provider_id: runtime.provider_id
			};
		} else if (owner.active && runtime.data_path == "provider_fallback") {
			reason = {
				kind: "provider_fallback",
				preferred_provider_id: runtime.preferred_provider_id,
				preferred_region_id: runtime.preferred_region_id
			};
		} else if (owner.active && display_evidence?.decision?.group == runtime.preferred_group) {
			reason = {
				kind: "automatic_decision",
				sampled_at: display_evidence.sampled_at,
				delay_ms: display_evidence.decision.delay_ms,
				layer: display_evidence.decision.layer,
				changed_region: display_evidence.decision.changed_region,
				decision_reason: display_evidence.decision.reason ?? "fastest_eligible",
				preferred_region: display_evidence.decision.preferred_region ?? null,
				protected_probes_ok: display_evidence?.protected_probes?.ok == true
			};
		}
		push(capabilities, {
			id: name,
			display_name: capability_policy.display_name ?? name,
			enabled: capability_policy.enabled == true,
			compiled: true,
			mode: entry?.mode ?? policy.capabilities?.[name]?.mode ?? "manual",
			user_mode: runtime.user_mode,
			visible_choice: runtime.visible_choice,
			group: entry?.name ?? null,
			base_group: entry?.base_group ?? null,
			base_groups: entry?.base_groups ?? (entry?.base_group == null ? [] : [entry.base_group]),
			business_routes: business_routes(entry, proxy_state),
			data_path: runtime.data_path,
			runtime_path: runtime.path,
			selected_group: runtime.selected_group,
			provider_id: runtime.provider_id,
			region_id: runtime.region_id,
			role: runtime.role,
			leaf: runtime.leaf,
			alive: runtime.alive,
			preferred_group: runtime.preferred_group,
			preferred_provider_id: runtime.preferred_provider_id,
			preferred_region_id: runtime.preferred_region_id,
			preferred_leaf: runtime.preferred_leaf,
			allowed_regions: capability_policy.allowed_regions ?? null,
			excluded_regions: capability_policy.excluded_regions ?? [],
			prefer_region_from: capability_policy.prefer_region_from ?? null,
			fail_open_stages: entry?.fail_open_stages ?? [],
			region_switch_margin_ms: type(entry?.region_switch_margin_ms) == "int" ?
				entry.region_switch_margin_ms : region_switch_margin(policy, name),
			leaf_switch_margin_ms: type(entry?.leaf_switch_margin_ms) == "int" ?
				entry.leaf_switch_margin_ms : leaf_switch_margin(policy, name),
			reason: reason
		});
	}
	for (let i = 0; i < length(provider_names); i++) {
		const provider = providers[provider_names[i]];
		const region_values = provider_regions[provider_names[i]] ?? {};
		const names = keys(region_values);
		provider.region_count = length(names);
		provider.available_region_count = 0;
		for (let j = 0; j < length(names); j++) {
			provider.available_region_count += region_values[names[j]] ? 1 : 0;
		}
	}
	for (let i = 0; i < length(region_names); i++) {
		const region = regions[region_names[i]];
		const provider_values = region_providers[region_names[i]] ?? {};
		const names = keys(provider_values);
		region.provider_count = length(names);
		region.available_provider_count = 0;
		for (let j = 0; j < length(names); j++) {
			region.available_provider_count += provider_values[names[j]] ? 1 : 0;
		}
	}
	for (let i = 0; i < length(region_names); i++) {
		const region = regions[region_names[i]];
		const node_info = region_nodes[region_names[i]];
		if (region == null || node_info == null || !node_info.known) {
			continue;
		}
		const identities = keys(node_info.members);
		region.node_count = length(identities);
		region.available_node_count = 0;
		for (let j = 0; j < length(identities); j++) {
			region.available_node_count += node_info.members[identities[j]] ? 1 : 0;
		}
		region.node_count_known = true;
	}
	for (let i = 0; i < length(provider_names); i++) {
		const provider = providers[provider_names[i]];
		const aggregate = aggregate_evidence(root_evidence, "providers", provider_names[i]);
		if (provider == null || aggregate == null) {
			continue;
		}
		provider.best_delay_ms = aggregate.last_best_delay_ms;
		provider.last_best_delay_ms = aggregate.last_best_delay_ms;
		provider.average_best_delay_ms = aggregate.average_best_delay_ms;
		provider.delay_sample_count = aggregate.sample_count;
		provider.delay_sampled_at = aggregate.sampled_at;
	}
	for (let i = 0; i < length(region_names); i++) {
		const region = regions[region_names[i]];
		const aggregate = aggregate_evidence(root_evidence, "regions", region_names[i]);
		if (region == null || aggregate == null) {
			continue;
		}
		region.best_delay_ms = aggregate.last_best_delay_ms;
		region.last_best_delay_ms = aggregate.last_best_delay_ms;
		region.average_best_delay_ms = aggregate.average_best_delay_ms;
		region.delay_sample_count = aggregate.sample_count;
		region.delay_sampled_at = aggregate.sampled_at;
	}
	let automation_paused = false;
	for (let i = 0; i < length(capabilities); i++) {
		if (owner.active == true && capabilities[i]?.mode == "automatic" &&
			capabilities[i]?.user_mode != "automatic") {
			automation_paused = true;
		}
	}
	return {
		build: owner.build ?? { version: null, source_commit: null, source_tree: null },
		active: owner.active,
		policy_enabled: policy.main.enabled == true,
		profile: owner.profile,
		policy_source: policy.policy_source,
		recovery_profile: policy.recovery_profile.ref,
		recovery_profile_display_name: owner.recovery_profile_display_name ?? null,
		native_runtime: native,
		runtime: {
			mihomo_running: owner.mihomo_running,
			nikki_enabled: owner.nikki_enabled,
			netfleet_present: owner.netfleet_present == true,
			controller_available: state?.proxies != null,
			lan_runtime: owner.lan_runtime ?? null,
			cleanup: owner.cleanup ?? null,
			passthrough_ready: owner.cleanup?.ok == true && owner.nikki_enabled == false,
			supervisor: owner.supervisor ?? { installed: false, enabled: false, running: false }
		},
		selection: {
			automatic_capability_id: automatic_capability_id,
			automatic_capability_ids: automatic_capability_ids,
			region_switch_margin_ms: region_switch_margin(policy),
			leaf_switch_margin_ms: leaf_switch_margin(policy),
			automation: owner.automation ?? null,
			automation_paused: automation_paused
		},
		subscription_refresh: owner.subscription_refresh ?? null,
		subscriptions: owner.subscription_refresh?.subscriptions ?? [],
		capabilities: capabilities,
		providers: map(keys(providers), name => providers[name]),
		regions: map(keys(regions), name => regions[name]),
		actions: {
			can_enable: policy.main.enabled == true && owner.active != true &&
				owner.netfleet_present != true && owner.nikki_enabled == true &&
				owner.mihomo_running == true && owner.profile == policy.recovery_profile.ref,
			can_select_auto: owner.active == true && owner.netfleet_present == true &&
				owner.nikki_enabled == true && owner.mihomo_running == true &&
				length(automatic_capability_ids) > 0 && automatic_capability_id != null &&
				generated[automatic_capability_id]?.mode == "automatic" &&
				length(generated[automatic_capability_id]?.candidate_groups ?? []) > 0,
			can_refresh: owner.nikki_enabled == true &&
				(owner.subscription_refresh?.provider_count ?? 0) > 0,
			can_disable: owner.active || owner.netfleet_present == true
		}
	};
};
