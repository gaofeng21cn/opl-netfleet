

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let fail_enable_after_switch, enable_action, disable_action, resume_action, command_enable, command_disable, command_resume;

const ARGV = context.argv ?? [];
const compile_result = context.use("compilation.control").compile_result;
const fail = context.use("events.output").fail;
const ok = context.use("events.output").ok;
const decision_event = context.use("events.record").decision_event;
const record_events = context.use("events.record").record_events;
const event_initiator = context.use("events.record").event_initiator;
const load_manifest = context.use("mihomo.artifacts").load_manifest;
const resolve_profile = context.use("mihomo.backend").resolve_profile;
const ARTIFACT_PATH = context.use("mihomo.backend").ARTIFACT_PATH;
const COMPILED_PROFILE = context.use("mihomo.backend").COMPILED_PROFILE;
const restart = context.use("mihomo.backend").restart;
const MANIFEST_PATH = context.use("mihomo.backend").MANIFEST_PATH;
const running = context.use("mihomo.backend").running;
const test_profile = context.use("mihomo.controller").test_profile;
const proxies = context.use("mihomo.controller").proxies;
const controller_ready = context.use("mihomo.controller").controller_ready;
const measure_providers = context.use("mihomo.latency").measure_providers;
const capture_previous_choice = context.use("mihomo.paths").capture_previous_choice;
const wait_for_group_member = context.use("mihomo.paths").wait_for_group_member;
const reset_candidate_groups = context.use("mihomo.paths").reset_candidate_groups;
const activate_preferred_choice = context.use("mihomo.paths").activate_preferred_choice;
const activate_manual_choice = context.use("mihomo.paths").activate_manual_choice;
const resolve_policy_source = context.use("mihomo.policy-source").resolve;
const require_protected_probes = context.use("mihomo.probes").require_protected_probes;
const protected_probes_after_restart = context.use("mihomo.probes").protected_probes_after_restart;
const runtime_readback = context.use("mihomo.readback").runtime_readback;
const enable_precondition = context.use("models.activation").enable_precondition;
const is_active = context.use("models.activation").is_active;
const selection_snapshot = context.use("models.evidence").selection_snapshot;
const measurement_identity = context.use("models.evidence").measurement_identity;
const sorted_keys = context.use("models.ordering").sorted_keys;
const automatic_capability_order = context.use("models.ordering").automatic_capability_order;
const initial_choice = context.use("models.ordering").initial_choice;
const initial_user_choice = context.use("models.ordering").initial_user_choice;
const automatic_provider_sources = context.use("models.ordering").automatic_provider_sources;
const automatic_selectors_ready = context.use("models.ordering").automatic_selectors_ready;
const automation_config = context.use("models.policy").automation;
const load_policy = context.use("platform.documents").load_policy;
const load_evidence = context.use("platform.documents").load_evidence;
const current_profile = context.use("platform.profile").current_profile;
const upstream_ready = context.use("platform.device").upstream_ready;
const sha256 = context.use("platform.storage").sha256;
const POLICY_PATH = context.use("platform.paths").POLICY_PATH;
const api_secret = context.use("platform.credentials").api_secret;
const set_profile = context.use("platform.profile").set_profile;
const write_evidence = context.use("platform.documents").write_evidence;
const read_json = context.use("platform.storage").read_json;
const backend_enabled = context.use("platform.profile").backend_enabled;
const set_backend_enabled = context.use("platform.profile").set_backend_enabled;
const BACKEND_KIND = context.use("platform.runtime").KIND;
const prepare_recovery_action = context.use("recovery.control").prepare_recovery_action;
const restore_recovery_with_probes = context.use("recovery.control").restore_recovery_with_probes;
const recover_fail_open = context.use("recovery.control").recover_fail_open;
const restore_profile_with_probes = context.use("recovery.control").restore_profile_with_probes;
const enter_passthrough = context.use("recovery.control").enter_passthrough;
const guarded_mutation = context.use("recovery.control").guarded_mutation;
const disable_without_policy = context.use("recovery.control").disable_without_policy;
const clear_recovery = context.use("recovery.state").clear;
const pending_recovery = context.use("recovery.state").pending;
const defer_recovery = context.use("recovery.state").defer;
const automatic_round = context.use("selection.round").automatic_round;
const remove_policy_provider_links = context.use("subscriptions.facts").remove_policy_provider_links;

