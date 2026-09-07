

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let restore_profile, restore_profile_with_probes, enter_passthrough, native_profile_readback, restore_recovery_action, prepare_recovery_action, recover_fail_open, restore_recovery_with_probes, recover_action, guarded_mutation, disable_without_policy, command_prepare_recovery, command_restore_recovery, command_recover;

const ARGV = context.argv ?? [];
const fail = context.use("events.output").fail;
const ok = context.use("events.output").ok;
const profile_exists = context.use("mihomo.backend").profile_exists;
const restart = context.use("mihomo.backend").restart;
const MANIFEST_PATH = context.use("mihomo.backend").MANIFEST_PATH;
const stop_backend = context.use("mihomo.backend").stop;
const cleanup_state = context.use("mihomo.backend").cleanup_state;
const resolve_profile = context.use("mihomo.backend").resolve_profile;
const ARTIFACT_PATH = context.use("mihomo.backend").ARTIFACT_PATH;
const remove_provider_links = context.use("mihomo.backend").remove_provider_links;
const direct_probes = context.use("mihomo.controller").direct_probes;
const proxies = context.use("mihomo.controller").proxies;
const activate_all_direct_fallbacks = context.use("mihomo.paths").activate_all_direct_fallbacks;
const protected_probes_after_restart = context.use("mihomo.probes").protected_probes_after_restart;
const runtime_readback = context.use("mihomo.readback").runtime_readback;
const state_has_netfleet = context.use("mihomo.readback").state_has_netfleet;
const is_active = context.use("models.activation").is_active;
const passthrough_outcome = context.use("models.activation").passthrough_outcome;
const recovery_owner = context.use("models.activation").recovery_owner;
const recovery_profile = context.use("models.activation").recovery_profile;
const load_policy = context.use("platform.documents").load_policy;
const set_profile = context.use("platform.profile").set_profile;
const read_json = context.use("platform.storage").read_json;
const current_profile = context.use("platform.profile").current_profile;
const set_backend_enabled = context.use("platform.profile").set_backend_enabled;
const backend_enabled = context.use("platform.profile").backend_enabled;
const upstream_ready = context.use("platform.device").upstream_ready;
const api_secret = context.use("platform.credentials").api_secret;
const sha256 = context.use("platform.storage").sha256;
const POLICY_PATH = context.use("platform.paths").POLICY_PATH;
const request_recovery = context.use("recovery.state").request;
const manifest_provider_profiles = context.use("subscriptions.facts").manifest_provider_profiles;

restore_profile = function(profile, manifest) {
	if (type(profile) != "string" || length(profile) == 0 || is_active(profile) ||
		!profile_exists(profile) || !set_profile(profile) || !restart()) {
		return false;
	}
	// Restart readiness and effective profile identity are separate from the UCI
	// string.  Wait for the new owner to expose a native, non-NetFleet runtime;
	// otherwise a stale Mihomo process can make rollback look successful.
	for (let attempt = 0; attempt < 8; attempt++) {
		const readback = runtime_readback(profile, manifest);
		if (readback.mihomo_running && readback.mihomo_config_valid &&
			readback.state_available && readback.runtime_identity_ok) {
			return true;
		}
		if (attempt < 7) {
			system("sleep 1");
		}
	}
	return false;
};

restore_profile_with_probes = function(profile, policy) {
	if (type(profile) != "string" || length(profile) == 0 || is_active(profile)) {
		return { ok: false, runtime_ok: false, business_ok: null, error: "profile_not_restorable", profile: profile };
	}
	if (!restore_profile(profile, read_json(MANIFEST_PATH))) {
		return { ok: false, runtime_ok: false, business_ok: null, error: "profile_restore_failed", profile: profile };
	}
	const probes = protected_probes_after_restart(policy);
	const business_ok = probes?.ok == true ? true : probes?.ok == false ? false : null;
	return {
		// Restoring the native owner and proving business reachability are separate.
		// A remote probe outage must not turn a healthy native Profile into another
		// mutation or force Nikki off; callers still receive the exact probe result.
		ok: true,
		runtime_ok: true,
		business_ok: business_ok,
		mode: "native_profile",
		profile: profile,
		protected_probes: probes
	};
};

