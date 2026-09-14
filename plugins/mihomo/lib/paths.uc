

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let wait_for_group_member, selection_group, provider_source_for_group, candidate_leaf_wait_seconds, refresh_data_fallback, wait_for_preferred_runtime, capture_previous_choice, activate_preferred_choice, region_for_choice, activate_manual_choice, activate_direct_fallback, activate_all_direct_fallbacks, candidate_group_names, reset_candidate_groups, candidate_provider_leaves_ready, wait_for_candidate_provider_leaves, restore_runtime_selections, capture_runtime_selections;

const proxies = context.use("mihomo.controller").proxies;
const proxy_providers = context.use("mihomo.controller").proxy_providers;
const unfix_proxy = context.use("mihomo.controller").unfix;
const test_group_path = context.use("mihomo.controller").test_group_path;
const select_proxy = context.use("mihomo.controller").select;
const protected_probes = context.use("mihomo.controller").protected_probes;
const measure_latency = context.use("mihomo.latency").measure;
const protected_probes_after_restart = context.use("mihomo.probes").protected_probes_after_restart;
const preferred_runtime_ready = context.use("models.activation").preferred_runtime_ready;
const sorted_keys = context.use("models.ordering").sorted_keys;
const automation_config = context.use("models.policy").automation;
const provider_group_leaf = context.use("models.selector").provider_group_leaf;
const resolve_runtime = context.use("models.status").resolve_runtime;
const api_secret = context.use("platform.credentials").api_secret;

wait_for_group_member = function(secret, group, member, wait_seconds) {
	const attempts = type(wait_seconds) == "int" && wait_seconds > 0 ? wait_seconds : 10;
	for (let attempt = 0; attempt < attempts; attempt++) {
		const state = proxies(secret, 1);
		const members = state?.proxies?.[group]?.all;
		if (type(members) == "array" && index(members, member) >= 0) {
			return true;
		}
		if (attempt + 1 < attempts) {
			system("sleep 1");
		}
	}
	return false;
};

selection_group = function(entry) {
	return entry?.selector_name ?? entry?.name;
};

provider_source_for_group = function(entry, group) {
	const groups = entry?.candidate_groups ?? [];
	for (let i = 0; i < length(groups); i++) {
		if (groups[i]?.name == group) {
			return entry?.providers?.[groups[i]?.provider]?.source_name ?? null;
		}
	}
	return null;
};

candidate_leaf_wait_seconds = function(policy) {
	const timeout_ms = policy?.checks?.latency?.timeout_ms;
	if (type(timeout_ms) != "int" || timeout_ms < 1) return 1;
	const seconds = int((timeout_ms + 999) / 1000);
	return seconds > 30 ? 30 : seconds;
};

refresh_data_fallback = function(secret, entry, policy, provider_state, selected_group) {
	// Confirm only the chosen path. Traversing all visible branches can overwrite
	// its healthy wrapper with a failed lazy fallback during initial convergence.
	const round = selected_group == null ? measure_latency(secret, entry.name, policy.checks) : null;
	const reset_detail = {};
	if (selected_group != null && !unfix_proxy(secret, selected_group, reset_detail))
		return { ok: false, error: "candidate_group_reset_failed", detail: reset_detail, round: null, runtime: null };
	if (selected_group != null) {
		// The selected leaf already has this round's speed evidence. Do not remeasure it.
		// Mihomo caches health independently for each URL. A latency test on the
		// candidate cannot revive a selector or wrapper failed by a business URL.
		// Refresh only the bound chain, from the inner selector to the outer guard.
		const health = policy?.fail_open?.healthcheck;
		const stages = [
			{ group: selection_group(entry), probe: health?.path_probe_id },
			{ group: entry?.proxy_path_name, probe: health?.guard_probe_id }
		];
		for (let stage in stages) {
			let probe = null;
			for (let candidate in policy?.fail_open?.probes ?? [])
				if (candidate.id == stage.probe) probe = candidate;
			if (probe == null || !test_group_path(secret, stage.group, { latency: {
				url: probe.url, expected_status: probe.head_expected_status ?? probe.expected_status, timeout_ms: health.timeout_ms
			} })) return { ok: false, error: "selected_business_path_probe_failed", probe: stage.probe, group: stage.group,
				method: "HEAD", expected_status: probe?.head_expected_status ?? probe?.expected_status, round: round, runtime: null };
		}
	}
	const state = proxies(secret);
	if (state == null || state.proxies == null) {
		return { ok: false, error: "mihomo_state_unavailable", round: round };
	}
	state.providers = provider_state ?? proxy_providers(secret, 1)?.providers ?? null;
	const runtime = resolve_runtime(entry, state);
	return {
		// The outer scan initializes Mihomo's lazy fallback branches. Activation
		// authority remains the actual bound path, selected leaf and protected
		// probes; a slow unused branch must not invalidate the live path.
		ok: runtime.leaf != null,
		preferred: runtime.data_path == "preferred",
		round: round,
		state: state,
		runtime: runtime
	};
};