fail_enable_after_switch = function(policy, original_profile, reason, details) {
	const recovery = restore_recovery_with_probes(policy, reason);
	if (!recovery.ok) {
		fail("enable", "rollback_failed", {
			profile: original_profile,
			reason: reason,
			details: details,
			recovery: recovery
		});
	}
	details.recovery = recovery;
	fail("enable", reason, details);
};

enable_action = function(policy, evidence, quiet) {
	let current = current_profile();
	const stopped = BACKEND_KIND == "native-mihomo" && backend_enabled() != true && !running();
	if (policy.main.enabled != true) {
		fail("enable", "disabled_by_policy", null);
	}
	if (!upstream_ready()) {
		fail("enable", "upstream_unavailable", { profile: current });
	}
	const manifest = load_manifest();
	const capability_names = sorted_keys(manifest?.generated_groups ?? {});
	const automatic_names = automatic_capability_order(policy, manifest);
	if (length(capability_names) == 0) {
		fail("enable", "compiled_groups_missing", null);
	}
	let expected_automatic = 0;
	for (let i = 0; i < length(capability_names); i++) {
		expected_automatic += manifest.generated_groups[capability_names[i]]?.mode == "automatic" ? 1 : 0;
	}
	if (length(automatic_names) != expected_automatic) {
		fail("enable", "automatic_dependency_invalid", null);
	}
	const recovery_profile_ref = policy.recovery_profile.ref;
	const precondition = enable_precondition(stopped ? recovery_profile_ref : current, recovery_profile_ref, manifest);
	if (!precondition.ok) {
		fail("enable", precondition.error, { current: current, expected: recovery_profile_ref });
	}
	const policy_source_path = resolve_policy_source(policy.policy_source);
	const recovery_profile_path = resolve_profile(recovery_profile_ref);
	if (policy_source_path == null || recovery_profile_path == null ||
		sha256(policy_source_path) != manifest?.policy_source?.sha256 ||
		sha256(recovery_profile_path) != manifest?.recovery_profile?.sha256 ||
		sha256(POLICY_PATH) != manifest.policy_sha256 ||
		sha256(ARTIFACT_PATH) != manifest.artifact_sha256) {
		fail("enable", "staged_input_stale", null);
	}
	if (!test_profile(ARTIFACT_PATH)) {
		fail("enable", "staged_profile_invalid", ARTIFACT_PATH);
	}
	if (stopped) {
		prepare_recovery_action(policy, current, true);
		current = current_profile();
	}
	const base_probes = require_protected_probes(policy, "enable");
	const before_secret = api_secret();
	// A newly activated NetFleet profile can start URLTest groups before the
	// automatic round reaches its first controller read.  Capture the native
	// runtime here so every history created by this activation is fresh relative
	// to the round, including providers that initialize faster than the selector.
	const enable_freshness_baseline = before_secret ? proxies(before_secret) : null;
	const previous_choices = {};
	for (let i = 0; i < length(capability_names); i++) {
		const capability = capability_names[i];
		previous_choices[capability] = capture_previous_choice(before_secret,
			manifest.generated_groups[capability], policy.policy_source?.kind == "profile");
		if (!previous_choices[capability].ok) {
			fail("enable", previous_choices[capability].error, {
				capability: capability,
				detail: previous_choices[capability]
			});
		}
	}
	if (!set_profile(COMPILED_PROFILE) || !restart()) {
		const recovery = restore_recovery_with_probes(policy, "owner_switch_failed");
		if (!recovery.ok) {
			fail("enable", "rollback_failed", { profile: current, recovery: recovery });
		}
		fail("enable", "owner_switch_failed", { profile: current, recovery: recovery });
	}
	const secret = api_secret();
	if (!secret) {
		fail_enable_after_switch(policy, current, "api_secret_missing", {});
	}
	const selections = {};
	const automatic_results = {};
	const initialization_grace = automation_config(policy).startup_grace_seconds;
	for (let i = 0; i < length(capability_names); i++) {
		const capability = capability_names[i];
		const entry = manifest.generated_groups[capability];
		const first_choice = initial_choice(manifest, capability);
		const user_choice = initial_user_choice(entry, first_choice);
		if (!entry?.name || !first_choice || !user_choice ||
			!wait_for_group_member(secret, entry.name, user_choice, initialization_grace)) {
			fail_enable_after_switch(policy, current, "initialization_failed", {
				capability: capability,
				initial_choice: first_choice,
				user_choice: user_choice
			});
		}
		selections[capability] = {
			mode: entry.mode,
			selected_group: first_choice,
			user_choice: user_choice,
			trigger: "enable"
		};
	}
	const provider_measurement_ok = length(automatic_names) == 0 ? null :
		measure_providers(secret, automatic_provider_sources(manifest, automatic_names), policy.checks);
	const shared = {entries: {}, prepared: true};
	for (let capability in automatic_names)
		if (!reset_candidate_groups(secret, manifest.generated_groups[capability]))
			fail_enable_after_switch(policy, current, "candidate_group_reset_failed", {capability});
	for (let i = 0; i < length(automatic_names); i++) {
		const capability = automatic_names[i];
		const entry = manifest.generated_groups[capability];
		const parent = policy.capabilities?.[capability]?.prefer_region_from;
		const preferred_region = parent == null ? null : automatic_results[parent]?.decision?.region_id;
		const result = automatic_round(policy, manifest, entry, capability, secret, false,
			enable_freshness_baseline, provider_measurement_ok, preferred_region, shared,
			parent == null ? null : automatic_results[parent]?.decision);
		if (!result.ok) {
			fail_enable_after_switch(policy, current, result.error, {
				capability: capability,
				automatic: result
			});
		}
		automatic_results[capability] = result;
		selections[capability].selected_group = result.decision.group;
	}
	for (let i = 0; i < length(capability_names); i++) {
		const capability = capability_names[i];
		const entry = manifest.generated_groups[capability];
		const activation = entry.mode == "automatic" ?
			activate_preferred_choice(secret, entry, selections[capability].selected_group,
				policy, true, false, automatic_results[capability].decision) :
			activate_manual_choice(secret, entry, selections[capability].user_choice,
				policy, false);
		if (!activation.ok) {
			fail_enable_after_switch(policy, current, activation.error, {
				capability: capability,
				selected_group: selections[capability].selected_group,
				activation: activation
			});
		}
		selections[capability].selected_leaf = activation.leaf;
		selections[capability].data_path = activation.data_path;
	}
	const activation_probes = protected_probes_after_restart(policy);
	if (!activation_probes.ok) {
		fail_enable_after_switch(policy, current, "protected_probe_failed", {
			capabilities: selections,
			protected_probes: activation_probes
		});
	}
	const readback = runtime_readback(COMPILED_PROFILE, manifest);
	if (!readback.mihomo_running || !readback.mihomo_config_valid ||
		!readback.state_available || !readback.runtime_identity_ok ||
		!automatic_selectors_ready(readback, manifest, automatic_names) ||
		current_profile() != COMPILED_PROFILE) {
		fail_enable_after_switch(policy, current, "owner_readback_failed", { readback: readback });
	}
	let next_evidence = evidence;
	for (let i = 0; i < length(automatic_names); i++) {
		const capability = automatic_names[i];
		const result = automatic_results[capability];
			next_evidence = selection_snapshot(next_evidence, result.candidates, capability,
				result.decision, activation_probes, measurement_identity(policy, manifest),
				manifest.generated_groups[capability].candidate_groups);
	}
	const evidence_recorded = length(automatic_names) > 0 && write_evidence(next_evidence);
	const event_entries = [];
	for (let i = 0; i < length(capability_names); i++) {
		const capability = capability_names[i];
		push(event_entries, decision_event("enable", capability,
			previous_choices[capability]?.choice, selections[capability], automatic_results[capability], ARGV[1]));
	}
	const events_recorded = record_events(event_entries);
	const sole_selection = length(capability_names) == 1 ? selections[capability_names[0]] : null;
	if (!clear_recovery()) fail("enable", "recovery_state_write_failed");
	const result = {
		readback: readback,
		capabilities: selections,
		selected_group: sole_selection?.selected_group ?? null,
		selected_leaf: sole_selection?.selected_leaf ?? null,
		data_path: sole_selection?.data_path ?? null,
		protected_probes: activation_probes,
		base_probes: base_probes,
		evidence_recorded: evidence_recorded,
		events_recorded: events_recorded
	};
	if (quiet) return result;
	ok("enable", result);
};

