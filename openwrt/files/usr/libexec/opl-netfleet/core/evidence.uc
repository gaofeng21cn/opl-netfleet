export const MEASUREMENT_MODEL = "all_capability_groups_v2";

function clone(value) {
	const value_type = type(value);
	if (value_type == "array") {
		const result = [];
		for (let i = 0; i < length(value); i++) push(result, clone(value[i]));
		return result;
	}
	if (value_type == "object") {
		const result = {};
		const names = keys(value);
		for (let i = 0; i < length(names); i++) result[names[i]] = clone(value[names[i]]);
		return result;
	}
	return value;
};

function valid_identity(identity) {
	return type(identity) == "object" &&
		type(identity.artifact_sha256) == "string" &&
		type(identity.policy_source_sha256) == "string" &&
		type(identity.policy_sha256) == "string" &&
		type(identity.measurement_model) == "string" &&
		(identity.measurement_contract == null || type(identity.measurement_contract) == "string");
};

export function measurement_identity(policy, manifest) {
	const latency = policy?.checks?.latency ?? {};
	return {
		artifact_sha256: manifest?.artifact_sha256,
		policy_source_sha256: manifest?.policy_source?.sha256,
		policy_sha256: manifest?.policy_sha256,
		measurement_model: MEASUREMENT_MODEL,
		measurement_contract: sprintf("%J", {
			method: latency.method,
			url: latency.url,
			timeout_ms: latency.timeout_ms,
			expected_status: latency.expected_status
		})
	};
};

export function identity_matches(left, right) {
	if (!valid_identity(left) || !valid_identity(right) ||
		left.measurement_model != right.measurement_model) return false;
	if (type(left.measurement_contract) == "string" &&
		type(right.measurement_contract) == "string") {
		return left.measurement_contract == right.measurement_contract;
	}
	// Legacy evidence has no measurement contract. Accept it once only when its
	// exact artifact and policy provenance still match the current owner.
	return left.artifact_sha256 == right.artifact_sha256 &&
		left.policy_source_sha256 == right.policy_source_sha256 &&
		left.policy_sha256 == right.policy_sha256;
};

function same_identity(left, right) {
	return identity_matches(left, right);
};

function best_by(entries, field) {
	const result = {};
	for (let i = 0; i < length(entries); i++) {
		const entry = entries[i];
		const name = entry?.[field];
		if (entry?.ok != true || type(name) != "string" ||
			type(entry?.delay_ms) != "int") continue;
		const current = result[name];
		if (current == null || entry.delay_ms < current) result[name] = entry.delay_ms;
	}
	return result;
};

function valid_aggregate(entry) {
	return type(entry?.last_best_delay_ms) == "int" && entry.last_best_delay_ms >= 0 &&
		type(entry?.total_best_delay_ms) == "int" &&
		entry.total_best_delay_ms >= entry.last_best_delay_ms &&
		type(entry?.sample_count) == "int" && entry.sample_count > 0 &&
		type(entry?.sampled_at) == "int";
};

function aggregate_ids(entries, field) {
	const result = {};
	for (let i = 0; i < length(entries); i++) {
		const name = entries[i]?.[field];
		if (type(name) == "string" && length(name) > 0) result[name] = true;
	}
	return result;
};

function initial_aggregates(previous, current_ids) {
	const result = {};
	const names = keys(previous ?? {});
	for (let i = 0; i < length(names) && i < 256; i++) {
		const entry = previous[names[i]];
		if (current_ids?.[names[i]] == true && valid_aggregate(entry)) {
			result[names[i]] = clone(entry);
		}
	}
	return result;
};

function add_aggregate_samples(aggregates, latest, sampled_at) {
	const names = keys(latest);
	for (let i = 0; i < length(names) && i < 256; i++) {
		const name = names[i];
		const delay = latest[name];
		const current = aggregates[name];
		aggregates[name] = {
			last_best_delay_ms: delay,
			total_best_delay_ms: (current?.total_best_delay_ms ?? 0) + delay,
			sample_count: (current?.sample_count ?? 0) + 1,
			sampled_at: sampled_at
		};
	}
};

function entries_for(candidates, sampled_at) {
	const entries = [];
	for (let i = 0; i < length(candidates) && i < 256; i++) {
		const candidate = candidates[i];
		const entry = {
			candidate: candidate.group,
			sampled_at: sampled_at,
			ok: candidate.available == true && candidate?.latency?.status == "ok",
			provider_id: candidate.provider_id,
			region_id: candidate.region_id,
			role: candidate.role,
			leaf: candidate.candidate_id,
			quota_state: candidate?.quota?.state ?? "unknown"
		};
		if (entry.ok) entry.delay_ms = candidate.latency.delay_ms;
		push(entries, entry);
	}
	return entries;
};

function decision_for(capability, decision) {
	return {
		capability: capability,
		group: decision.group,
		provider_id: decision.provider_id,
		region_id: decision.region_id,
		candidate_id: decision.candidate_id,
		delay_ms: decision.delay_ms,
		layer: decision.layer,
		changed_region: decision.changed_region,
		reason: decision.reason ?? "fastest_eligible",
		preferred_region: decision.preferred_region ?? null
	};
};