wait_for_preferred_runtime = function(secret, entry, choice, policy, provider_state, after_restart) {
	let fallback = refresh_data_fallback(secret, entry, policy, provider_state, choice);
	if (fallback.error != null) return fallback;
	if (fallback.ok && preferred_runtime_ready(fallback.runtime, choice)) {
		return fallback;
	}
	const wait_seconds = after_restart ? automation_config(policy).startup_grace_seconds :
		candidate_leaf_wait_seconds(policy);
	const attempts = type(wait_seconds) == "int" && wait_seconds > 0 ? wait_seconds : 1;
	for (let attempt = 0; attempt < attempts; attempt++) {
		system("sleep 1");
		const state = proxies(secret, 1);
		if (state != null) state.providers = proxy_providers(secret, 1)?.providers ?? null;
		const runtime = resolve_runtime(entry, state);
		fallback = {
			ok: runtime?.leaf != null,
			preferred: runtime?.data_path == "preferred",
			round: fallback.round,
			state: state,
			runtime: runtime
		};
		if (fallback.ok && preferred_runtime_ready(runtime, choice)) {
			break;
		}
	}
	return fallback;
};

capture_previous_choice = function(secret, entry, required) {
	if (required != true || entry?.base_type != "select" || !secret) {
		return { ok: true, choice: null };
	}
	const state = proxies(secret)?.proxies ?? {};
	const groups = entry?.entry_group == null ? [entry?.base_group] : [entry.entry_group];
	let choice = null;
	for (let i = 0; i < length(groups); i++) {
		const current = state?.[groups[i]]?.now;
		if (type(current) != "string" || length(current) == 0) {
			return { ok: false, error: "previous_selector_state_unavailable", group: groups[i] };
		}
		if (choice == null) choice = current;
		if (current != choice) {
			return { ok: false, error: "shared_binding_selection_mismatch", groups: groups };
		}
	}
	return { ok: true, choice: choice };
};

activate_preferred_choice = function(secret, entry, choice, policy, after_restart, verify_probes, measurement) {
	const selector = selection_group(entry);
	if (!wait_for_group_member(secret, selector, choice) || !select_proxy(secret, selector, choice)) {
		return { ok: false, error: "selector_write_failed", choice: choice };
	}
	const state = proxies(secret), provider_state = proxy_providers(secret, 1)?.providers ?? null;
	const current = provider_group_leaf(state?.proxies, provider_state, provider_source_for_group(entry, choice), choice, policy.checks.latency.url);
	const leaf = { ok: measurement?.group == choice && current != null && current == measurement?.candidate_id, leaf: current, provider_state };
	if (!leaf.ok) {
		return { ok: false, error: "selected_leaf_unavailable", choice: choice, leaf: leaf.leaf };
	}
	const visible = entry?.name;
	const automatic = entry?.automatic_name;
	if (type(automatic) != "string" || !wait_for_group_member(secret, visible, automatic) ||
		!select_proxy(secret, visible, automatic)) {
		return { ok: false, error: "proxy_guard_write_failed", choice: choice, leaf: leaf.leaf };
	}
	const fallback = wait_for_preferred_runtime(secret, entry, choice, policy,
		leaf.provider_state, after_restart);
	if (!fallback.ok || !preferred_runtime_ready(fallback.runtime, choice)) {
		return {
			ok: false,
			error: fallback.error ?? "preferred_path_unavailable",
			probe: fallback.probe, group: fallback.group, method: fallback.method,
			expected_status: fallback.expected_status,
			choice: choice,
			leaf: leaf.leaf,
			data_path: fallback.runtime?.data_path ?? "unknown",
			runtime: fallback.runtime
		};
	}
	let probes = null;
	if (verify_probes != false) {
		probes = after_restart ? protected_probes_after_restart(policy) : protected_probes(policy);
		if (!probes.ok) {
			return { ok: false, error: "protected_probe_failed", choice: choice, leaf: leaf.leaf, probes: probes };
		}
	}
	return {
		ok: true,
		choice: choice,
		leaf: leaf.leaf,
		data_path: fallback.runtime.data_path,
		runtime: fallback.runtime,
		protected_probes: probes
	};
};

