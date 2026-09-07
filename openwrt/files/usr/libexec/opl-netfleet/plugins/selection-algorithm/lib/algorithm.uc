return function(context) {
// Bind the service functions before assigning closures that may reference them.
let manual_member, generated_group, choose_automatic, eligible_candidates, candidate_eligible, is_object, array_has, region_representatives, candidate_before, quota_rank, quota_value, candidate_key, best_region, best_in_region;

const region_switch_margin = context.use("models.policy").region_switch_margin;
manual_member = function(manifest, capability, choice) {
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

generated_group = function(manifest, capability) {
	return manifest?.generated_groups?.[capability];
};

choose_automatic = function(candidates, policy, capability, current_region, preferred_region) {
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

eligible_candidates = function(candidates, capability, policy, role) {
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

candidate_eligible = function(candidate, capability, policy) {
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

is_object = function(value) {
	return type(value) == "object";
};

array_has = function(values, value) {
	return type(values) == "array" && index(values, value) >= 0;
};

region_representatives = function(candidates) {
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

candidate_before = function(left, right) {
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

quota_rank = function(candidate) {
	const state = candidate?.quota?.state;
	if (state == "available" && quota_value(candidate) != null) {
		return 0;
	}
	return 1;
};

quota_value = function(candidate) {
	const remaining = candidate?.quota?.remaining_bytes;
	return type(remaining) == "int" || type(remaining) == "double" ? remaining : null;
};

candidate_key = function(candidate) {
	return `${candidate?.provider_id ?? ""}\u0000${candidate?.candidate_id ?? candidate?.id ?? ""}`;
};

best_region = function(representatives) {
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

best_in_region = function(candidates, region_id) {
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

return { manual_member, choose_automatic };
};
