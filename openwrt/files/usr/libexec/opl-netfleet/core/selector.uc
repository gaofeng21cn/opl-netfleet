import { region_switch_margin } from "./policy.uc";

function generated_group(manifest, capability) {
	return manifest?.generated_groups?.[capability];
};

function is_object(value) {
	return type(value) == "object";
};

function array_has(values, value) {
	return type(values) == "array" && index(values, value) >= 0;
};

const CONTROL_PROXY_TYPES = {
	direct: true,
	reject: true,
	compatible: true,
	global: true,
	pass: true,
	block: true
};

export function is_control_proxy(proxy_state, value) {
	return CONTROL_PROXY_TYPES[lc(`${proxy_state?.[value]?.type ?? ""}`)] == true;
};

// Names are not identities: a subscription may contain a perfectly valid
// node whose display name happens to be "direct".  Prefer Mihomo's type and
// group shape when it is available, and reserve built-in DIRECT detection for
// the status resolver's manifest-bound terminal.
export function is_proxy_leaf(proxy_state, value) {
	if (type(value) != "string" || length(trim(value)) == 0) {
		return false;
	}
	const state = proxy_state?.[value];
	if (state == null || type(state) != "object") {
		return false;
	}
	const proxy_type = lc(`${state.type ?? ""}`);
	return CONTROL_PROXY_TYPES[proxy_type] != true &&
		type(state.all) != "array" && type(state.now) != "string";
};

function is_provider_proxy_leaf(provider_state, source_name, value, require_alive) {
	if (type(source_name) != "string" || length(trim(source_name)) == 0 ||
		type(value) != "string" || length(trim(value)) == 0) {
		return false;
	}
	const nodes = provider_state?.[source_name]?.proxies;
	if (type(nodes) != "array") {
		return false;
	}
	let matched = null;
	for (let i = 0; i < length(nodes); i++) {
		if (nodes[i]?.name != value) {
			continue;
		}
		if (matched != null) {
			return false;
		}
		matched = nodes[i];
	}
	const proxy_type = lc(`${matched?.type ?? ""}`);
	return matched != null && (require_alive != true || matched.alive == true) && length(proxy_type) > 0 &&
		CONTROL_PROXY_TYPES[proxy_type] != true;
};

function provider_group_leaf_with_health(proxy_state, provider_state, source_name, group, require_alive) {
	const group_state = proxy_state?.[group];
	const leaf = group_state?.now ?? null;
	return group_state?.alive == true && type(group_state?.all) == "array" &&
		index(group_state.all, leaf) >= 0 &&
		is_provider_proxy_leaf(provider_state, source_name, leaf, require_alive) ? leaf : null;
};

export function provider_group_current_leaf(proxy_state, provider_state, source_name, group) {
	return provider_group_leaf_with_health(proxy_state, provider_state, source_name, group, false);
};

export function provider_group_leaf(proxy_state, provider_state, source_name, group) {
	return provider_group_leaf_with_health(proxy_state, provider_state, source_name, group, true);
};

function control_proxy_type(value) {
	return CONTROL_PROXY_TYPES[lc(`${value ?? ""}`)] == true;
};

function provider_source_summary(provider_state, source_name) {
	if (type(source_name) != "string" || length(trim(source_name)) == 0 ||
		provider_state?.[source_name] == null) {
		return { reason: "source_not_loaded", node_count: 0, alive_count: 0 };
	}
	const nodes = provider_state[source_name]?.proxies;
	if (type(nodes) != "array") {
		return { reason: "source_not_loaded", node_count: 0, alive_count: 0 };
	}
	let node_count = 0;
	let alive_count = 0;
	for (let i = 0; i < length(nodes); i++) {
		const proxy_type = lc(`${nodes[i]?.type ?? ""}`);
		if (control_proxy_type(proxy_type) || type(nodes[i]?.name) != "string" ||
			length(trim(nodes[i].name)) == 0) {
			continue;
		}
		node_count++;
		if (nodes[i]?.alive == true && length(proxy_type) > 0) {
			alive_count++;
		}
	}
	return {
		reason: node_count == 0 ? "zero_nodes" : alive_count == 0 ? "zero_alive_nodes" : "ready",
		node_count: node_count,
		alive_count: alive_count
	};
};