region_for_choice = function(entry, choice) {
	const regions = entry?.region_groups ?? [];
	for (let i = 0; i < length(regions); i++) {
		if (regions[i]?.name == choice) return regions[i]?.region ?? null;
	}
	return null;
};

activate_manual_choice = function(secret, entry, choice, policy, verify_probes) {
	const visible = entry?.name;
	const direct = entry?.direct_name ?? "DIRECT";
	if (!wait_for_group_member(secret, visible, choice) || !select_proxy(secret, visible, choice)) {
		return { ok: false, error: "selector_write_failed", choice: choice };
	}
	if (choice == direct) {
		const state = proxies(secret);
		const runtime = resolve_runtime(entry, state);
		if (runtime?.user_mode != "direct" || runtime?.leaf != direct) {
			return { ok: false, error: "direct_readback_failed", runtime: runtime };
		}
		const probes = verify_probes == false ? null : protected_probes(policy);
		return {
			ok: true,
			choice: choice,
			leaf: direct,
			data_path: runtime.data_path,
			runtime: runtime,
			business_ok: probes?.ok == true ? true : probes?.ok == false ? false : null,
			protected_probes: probes
		};
	}
	// Measure each region layer's candidates before testing its selected path.
	// Testing only the outer fallback can retain its uninitialized DIRECT path.
	const region = filter(entry?.region_groups ?? [], item => item.name == choice)[0];
	const health = policy?.fail_open?.healthcheck;
	const probe = filter(policy?.fail_open?.probes ?? [], item => item.id == health?.path_probe_id)[0];
	for (let layer in [region?.primary_name, region?.reserve_name]) {
		if (layer == null) continue;
		measure_latency(secret, layer, policy.checks);
		if (probe != null) test_group_path(secret, layer, { latency: {
			url: probe.url, expected_status: probe.head_expected_status ?? probe.expected_status,
			timeout_ms: health.timeout_ms
		} });
	}
	const state = proxies(secret);
	if (state != null) state.providers = proxy_providers(secret, 1)?.providers ?? null;
	const runtime = resolve_runtime(entry, state);
	const expected_region = region_for_choice(entry, choice);
	if (runtime?.user_mode != "manual_region" || runtime?.region_id != expected_region || runtime?.leaf == null) {
		return { ok: false, error: "manual_region_readback_failed", runtime: runtime };
	}
	const probes = verify_probes == false ? null : protected_probes(policy);
	if (verify_probes != false && probes?.ok != true) {
		return { ok: false, error: "protected_probe_failed", runtime: runtime, probes: probes };
	}
	return {
		ok: true,
		choice: choice,
		leaf: runtime.leaf,
		data_path: runtime.data_path,
		runtime: runtime,
		protected_probes: probes
	};
};

activate_direct_fallback = function(secret, entry) {
	const guard = entry?.name;
	const direct = entry?.direct_name ?? "DIRECT";
	if (type(secret) != "string" || length(secret) == 0 ||
		type(guard) != "string" || type(direct) != "string" ||
		!wait_for_group_member(secret, guard, direct) ||
		!select_proxy(secret, guard, direct)) {
		return { ok: false, runtime_ok: false, business_ok: null, error: "direct_selector_write_failed" };
	}
	const state = proxies(secret);
	const runtime = resolve_runtime(entry, state);
	if ((runtime?.data_path != "direct_fallback" && runtime?.data_path != "direct_manual") ||
		runtime?.leaf != direct) {
		return { ok: false, runtime_ok: false, business_ok: null, error: "direct_readback_failed", runtime: runtime };
	}
	return {
		ok: true,
		runtime_ok: true,
		business_ok: null,
		mode: "direct_fallback",
		runtime: runtime
	};
};

activate_all_direct_fallbacks = function(secret, manifest, policy) {
	const results = {};
	const capability_names = sorted_keys(manifest?.generated_groups ?? {});
	let ok_count = 0;
	for (let i = 0; i < length(capability_names); i++) {
		const capability = capability_names[i];
		const result = activate_direct_fallback(secret, manifest.generated_groups[capability]);
		results[capability] = result;
		ok_count += result.ok == true ? 1 : 0;
	}
	const probes = protected_probes(policy);
	return {
		ok: length(capability_names) > 0 && ok_count == length(capability_names),
		attempted: length(capability_names),
		activated: ok_count,
		business_ok: probes?.ok == true ? true : probes?.ok == false ? false : null,
		protected_probes: probes,
		capabilities: results
	};
};