enter_passthrough = function(policy, reason, owner_claim) {
	// Only an active NetFleet owner (or a caller that has already proved that it
	// owned the just-failed switch) may ask Nikki to stop.  A user-selected native
	// Profile is otherwise left completely untouched.
	const recovery_profile_ref = policy?.recovery_profile?.ref;
	const before = current_profile();
	const owned = owner_claim == true || is_active(before);
	if (!owned) {
		return {
			ok: true,
			safe: true,
			persistent: true,
			durable: true,
			state: "unchanged",
			mode: "unchanged",
			reason: reason,
			profile: before,
			error: "passthrough_not_owned"
		};
	}
	const recovery_reference = type(recovery_profile_ref) == "string" &&
		!is_active(recovery_profile_ref) ? recovery_profile_ref : null;
	const recovery_valid = recovery_reference != null && profile_exists(recovery_reference);
	const profile_set = recovery_valid &&
		(before == recovery_profile_ref || set_profile(recovery_profile_ref));
	// Persist the emergency escape before stopping the service.  Nikki's own
	// start_service gate reads this UCI flag on the next boot; without it, a
	// reboot could immediately resurrect the failed NetFleet/native path.
	const disabled = set_backend_enabled(false);
	// Nikki remains the sole owner of Mihomo, DNS, nft and policy-routing teardown.
	// NetFleet never assembles a parallel cleanup command.
	const stop_result = stop_backend();
	const cleanup = stop_result?.readback ?? cleanup_state();
	const persistent = recovery_valid && profile_set && current_profile() == recovery_profile_ref &&
		disabled == true && backend_enabled() == false;
	const route_ready = upstream_ready();
	const probes = cleanup?.ok == true && route_ready ? direct_probes(policy, 5) :
		{ ok: null, error: route_ready ? "passthrough_not_clean" : "upstream_unavailable" };
	const outcome = passthrough_outcome(cleanup, persistent, probes?.ok);
	return {
		// Cleanup and next-start persistence define recovery success.  A physical
		// WAN/DNS outage is reported in business_ok and cannot cause a second
		// mutation loop after cleanup is already safe and durable.
		ok: outcome.ok,
		safe: outcome.safe,
		persistent: outcome.persistent,
		durable: outcome.durable,
		state: "passthrough",
		mode: "passthrough",
		reason: reason,
		profile_set: profile_set,
		backend_disabled: disabled,
		stop_ok: stop_result?.ok == true,
		cleanup: cleanup,
		mihomo_stopped: cleanup?.mihomo_stopped == true,
		upstream_ready: route_ready,
		business_ok: outcome.business_ok,
		direct_probes: probes,
		protected_probes: probes
	};
};

native_profile_readback = function(profile, policy) {
	const manifest = read_json(MANIFEST_PATH);
	const readback = runtime_readback(profile, manifest);
	const probes = protected_probes_after_restart(policy);
	return {
		ok: readback.mihomo_running && readback.mihomo_config_valid &&
			readback.state_available && readback.runtime_identity_ok,
		business_ok: probes?.ok == true,
		profile: profile,
		readback: readback,
		protected_probes: probes
	};
};

restore_recovery_action = function(policy) {
	const target = ARGV[1];
	const force_restart = ARGV[2] == "restart";
	if (type(target) != "string" || length(target) == 0 || is_active(target) || !profile_exists(target)) {
		fail("restore-recovery", "recovery_profile_missing", target);
	}
	let result = null;
	if (current_profile() == target && !force_restart) {
		result = native_profile_readback(target, policy);
	} else {
		const restored = restore_profile_with_probes(target, policy);
		result = {
			ok: restored.runtime_ok == true,
			business_ok: restored.business_ok,
			profile: target,
			readback: runtime_readback(target, read_json(MANIFEST_PATH)),
			protected_probes: restored.protected_probes
		};
	}
	if (!result.ok) {
		const passthrough = enter_passthrough(policy, "restore_native_failed", true);
		fail("restore-recovery", passthrough.ok ? "recovery_profile_restore_failed" : "rollback_failed", {
			target: target,
			result: result,
			recovery: passthrough
		});
	}
	ok("restore-recovery", result);
};

prepare_recovery_action = function(policy) {
	const expected = ARGV[1];
	const force_restart = ARGV[2] == "restart";
	const current = current_profile();
	const target = policy?.recovery_profile?.ref;
	if (type(expected) != "string" || current != expected) {
		fail("prepare-recovery", "profile_precondition_stale", { expected: expected, current: current });
	}
	if (type(target) != "string" || is_active(target) || !profile_exists(target)) {
		fail("prepare-recovery", "recovery_profile_missing", target);
	}
	if (!upstream_ready()) {
		fail("prepare-recovery", "upstream_unavailable", { profile: current });
	}
	const was_enabled = backend_enabled();
	if (was_enabled != true && !set_backend_enabled(true)) {
		fail("prepare-recovery", "backend_enable_failed", { profile: current });
	}
	let prepared = null;
	if (current == target && !force_restart && was_enabled == true) {
		prepared = native_profile_readback(target, policy);
	} else {
		const switched = restore_profile_with_probes(target, policy);
		prepared = {
			ok: switched.runtime_ok == true,
			business_ok: switched.business_ok,
			profile: target,
			readback: runtime_readback(target, read_json(MANIFEST_PATH)),
			protected_probes: switched.protected_probes
		};
	}
	if (prepared.ok && prepared.business_ok == true) {
		ok("prepare-recovery", prepared);
		return;
	}
	let recovery = null;
	if (!is_active(expected) && profile_exists(expected)) {
		const restored = restore_profile_with_probes(expected, policy);
		recovery = {
			ok: restored.runtime_ok == true,
			business_ok: restored.business_ok,
			profile: expected,
			protected_probes: restored.protected_probes
		};
	}
	if (recovery?.ok != true) {
		recovery = enter_passthrough(policy, "prepare_recovery_rollback_failed", true);
	}
	fail("prepare-recovery", recovery?.ok == true ? "recovery_profile_unhealthy" : "rollback_failed", {
		target: target,
		prepared: prepared,
		recovery: recovery
	});
};