disable_action = function(policy) {
	const current = current_profile();
	if (!is_active(current)) {
		const manifest = read_json(MANIFEST_PATH);
		const readback = runtime_readback(current, manifest);
		if (!readback.netfleet_present) {
			ok("disable", { state: "not_active", profile: current, readback: readback });
			return;
		}
		// UCI may already name a native Profile while the old Mihomo process still
		// serves the generated groups.  The just-observed runtime is the effective
		// owner, so complete the same recovery before reporting disabled.
		const recovery = recover_fail_open(policy, current, "stale_netfleet_runtime");
		if (recovery.ok) {
			remove_policy_provider_links(policy);
			const events_recorded = record_events([decision_event("disable", null, current,
					{ selected_group: current_profile() }, null, ARGV[1])]);
			ok("disable", {
				state: recovery.mode,
				profile: current_profile(),
				stale_runtime: true,
				recovery: recovery,
				events_recorded: events_recorded
			});
			return;
		}
		fail("disable", "fail_open_recovery_failed", {
			stale_runtime: true,
			readback: readback,
			recovery: recovery
		});
	}
	const recovery_profile_ref = policy.recovery_profile.ref;
	const native = restore_profile_with_probes(recovery_profile_ref, policy);
	if (native.ok) {
		remove_policy_provider_links(policy);
		const events_recorded = record_events([decision_event("disable", null, current,
			{ selected_group: recovery_profile_ref }, null, ARGV[1])]);
		ok("disable", {
			state: "native_profile",
			profile: recovery_profile_ref,
			business_ok: native.business_ok,
			protected_probes: native.protected_probes,
			events_recorded: events_recorded
		});
		return;
	}
	// Never reactivate the known-bad NetFleet profile after a failed disable.
	// Let Nikki perform its complete official cleanup and leave the device in
	// passthrough, even when the native proxy profile is exhausted.
	const passthrough = enter_passthrough(policy, "disable_native_restore_failed", true);
	if (passthrough.ok) {
		remove_policy_provider_links(policy);
		passthrough.events_recorded = record_events([{
			at: int(time()), action: "disable", capability: null, from_group: current,
			to_group: "passthrough", region_id: null, provider_id: null, leaf: null,
			delay_ms: null, reason: "native_restore_failed_passthrough",
			initiator: event_initiator(ARGV[1], null)
		}]);
		// A physical WAN/DNS failure can make a direct business probe fail even
		// though Nikki cleanup and next-start persistence are complete.  Expose
		// business_ok as evidence without reactivating or retrying.
		ok("disable", passthrough);
		return;
	}
	if (passthrough.safe) {
		// Cleanup is complete, so do not retry or reactivate the failed profile.
		// Keep the artifact/provider links for manual recovery until persistence is
		// proven, and report the missing durability proof.
		fail("disable", "passthrough_profile_persistence_failed", {
			native: native,
			passthrough: passthrough
		});
	}
	fail("disable", "fail_open_recovery_failed", { native: native, passthrough: passthrough });
};