candidate_group_names = function(entry) {
	const result = [];
	const groups = entry?.candidate_groups ?? [];
	for (let i = 0; i < length(groups); i++) {
		if (type(groups[i]?.name) == "string") {
			push(result, groups[i].name);
		}
	}
	return result;
};

reset_candidate_groups = function(secret, entry, detail, progress) {
	const names = candidate_group_names(entry);
	if (length(names) == 0) {
		if (detail != null) detail.error = "candidate_groups_missing";
		return false;
	}
	for (let i = 0; i < length(names); i++) {
		if (progress != null) progress({ completed: i, total: length(names) });
		if (!unfix_proxy(secret, names[i], detail)) return false;
	}
	if (progress != null) progress({ completed: length(names), total: length(names) });
	return true;
};

candidate_provider_leaves_ready = function(entry, proxy_state, provider_state, url) {
	const groups = entry?.candidate_groups ?? [];
	if (length(groups) == 0 || type(proxy_state) != "object" ||
		type(provider_state) != "object") {
		return false;
	}
	for (let i = 0; i < length(groups); i++) {
		const group = groups[i];
		const source_name = entry?.providers?.[group?.provider]?.source_name;
		if (provider_group_leaf(proxy_state, provider_state, source_name, group?.name, url) == null) {
			return false;
		}
	}
	return true;
};

wait_for_candidate_provider_leaves = function(secret, entry, timeout_seconds, url) {
	let state = null;
	let provider_state = null;
	const attempts = (type(timeout_seconds) == "int" && timeout_seconds > 0 ? timeout_seconds : 1) + 1;
	for (let attempt = 0; attempt < attempts; attempt++) {
		state = proxies(secret, 1);
		provider_state = proxy_providers(secret, 1)?.providers ?? null;
		if (candidate_provider_leaves_ready(entry, state?.proxies, provider_state, url)) {
			break;
		}
		if (attempt < attempts - 1) {
			system("sleep 1");
		}
	}
	return { state: state, provider_state: provider_state };
};

restore_runtime_selections = function(secret, manifest, before_groups, policy) {
	const names = keys(before_groups ?? {});
	for (let i = 0; i < length(names); i++) {
		const capability = names[i];
		const entry = manifest?.generated_groups?.[capability];
		const previous = before_groups[capability];
		if (entry == null || type(previous?.preferred) != "string" ||
			type(previous?.visible) != "string" ||
			!wait_for_group_member(secret, selection_group(entry), previous.preferred) ||
			!select_proxy(secret, selection_group(entry), previous.preferred) ||
			!wait_for_group_member(secret, entry.name, previous.visible) ||
			!select_proxy(secret, entry.name, previous.visible)) {
			return false;
		}
		refresh_data_fallback(secret, entry, policy);
	}
	return protected_probes(policy).ok;
};

capture_runtime_selections = function(manifest) {
	const secret = api_secret();
	const state = secret ? proxies(secret, 2) : null;
	if (state?.proxies == null) {
		return { ok: false, error: "runtime_state_unavailable" };
	}
	const selections = {};
	const names = sorted_keys(manifest?.generated_groups ?? {});
	for (let i = 0; i < length(names); i++) {
		const entry = manifest.generated_groups[names[i]];
		const preferred = state.proxies?.[selection_group(entry)]?.now;
		const visible = state.proxies?.[entry?.name]?.now;
		if (type(preferred) != "string" || type(visible) != "string") {
			return { ok: false, error: "runtime_selection_unavailable", capability: names[i] };
		}
		selections[names[i]] = { preferred: preferred, visible: visible };
	}
	return { ok: true, selections: selections };
};

return { wait_for_group_member, selection_group, provider_source_for_group, candidate_leaf_wait_seconds, refresh_data_fallback, wait_for_preferred_runtime, capture_previous_choice, activate_preferred_choice, region_for_choice, activate_manual_choice, activate_direct_fallback, activate_all_direct_fallbacks, candidate_group_names, reset_candidate_groups, candidate_provider_leaves_ready, wait_for_candidate_provider_leaves, restore_runtime_selections, capture_runtime_selections };
};