export function provider_round_summary(entry, proxy_state, provider_state) {
	const sources = [];
	const groups = [];
	if (provider_state == null || type(provider_state) != "object") {
		return {
			reason: "provider_state_unavailable",
			sources: sources,
			groups: groups
		};
	}
	const providers = entry?.providers ?? {};
	const provider_ids = keys(providers);
	for (let i = 0; i < length(provider_ids) && i < 64; i++) {
		const provider_id = provider_ids[i];
		const counts = provider_source_summary(provider_state, providers[provider_id]?.source_name);
		push(sources, {
			provider_id: provider_id,
			reason: counts.reason,
			node_count: counts.node_count,
			alive_count: counts.alive_count
		});
	}
	const candidate_groups = entry?.candidate_groups ?? [];
	for (let i = 0; i < length(candidate_groups) && i < 64; i++) {
		const group = candidate_groups[i];
		const source_name = entry?.providers?.[group?.provider]?.source_name;
		const leaf = provider_group_leaf(proxy_state, provider_state, source_name, group?.name);
		const group_state = proxy_state?.[group?.name];
		const now_type = lc(`${proxy_state?.[group_state?.now]?.type ?? ""}`);
		let reason = "ready";
		if (leaf == null) {
			reason = control_proxy_type(now_type) ? "control_fallback" : "no_verified_leaf";
		}
		push(groups, {
			provider_id: group?.provider ?? null,
			region_id: group?.region ?? null,
			reason: reason,
			member_count: type(group_state?.all) == "array" ? length(group_state.all) : 0
		});
	}
	return {
		reason: null,
		sources: sources,
		groups: groups
	};
};

function quota_value(candidate) {
	const remaining = candidate?.quota?.remaining_bytes;
	return type(remaining) == "int" || type(remaining) == "double" ? remaining : null;
};

function quota_rank(candidate) {
	const state = candidate?.quota?.state;
	if (state == "available" && quota_value(candidate) != null) {
		return 0;
	}
	return 1;
};

function candidate_key(candidate) {
	return `${candidate?.provider_id ?? ""}\u0000${candidate?.candidate_id ?? candidate?.id ?? ""}`;
};

function candidate_before(left, right) {
	const left_delay = left?.latency?.delay_ms;
	const right_delay = right?.latency?.delay_ms;
	const left_has_delay = type(left_delay) == "int" && left_delay >= 0;
	const right_has_delay = type(right_delay) == "int" && right_delay >= 0;
	if (left_has_delay != right_has_delay) {
		return left_has_delay;
	}
	if (left_has_delay && left_delay != right_delay) {
		return left_delay < right_delay;
	}
	const left_rank = quota_rank(left);
	const right_rank = quota_rank(right);
	if (left_rank != right_rank) {
		return left_rank < right_rank;
	}
	if (left_rank == 0 && quota_value(left) != quota_value(right)) {
		return quota_value(left) > quota_value(right);
	}
	return candidate_key(left) < candidate_key(right);
};

function candidate_eligible(candidate, capability, policy) {
	if (!is_object(candidate) || candidate.capability != capability ||
		candidate.leaf_verified != true ||
		candidate.available != true || candidate?.latency?.status != "ok" ||
		type(candidate?.latency?.delay_ms) != "int" || candidate.latency.delay_ms < 0 ||
		candidate?.quota?.state == "exhausted") {
		return false;
	}
	const capability_policy = policy?.capabilities?.[capability] ?? {};
	if (capability_policy.enabled != true ||
		(type(capability_policy.allowed_regions) == "array" &&
			!array_has(capability_policy.allowed_regions, candidate.region_id))) {
		return false;
	}
	if (array_has(capability_policy.excluded_regions, candidate.region_id)) {
		return false;
	}
	const region_policy = policy?.regions?.[candidate.region_id];
	if (region_policy == null || region_policy.mode == "manual_only") {
		return false;
	}
	return true;
};

