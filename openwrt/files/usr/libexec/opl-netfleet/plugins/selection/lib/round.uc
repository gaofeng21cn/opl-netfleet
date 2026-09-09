

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let automatic_candidates, current_region, automatic_round;

const proxies = context.use("mihomo.controller").proxies;
const proxy_providers = context.use("mihomo.controller").proxy_providers;
const measure_latency = context.use("mihomo.latency").measure;
const complete_from_fresh_history = context.use("mihomo.latency").complete_from_fresh_history;
const reset_candidate_groups = context.use("mihomo.paths").reset_candidate_groups;
const selection_group = context.use("mihomo.paths").selection_group;
const candidate_provider_leaves_ready = context.use("mihomo.paths").candidate_provider_leaves_ready;
const wait_for_candidate_provider_leaves = context.use("mihomo.paths").wait_for_candidate_provider_leaves;
const candidate_leaf_wait_seconds = context.use("mihomo.paths").candidate_leaf_wait_seconds;
const candidate_group_names = context.use("mihomo.paths").candidate_group_names;
const provider_group_leaf = context.use("models.selector").provider_group_leaf;
const choose_automatic = context.use("selection.algorithm").choose_automatic;
const provider_round_summary = context.use("models.selector").provider_round_summary;
const resolve_runtime = context.use("models.status").resolve_runtime;
const provider_quotas = context.use("subscriptions.facts").provider_quotas;

automatic_candidates = function(manifest, quotas, state, provider_state, capability, latency_round) {
	const entry = manifest?.generated_groups?.[capability];
	const result = [];
	const groups = entry?.candidate_groups ?? [];
	for (let i = 0; i < length(groups); i++) {
		const group = groups[i];
		const group_state = state?.proxies?.[group.name];
		// Mihomo owns node-level URLTest inside each provider/region group.
		// NetFleet compares only that group's current leaf once per round.
		const source_name = entry?.providers?.[group.provider]?.source_name;
		const candidate_id = provider_group_leaf(state?.proxies, provider_state,
			source_name, group.name, latency_round?.target);
		const latency = latency_round?.results?.[group.name] ??
			{ method: "mihomo_delay", status: "unavailable", reason: "delay_test_failed" };
		const reason = group_state == null ? "group_unavailable" :
			group_state.extra?.[latency_round?.target]?.alive != true ? "latency_health_failed" :
			candidate_id == null ? "no_verified_leaf" :
			latency?.status != "ok" ? "delay_unavailable" :
			quotas[group.provider]?.state == "exhausted" ? "quota_exhausted" : null;
		const available = candidate_id != null && latency?.status == "ok";
		const candidate = {
			capability: capability,
			candidate_id: candidate_id,
			leaf_verified: candidate_id != null,
			provider_id: group.provider,
			region_id: group.region,
			role: group.role,
			group: group.name,
			available: available,
			reason: reason,
			quota: quotas[group.provider] ?? { state: "unknown" }
		};
		candidate.latency = latency;
		push(result, candidate);
	}
	return result;
};

current_region = function(manifest_entry, state) {
	return resolve_runtime(manifest_entry, state)?.region_id ?? null;
};

// Cache keys describe the measured resource, never the capability display name.
function measurement_key(entry, group, state, providers, target) {
	const source = entry?.providers?.[group.provider]?.source_name;
	const leaf = provider_group_leaf(state?.proxies, providers, source, group.name, target);
	return sprintf("%J", [group.provider, source, group.region, group.filter, leaf,
		state?.proxies?.[group.name]?.all ?? []]);
};

automatic_round = function(policy, manifest, manifest_entry, capability, secret, keep_current,
	freshness_baseline, provider_measurement_ok, preferred_region, shared) {
	const before = freshness_baseline ?? proxies(secret);
	// Mihomo caches an empty-fallback selected during provider startup for up to
	// ten seconds. Clear each automatic leaf group through the controller before
	// the single capability delay; the delay still owns all node measurements and
	// Mihomo remains the only leaf selector.
	if (shared?.prepared != true && !reset_candidate_groups(secret, manifest_entry)) {
		return { ok: false, error: "candidate_group_reset_failed", candidates: [] };
	}
	const reused = {};
	let reusable = shared?.state != null;
	for (let group in manifest_entry.candidate_groups ?? []) {
		const key = measurement_key(manifest_entry, group, shared?.state, shared?.provider_state, policy.checks.latency.url);
		if (shared?.entries?.[key] == null) reusable = false;
		else if (shared.entries[key].latency != null) reused[group.name] = shared.entries[key].latency;
	}
	let latency_round = reusable ? { target: policy.checks.latency.url, results: reused } :
		measure_latency(secret, selection_group(manifest_entry), policy.checks);
	let measured_state = reusable ? shared.state : proxies(secret);
	if (measured_state == null || measured_state.proxies == null) {
		return { ok: false, error: "mihomo_state_unavailable_after_delay", candidates: [] };
	}
	let provider_state = reusable ? shared.provider_state : proxy_providers(secret, 1)?.providers ?? null;
	if (!reusable && !candidate_provider_leaves_ready(manifest_entry, measured_state.proxies, provider_state, policy.checks.latency.url)) {
		const waited = wait_for_candidate_provider_leaves(secret, manifest_entry,
			candidate_leaf_wait_seconds(policy), policy.checks.latency.url);
		if (waited.state != null && waited.state.proxies != null) {
			measured_state = waited.state;
		}
		provider_state = waited.provider_state ?? provider_state;
	}
	latency_round = complete_from_fresh_history(latency_round, before, measured_state,
		candidate_group_names(manifest_entry), policy.checks);
	if (shared != null && !reusable) {
		shared.state = measured_state;
		shared.provider_state = provider_state;
		for (let group in manifest_entry.candidate_groups ?? []) {
			const key = measurement_key(manifest_entry, group, measured_state, provider_state, policy.checks.latency.url);
			shared.entries[key] = { latency: latency_round.results?.[group.name] ?? null };
		}
	}
	const candidates = automatic_candidates(manifest, provider_quotas(policy), measured_state,
		provider_state, capability, latency_round);
	const decision = choose_automatic(candidates, policy, capability,
		keep_current ? current_region(manifest_entry, measured_state) : null, preferred_region);
	return {
		ok: decision.ok == true,
		error: decision.error,
		decision: decision,
		candidates: candidates,
		summary: provider_round_summary(manifest_entry, measured_state?.proxies, provider_state, policy.checks.latency.url),
		latency_round: latency_round,
		provider_state_available: provider_state != null,
		provider_measurement_ok: provider_measurement_ok
	};
};

return { automatic_candidates, current_region, automatic_round };
};