function legacy_snapshot(candidates, capability, decision, probes) {
	const sampled_at = int(time());
	return {
		schema_version: 1,
		sampled_at: sampled_at,
		capability: capability,
		decision: decision_for(capability, decision),
		protected_probes: { ok: probes?.ok == true, count: probes?.count ?? 0 },
		entries: entries_for(candidates, sampled_at)
	};
};

export function selection_snapshot(previous, candidates, capability, decision, probes, identity, groups) {
	// Keep the old four-argument upgrade call data-safe. The next new-owner
	// round replaces it with the current per-capability schema.
	if (type(previous) == "array" && type(candidates) == "string" &&
		type(capability) == "object" && type(decision) == "object" && identity == null) {
		return legacy_snapshot(previous, candidates, capability, decision);
	}
	const sampled_at = int(time());
	const entries = entries_for(candidates, sampled_at);
	const capabilities = previous?.schema_version == 3 && same_identity(previous.identity, identity) &&
		type(previous.capabilities) == "object" ? clone(previous.capabilities) : {};
	const prior = capabilities[capability];
	// Runtime availability is transient; only the compiled catalog owns removal.
	const regions = initial_aggregates(prior?.regions,
		groups != null ? aggregate_ids(groups, "region") : aggregate_ids(entries, "region_id"));
	const providers = initial_aggregates(prior?.providers,
		groups != null ? aggregate_ids(groups, "provider") : aggregate_ids(entries, "provider_id"));
	add_aggregate_samples(regions, best_by(entries, "region_id"), sampled_at);
	add_aggregate_samples(providers, best_by(entries, "provider_id"), sampled_at);
	capabilities[capability] = {
		sampled_at: sampled_at,
		decision: decision_for(capability, decision),
		protected_probes: { ok: probes?.ok == true, count: probes?.count ?? 0 },
		entries: entries,
		providers: providers,
		regions: regions
	};
	return {
		schema_version: 3,
		identity: clone(identity),
		sampled_at: sampled_at,
		capabilities: capabilities
	};
};

function valid_decision(decision) {
	return decision == null || (type(decision) == "object" &&
		type(decision.capability) == "string" && type(decision.group) == "string" &&
		type(decision.provider_id) == "string" && type(decision.region_id) == "string" &&
		type(decision.delay_ms) == "int");
};

function validate_entries(entries, prefix) {
	if (type(entries) != "array" || length(entries) > 256) {
		return `${prefix} entries must be a bounded array`;
	}
	for (let i = 0; i < length(entries); i++) {
		const entry = entries[i];
		if (type(entry) != "object" || type(entry.candidate) != "string" ||
			type(entry.sampled_at) != "int" || type(entry.ok) != "bool") {
			return `invalid ${prefix} evidence entry: ${i}`;
		}
		if (entry.ok && type(entry.delay_ms) != "int") {
			return `successful ${prefix} evidence entry lacks delay: ${i}`;
		}
	}
	return null;
};

function validate_aggregates(aggregates, prefix, dimension) {
	const names = type(aggregates) == "object" ? keys(aggregates) : [];
	if (type(aggregates) != "object" || length(names) > 256) {
		return `${prefix} ${dimension} must be bounded`;
	}
	for (let i = 0; i < length(names); i++) {
		if (!valid_aggregate(aggregates[names[i]])) {
			return `invalid ${prefix} evidence ${dimension}: ${names[i]}`;
		}
	}
	return null;
};

export function validate(store) {
	if (store == null) return { ok: true, count: 0 };
	if (type(store) != "object") return { ok: false, errors: ["evidence must be an object"] };
	const version = store.schema_version ?? 1;
	if (version != 1 && version != 2 && version != 3) {
		return { ok: false, errors: ["evidence schema_version must be 1, 2 or 3"] };
	}
	if (version == 3) {
		if (!valid_identity(store.identity) || type(store.capabilities) != "object" ||
			length(keys(store.capabilities)) > 16) {
			return { ok: false, errors: ["per-capability evidence identity or capabilities are invalid"] };
		}
		let count = 0;
		const names = keys(store.capabilities);
		for (let i = 0; i < length(names); i++) {
			const capability = store.capabilities[names[i]];
			if (type(capability?.sampled_at) != "int" || !valid_decision(capability?.decision)) {
				return { ok: false, errors: [`invalid capability evidence: ${names[i]}`] };
			}
			const entries_error = validate_entries(capability.entries ?? [], names[i]);
			if (entries_error != null) return { ok: false, errors: [entries_error] };
			const providers_error = validate_aggregates(capability.providers ?? {}, names[i], "providers");
			if (providers_error != null) return { ok: false, errors: [providers_error] };
			const regions_error = validate_aggregates(capability.regions ?? {}, names[i], "regions");
			if (regions_error != null) return { ok: false, errors: [regions_error] };
			count += length(capability.entries ?? []);
		}
		return { ok: true, count: count };
	}
	if (version == 2 && !valid_identity(store.identity)) {
		return { ok: false, errors: ["evidence identity is invalid"] };
	}
	if (!valid_decision(store.decision)) return { ok: false, errors: ["invalid evidence decision"] };
	const entries_error = validate_entries(store.entries ?? [], "legacy");
	if (entries_error != null) return { ok: false, errors: [entries_error] };
	if (version == 2) {
		const regions_error = validate_aggregates(store.regions ?? {}, "legacy", "regions");
		if (regions_error != null) return { ok: false, errors: [regions_error] };
	}
	return { ok: true, count: length(store.entries ?? []) };
};