function eligible_candidates(candidates, capability, policy, role) {
	const result = [];
	for (let i = 0; i < length(candidates ?? []); i++) {
		const candidate = candidates[i];
		if (candidate_eligible(candidate, capability, policy) &&
			(role == null || candidate.role == role)) {
			push(result, candidate);
		}
	}
	return result;
};

function best_in_region(candidates, region_id) {
	let winner = null;
	for (let i = 0; i < length(candidates); i++) {
		const candidate = candidates[i];
		if (candidate.region_id != region_id) {
			continue;
		}
		if (winner == null || candidate_before(candidate, winner)) {
			winner = candidate;
		}
	}
	return winner;
};

function region_representatives(candidates) {
	const representatives = {};
	for (let i = 0; i < length(candidates); i++) {
		const candidate = candidates[i];
		const current = representatives[candidate.region_id];
		if (current == null || candidate_before(candidate, current)) {
			representatives[candidate.region_id] = candidate;
		}
	}
	return representatives;
};

function best_region(representatives) {
	let winner = null;
	const region_names = keys(representatives);
	for (let i = 0; i < length(region_names); i++) {
		const candidate = representatives[region_names[i]];
		if (winner == null || candidate_before(candidate, winner) ||
			(candidate.latency.delay_ms == winner.latency.delay_ms && candidate.region_id < winner.region_id)) {
			winner = candidate;
		}
	}
	return winner;
};

export function manual_member(manifest, capability, choice) {
	const entry = generated_group(manifest, capability);
	if (entry == null) {
		return { ok: false, error: "unknown capability" };
	}
	const direct = entry?.direct_name ?? "DIRECT";
	if (choice == direct) {
		return { ok: true, group: entry.name, choice: direct, mode: "direct" };
	}
	const regions = entry?.region_groups ?? [];
	for (let i = 0; i < length(regions); i++) {
		if (choice == regions[i]?.region || choice == regions[i]?.name) {
			return {
				ok: true,
				group: entry.name,
				choice: regions[i].name,
				region: regions[i].region,
				mode: "manual_region"
			};
		}
	}
	return { ok: false, error: "choice is not an authorized region or DIRECT" };
};

export function choose_automatic(candidates, policy, capability, current_region, preferred_region) {
	const margin = region_switch_margin(policy, capability);
	const primary = eligible_candidates(candidates, capability, policy, "primary");
	const reserve = eligible_candidates(candidates, capability, policy, "reserve");
	const layers = [primary, reserve];

	for (let layer_index = 0; layer_index < length(layers); layer_index++) {
		const layer = layers[layer_index];
		if (length(layer) == 0) {
			continue;
		}
		const representatives = region_representatives(layer);
		const fastest = best_region(representatives);
		if (fastest == null) {
			continue;
		}
		let selected_region = fastest.region_id;
		const current = representatives[current_region];
		const preferred = representatives[preferred_region];
		let reason = "fastest_eligible";
		if (preferred != null) {
			selected_region = preferred.region_id;
			reason = "followed_capability_region";
		} else if (current != null && current.region_id != fastest.region_id &&
			current.latency.delay_ms - fastest.latency.delay_ms < margin) {
			selected_region = current.region_id;
			reason = "kept_current_region";
		} else if (current != null && current.region_id == fastest.region_id) {
			reason = "current_region_fastest";
		}
		const selected = best_in_region(layer, selected_region);
		if (selected != null) {
			return {
				ok: true,
				region_id: selected.region_id,
				group: selected.group,
				candidate_id: selected.candidate_id ?? selected.id,
				provider_id: selected.provider_id,
				delay_ms: selected.latency.delay_ms,
				layer: layer_index == 0 ? "primary" : "reserve",
				changed_region: current_region == null || selected.region_id != current_region,
				reason: reason,
				preferred_region: preferred_region ?? null
			};
		}
	}
	return { ok: false, error: "no_qualified_candidate" };
};