recover_fail_open = function(policy, preferred_profile, reason) {
	const attempts = [];
	const before = current_profile();
	const manifest = read_json(MANIFEST_PATH);
	let owner = recovery_owner(before, preferred_profile, false);
	let owner_readback = null;
	if (!owner) {
		// A failed switch can leave generated groups alive for a short time even if
		// UCI already points at a native Profile.  Recognize that residue read-only;
		// never infer ownership from an arbitrary user Profile name.
		owner_readback = runtime_readback(before, manifest);
		owner = recovery_owner(before, preferred_profile, owner_readback.netfleet_present);
	}
	if (!owner) {
		return {
			ok: true,
			mode: "unchanged",
			profile: before,
			reason: reason,
			attempts: [],
			owner_readback: owner_readback
		};
	}

	const recovery_profile_ref = policy?.recovery_profile?.ref;
	const recovery_valid = type(recovery_profile_ref) == "string" &&
		!is_active(recovery_profile_ref) && profile_exists(recovery_profile_ref);
	if (recovery_valid) {
		const attempt = restore_profile_with_probes(recovery_profile_ref, policy);
		push(attempts, attempt);
		if (attempt.runtime_ok == true) {
			return {
				ok: true,
				mode: "native_profile",
				profile: recovery_profile_ref,
				business_ok: attempt.business_ok,
				protected_probes: attempt.protected_probes,
				reason: reason,
				attempts: attempts
			};
		}
	}
	const passthrough = enter_passthrough(policy, reason, true);
	passthrough.attempts = attempts;
	return passthrough;
};

restore_recovery_with_probes = function(policy, reason) {
	const intent_recorded = !is_active(current_profile()) || request_recovery(policy, reason);
	const manifest = read_json(MANIFEST_PATH);
	const secret = api_secret();
	let direct = null;
	// Move an active transaction to its explicit DIRECT guard before restarting
	// Nikki.  DIRECT is the immediate data-plane escape, not the transaction
	// outcome: a failed enable/select must still return ownership to Recovery Profile
	// (or, if that cannot be proved, Nikki's official passthrough cleanup).
	if (is_active(current_profile()) && length(keys(manifest?.generated_groups ?? {})) > 0 && secret) {
		direct = activate_all_direct_fallbacks(secret, manifest, policy);
	}
	const recovery = recover_fail_open(policy, current_profile(), reason);
	recovery.direct = direct;
	recovery.intent_recorded = intent_recorded;
	return recovery;
};

recover_action = function(policy) {
	const reason = ARGV[1] ?? "runtime_unavailable";
	const before = current_profile();
	const manifest = read_json(MANIFEST_PATH);
	const state = api_secret() ? proxies(api_secret(), 1) : null;
	if (!is_active(before) && !state_has_netfleet(state, manifest, before)) {
		ok("recover", { state: "unchanged", profile: before, reason: reason });
		return;
	}
	if (reason == "lan_ingress_unavailable" || reason == "dns_ingress_unavailable") {
		const intent_recorded = request_recovery(policy, reason);
		// Recovery Profiles inherit Nikki's global LAN/listener platform values.
		// Switching Profile cannot repair this failure and would preserve the same
		// black hole, so ask Nikki to remove interception and persist passthrough.
		const passthrough = enter_passthrough(policy, reason, true);
		passthrough.intent_recorded = intent_recorded;
		if (!passthrough.ok) fail("recover", "fail_open_recovery_failed", passthrough);
		ok("recover", passthrough);
		return;
	}
	const recovery = restore_recovery_with_probes(policy, reason);
	if (!recovery.ok) fail("recover", "fail_open_recovery_failed", recovery);
	ok("recover", recovery);
};