resume_action = function(policy, evidence) {
	const pending = pending_recovery(policy);
	if (pending == null || is_active(current_profile()) || int(time()) < pending.retry_at) {
		ok("resume", { state: "unchanged" });
		return;
	}
	// Persist the deadline before mutation so a supervisor restart cannot cause
	// an immediate restart loop after a failed activation.
	if (!defer_recovery(policy)) fail("resume", "recovery_state_write_failed");
	if (!upstream_ready()) fail("resume", "upstream_unavailable");
	if (backend_enabled() != true || !running() || !controller_ready(api_secret(), 2)) {
		if (!set_backend_enabled(true)) fail("resume", "backend_enable_failed");
		const restored = restore_profile_with_probes(policy.recovery_profile.ref, policy);
		if (!restored.runtime_ok) {
			const recovery = enter_passthrough(policy, "resume_runtime_unavailable", true);
			fail("resume", "recovery_runtime_unavailable", recovery);
		}
	}
	const compiled = compile_result(policy, false);
	if (!compiled.ok) fail("resume", compiled.error, compiled.detail);
	enable_action(policy, evidence);
};

command_enable = function(argv) {
	const policy = load_policy();
	if (policy == null) fail(argv[0], "policy_unreadable", POLICY_PATH);
	const evidence = load_evidence();
	guarded_mutation("enable", policy, () => enable_action(policy, evidence));
};

command_disable = function(argv) {
	if (!clear_recovery()) fail("disable", "recovery_state_write_failed");
	const policy = load_policy();
	if (policy == null) return disable_without_policy("disable");
	const evidence = load_evidence();
	guarded_mutation("disable", policy, () => disable_action(policy));
};

command_resume = function(argv) {
	const policy = load_policy();
	if (policy == null) fail(argv[0], "policy_unreadable", POLICY_PATH);
	const evidence = load_evidence();
	guarded_mutation("resume", policy, () => resume_action(policy, evidence));
};

return { fail_enable_after_switch, enable_action, disable_action, resume_action, command_enable, command_disable, command_resume };
};
