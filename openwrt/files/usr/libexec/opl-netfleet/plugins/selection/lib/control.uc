

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let automatic_select_action, select_action, maintain_action, command_select, command_maintain;

const ARGV = context.argv ?? [];
const operation_update = context.use("events.operation").update;
const operation_begin = context.use("events.operation").begin;
const fail = context.use("events.output").fail;
const ok = context.use("events.output").ok;
const decision_event = context.use("events.record").decision_event;
const record_events = context.use("events.record").record_events;
const load_manifest = context.use("mihomo.artifacts").load_manifest;
const protected_probes = context.use("mihomo.controller").protected_probes;
const proxies = context.use("mihomo.controller").proxies;
const select_proxy = context.use("mihomo.controller").select;
const reset_candidate_groups = context.use("mihomo.paths").reset_candidate_groups;
const measure_providers = context.use("mihomo.latency").measure_providers;
const selection_group = context.use("mihomo.paths").selection_group;
const activate_preferred_choice = context.use("mihomo.paths").activate_preferred_choice;
const restore_runtime_selections = context.use("mihomo.paths").restore_runtime_selections;
const activate_manual_choice = context.use("mihomo.paths").activate_manual_choice;
const refresh_data_fallback = context.use("mihomo.paths").refresh_data_fallback;
const is_active = context.use("models.activation").is_active;
const selection_snapshot = context.use("models.evidence").selection_snapshot;
const measurement_identity = context.use("models.evidence").measurement_identity;
const automatic_capability_order = context.use("models.ordering").automatic_capability_order;
const automatic_provider_sources = context.use("models.ordering").automatic_provider_sources;
const automatic_mode_active = context.use("models.ordering").automatic_mode_active;
const public_candidates = context.use("models.selection-view").public_candidates;
const manual_member = context.use("selection.algorithm").manual_member;
const load_policy = context.use("platform.documents").load_policy;
const load_evidence = context.use("platform.documents").load_evidence;
const current_profile = context.use("platform.profile").current_profile;
const api_secret = context.use("platform.credentials").api_secret;
const write_evidence = context.use("platform.documents").write_evidence;
const POLICY_PATH = context.use("platform.paths").POLICY_PATH;
const restore_recovery_with_probes = context.use("recovery.control").restore_recovery_with_probes;
const guarded_mutation = context.use("recovery.control").guarded_mutation;
const automatic_round = context.use("selection.round").automatic_round;