guarded_mutation = function(action, policy, callback) {
	try {
		callback();
	} catch (error) {
		let recovery = null;
		let rollback_error = null;
		try {
			recovery = action == "disable" ?
				recover_fail_open(policy, current_profile(), "unexpected_error") :
				restore_recovery_with_probes(policy, "unexpected_error");
		} catch (rollback) {
			rollback_error = `${rollback}`;
		}
		if (recovery == null || !recovery.ok) {
			fail(action, "rollback_failed", {
				unexpected_error: `${error}`,
				unexpected_stacktrace: error?.stacktrace ?? [],
				rollback_error: rollback_error,
				profile: current_profile(),
				recovery: recovery
			});
		}
		fail(action, "unexpected_error", {
			unexpected_error: `${error}`,
			unexpected_stacktrace: error?.stacktrace ?? [],
			recovery: recovery
		});
	}
};

disable_without_policy = function(action_name) {
	const owner_action = action_name ?? "disable";
	// The policy is not required to ask Nikki for an emergency cleanup.  Use a
	// validated manifest recovery target only as the next-start profile; never re-enable the
	// compiled profile when policy/manifest state is damaged.
	const manifest = read_json(MANIFEST_PATH);
	const before = current_profile();
	const owner_readback = runtime_readback(before, manifest);
	if (!is_active(before) && !owner_readback.netfleet_present) {
		// A damaged/missing policy must never turn a user-selected native Nikki
		// profile into a passthrough outage.  There is nothing for NetFleet to
		// disable when its exact artifact is not the current owner.
		ok(owner_action, {
			state: "not_active",
			policy_unreadable: true,
			profile: before,
			owner_readback: owner_readback
		});
		return;
	}
	const manifest_recovery_path = resolve_profile(manifest?.recovery_profile?.ref);
	const recovery = recovery_profile(manifest, sha256(ARTIFACT_PATH), before,
		manifest_recovery_path == null ? null : sha256(manifest_recovery_path));
	const recovery_valid = recovery != null && profile_exists(recovery);
	// A valid manifest binds both artifact and Recovery Profile bytes. Prefer the
	// same native runtime restoration used by normal disable; policy loss only
	// makes business probes unavailable, it does not justify disabling a healthy
	// native owner.
	if (recovery_valid && restore_profile(recovery, manifest)) {
		remove_provider_links(manifest_provider_profiles(manifest));
		ok(owner_action, {
			state: "native_profile",
			policy_unreadable: true,
			profile: recovery,
			runtime_ok: true,
			business_ok: null,
			owner_readback: runtime_readback(recovery, manifest),
			protected_probes: { ok: null, error: "policy_unreadable" }
		});
		return;
	}
	const profile_set = recovery_valid &&
		(current_profile() == recovery || set_profile(recovery));
	const disabled = set_backend_enabled(false);
	const stop_result = stop_backend();
	const cleanup = stop_result?.readback ?? cleanup_state();
	const persistent = recovery_valid && profile_set && current_profile() == recovery &&
		disabled == true && backend_enabled() == false;
	const outcome = passthrough_outcome(cleanup, persistent, null);
	const result = {
		state: "passthrough",
		policy_unreadable: true,
		stale_runtime: !is_active(before) && owner_readback.netfleet_present,
		owner_readback: owner_readback,
		ok: outcome.ok,
		safe: outcome.safe,
		persistent: outcome.persistent,
		durable: outcome.durable,
		profile_set: profile_set,
		backend_disabled: disabled,
		stop_ok: stop_result?.ok == true,
		cleanup: cleanup,
		mihomo_stopped: cleanup?.mihomo_stopped == true,
		upstream_ready: upstream_ready(),
		business_ok: outcome.business_ok,
		direct_probes: null,
		protected_probes: { ok: false, error: "policy_unreadable" }
	};
	if (outcome.ok) {
		remove_provider_links(manifest_provider_profiles(manifest));
		ok(owner_action, result);
		return;
	}
	fail(owner_action, outcome.safe ? "passthrough_profile_persistence_failed" : "fail_open_recovery_failed", result);
};

command_prepare_recovery = function(argv) {
	const policy = load_policy();
	if (policy == null) fail(argv[0], "policy_unreadable", POLICY_PATH);
	guarded_mutation("prepare-recovery", policy, () => prepare_recovery_action(policy));
};

command_restore_recovery = function(argv) {
	const policy = load_policy();
	if (policy == null) fail(argv[0], "policy_unreadable", POLICY_PATH);
	guarded_mutation("restore-recovery", policy, () => restore_recovery_action(policy));
};

command_recover = function(argv) {
	const policy = load_policy();
	if (policy == null) return disable_without_policy(argv[0]);
	guarded_mutation("recover", policy, () => recover_action(policy));
};

return { restore_profile, restore_profile_with_probes, enter_passthrough, native_profile_readback, restore_recovery_action, prepare_recovery_action, recover_fail_open, restore_recovery_with_probes, recover_action, guarded_mutation, disable_without_policy, command_prepare_recovery, command_restore_recovery, command_recover };
};