automatic_select_action = function(policy, capability, evidence, trigger, initiator) {
	const current = current_profile();
	if (!is_active(current)) fail("select", "profile_not_active", current);
	const manifest = load_manifest();
	const automatic_names = automatic_capability_order(policy, manifest);
	if (length(automatic_names) == 0 || capability != automatic_names[0]) {
		fail("select", "automatic_root_required", automatic_names[0] ?? null);
	}
	operation_update("checking", { subject: "机场健康检查", total: length(automatic_names), completed: 0 });
	for (let i = 0; i < length(automatic_names); i++) {
		const entry = manifest?.generated_groups?.[automatic_names[i]];
		if (entry?.mode != "automatic" || length(entry?.candidate_groups ?? []) == 0) {
			fail("select", "automatic_not_compiled", automatic_names[i]);
		}
	}
	const secret = api_secret();
	if (!secret) fail("select", "api_secret_missing", null);
	const baseline_probes = protected_probes(policy);
	const state = proxies(secret);
	if (state == null || state.proxies == null) {
		if (!baseline_probes.ok) {
			const fallback = restore_recovery_with_probes(policy, "mihomo_state_unavailable");
			if (fallback.ok) {
				ok("select", { state: fallback.mode, reason: "mihomo_state_unavailable", fallback: fallback });
				return;
			}
			fail("select", "rollback_failed", fallback);
		}
		fail("select", "mihomo_state_unavailable", null);
	}
	const before_groups = {};
	for (let i = 0; i < length(automatic_names); i++) {
		const name = automatic_names[i];
		const entry = manifest.generated_groups[name];
		before_groups[name] = {
			preferred: state.proxies?.[selection_group(entry)]?.now ?? null,
			visible: state.proxies?.[entry.name]?.now ?? null
		};
	}
	const provider_measurement_ok = measure_providers(secret,
		automatic_provider_sources(manifest, automatic_names), policy.checks);
	const shared = { entries: {}, prepared: true };
	for (let name in automatic_names) {
		if (!reset_candidate_groups(secret, manifest.generated_groups[name])) fail("select", "candidate_group_reset_failed", name);
	}
	operation_update("measuring", { subject: null, total: 0, completed: 0 });
	const results = {};
	for (let i = 0; i < length(automatic_names); i++) {
		const name = automatic_names[i];
		const parent = policy.capabilities?.[name]?.prefer_region_from;
		const preferred_region = parent == null ? null : results[parent]?.decision?.region_id;
		const result = automatic_round(policy, manifest, manifest.generated_groups[name], name, secret,
			baseline_probes.ok, state, provider_measurement_ok, preferred_region, shared, parent == null ? null : results[parent]?.decision);
		results[name] = result;
		if (!result.ok) {
			const decision = result.decision ?? { error: result.error };
			if (!baseline_probes.ok) {
				const fallback = restore_recovery_with_probes(policy, decision.error);
				if (!fallback.ok) fail("select", "rollback_failed", { capability: name, decision: decision, fallback: fallback });
				ok("select", { state: fallback.mode, reason: decision.error, capability: name,
					fallback: fallback, candidates: public_candidates(result.candidates ?? []) });
				return;
			}
			ok("select", { state: "unchanged", reason: decision.error, capability: name,
				candidates: public_candidates(result.candidates ?? []) });
			return;
		}
	}
	const activations = {};
	for (let i = 0; i < length(automatic_names); i++) {
		const name = automatic_names[i];
		const result = results[name];
		operation_update("applying", { subject: name, total: length(automatic_names), completed: i });
		const activation = activate_preferred_choice(secret, manifest.generated_groups[name],
			result.decision.group, policy, false, false, result.decision);
		activations[name] = activation;
		if (!activation.ok) {
			const restored = baseline_probes.ok &&
				restore_runtime_selections(secret, manifest, before_groups, policy);
			if (restored) {
				fail("select", "automatic_selection_failed", {
					capability: name, decision: result.decision, activation: activation, restored: true
				});
			}
			const fallback = restore_recovery_with_probes(policy, activation.error);
			if (!fallback.ok) fail("select", "rollback_failed", { capability: name, activation: activation, fallback: fallback });
			fail("select", "automatic_selection_failed", { capability: name, activation: activation, fallback: fallback });
		}
	}
	operation_update("verifying", { subject: null, total: length(automatic_names), completed: length(automatic_names) });
	const activation_probes = protected_probes(policy);
	if (!activation_probes.ok) {
		const restored = baseline_probes.ok &&
			restore_runtime_selections(secret, manifest, before_groups, policy);
		if (restored) fail("select", "protected_probe_failed", { restored: true, probes: activation_probes });
		const fallback = restore_recovery_with_probes(policy, "protected_probe_failed");
		if (!fallback.ok) fail("select", "rollback_failed", { probes: activation_probes, fallback: fallback });
		fail("select", "protected_probe_failed", { probes: activation_probes, fallback: fallback });
	}
	let next_evidence = evidence;
	const selections = {};
	const event_entries = [];
	for (let i = 0; i < length(automatic_names); i++) {
		const name = automatic_names[i];
		const result = results[name];
		next_evidence = selection_snapshot(next_evidence, result.candidates, name,
			result.decision, activation_probes, measurement_identity(policy, manifest),
			manifest.generated_groups[name].candidate_groups);
		selections[name] = {
			decision: result.decision,
			selected_group: result.decision.group,
			selected_leaf: activations[name].leaf,
			data_path: activations[name].data_path,
			candidates: public_candidates(result.candidates),
			trigger: trigger ?? "manual"
		};
		push(event_entries, decision_event("select", name, before_groups[name]?.preferred,
			selections[name], result, initiator));
	}
	ok("select", {
		state: "selected",
		root_capability: capability,
		capabilities: selections,
		protected_probes: activation_probes,
		evidence_recorded: write_evidence(next_evidence),
		events_recorded: record_events(event_entries),
		provider_measurement_ok: provider_measurement_ok
	});
};

select_action = function(policy, evidence) {
	const current = current_profile();
	if (!is_active(current)) {
		fail("select", "profile_not_active", current);
	}
	if (policy.main.enabled != true) {
		fail("select", "disabled_by_policy", null);
	}
	const capability = ARGV[1];
	const choice = ARGV[2];
	if (!capability || !choice) {
		fail("select", "usage", "select <capability> <exact-member>");
	}
	operation_begin("selection", "preparing", { subject: capability, total: 1, completed: 0 });
	if (choice == "auto" && ARGV[4] != "region") {
		automatic_select_action(policy, capability, evidence, "manual", ARGV[3]);
		return;
	}
	const manifest = load_manifest();
	if (ARGV[4] == "region" && (policy.capabilities?.[capability]?.enabled != true || !length(filter(manifest?.generated_groups?.[capability]?.region_groups ?? [],
		entry => entry.region == choice)))) fail("select", "region_not_authorized", null);
	const allowed = manual_member(manifest, capability, choice);
	if (!allowed.ok) {
		fail("select", allowed.error, null);
	}
	const secret = api_secret();
	operation_update("checking", { subject: capability, total: 1, completed: 0 });
	const manifest_entry = manifest?.generated_groups?.[capability];
	const before = secret ? proxies(secret)?.proxies?.[allowed.group]?.now ?? null : null;
	const baseline = protected_probes(policy);
	if (!baseline.ok) {
		const recovery = restore_recovery_with_probes(policy, "protected_probe_failed");
		if (!recovery.ok) {
			fail("select", "rollback_failed", { probes: baseline, recovery: recovery });
		}
		fail("select", "protected_probe_failed", { probes: baseline, recovery: recovery });
	}
	operation_update("selecting", { subject: capability, total: 1, completed: 0 });
	const activation = secret && manifest_entry ?
		activate_manual_choice(secret, manifest_entry, allowed.choice, policy, true) :
		{ ok: false, error: "selector_write_failed" };
	if (!activation.ok) {
		let restored = false;
		if (before != null && secret && select_proxy(secret, allowed.group, before)) {
			refresh_data_fallback(secret, manifest_entry, policy);
			restored = protected_probes(policy).ok;
		}
		if (restored) {
			fail("select", activation.error, { activation: activation, restored: before });
		}
		const recovery = restore_recovery_with_probes(policy, activation.error);
		if (!recovery.ok) {
			fail("select", "rollback_failed", { activation: activation, recovery: recovery });
		}
		fail("select", activation.error, { activation: activation, recovery: recovery });
	}
	operation_update("verifying", { subject: null, total: 1, completed: 1 });
	const events_recorded = record_events([decision_event("select", capability, before, {
		selected_group: allowed.choice,
		selected_leaf: activation.leaf,
		trigger: "manual"
	}, null, ARGV[3])]);
	ok("select", {
		capability: capability,
		group: allowed.group,
		selected: allowed.choice,
		selected_leaf: activation.leaf,
		data_path: activation.data_path,
		protected_probes: activation.protected_probes,
		events_recorded: events_recorded
	});
};

maintain_action = function(policy, evidence) {
	const current = current_profile();
	if (!is_active(current)) {
		ok("maintain", { state: "inactive", profile: current });
		return;
	}
	const manifest = load_manifest();
	const automatic_names = automatic_capability_order(policy, manifest);
	const root = automatic_names[0] ?? null;
	const secret = api_secret();
	const state = secret ? proxies(secret, 2) : null;
	if (root == null || state?.proxies == null) {
		fail("maintain", "runtime_unavailable", { root_capability: root });
	}
	if (!automatic_mode_active(manifest, automatic_names, state)) {
		ok("maintain", {
			state: "paused",
			reason: "manual_choice_active",
			root_capability: root
		});
		return;
	}
	operation_begin("selection", "preparing", { subject: root, total: length(automatic_names), completed: 0, parent_id: ARGV[3] });
	automatic_select_action(policy, root, evidence, ARGV[1] ?? "scheduled", ARGV[2] ?? "supervisor");
};

command_select = function(argv) {
	const policy = load_policy();
	if (policy == null) fail(argv[0], "policy_unreadable", POLICY_PATH);
	const evidence = load_evidence();
	guarded_mutation("select", policy, () => select_action(policy, evidence));
};

command_maintain = function(argv) {
	const policy = load_policy();
	if (policy == null) fail(argv[0], "policy_unreadable", POLICY_PATH);
	const evidence = load_evidence();
	guarded_mutation("maintain", policy, () => maintain_action(policy, evidence));
};

return { automatic_select_action, select_action, maintain_action, command_select, command_maintain };
};
