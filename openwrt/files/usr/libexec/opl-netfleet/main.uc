#!/usr/bin/ucode

import { read_yaml, read_json, sha256, file_mtime, current_profile, nikki_enabled, set_nikki_enabled, api_secret, set_profile, shell_quote, subscription_display_name, subscription_quota, upstream_ready, write_evidence, POLICY_PATH, EVIDENCE_PATH } from "./adapters/uci.uc";
import { resolve_profile, profile_exists, restart, update_subscription, stop as stop_nikki, cleanup_state, running, lan_runtime_state, install_artifact, remove_artifact, test_profile_object, prepare_provider_links, remove_provider_links, ARTIFACT_PATH, MANIFEST_PATH, PROFILE_ENTRY_PATH, COMPILED_PROFILE } from "./adapters/nikki.uc";
import { resolve as resolve_policy_source, load as load_policy_source } from "./adapters/policy_source.uc";
import { test_profile, test_runtime, controller_ready, proxies, proxy_providers, connections as current_connections, select as select_proxy, unfix as unfix_proxy, protected_probes, direct_probes } from "./adapters/mihomo.uc";
import { measure as measure_latency, measure_providers, complete_from_fresh_history } from "./adapters/latency.uc";
import { read_events, write_events, nikki_netfleet_lines } from "./adapters/events.uc";
import { validate as validate_policy, automation as automation_config, guard_probe_url } from "./core/policy.uc";
import { compile as compile_profile } from "./core/compiler.uc";
import { manual_member, choose_automatic, provider_group_leaf, provider_round_summary } from "./core/selector.uc";
import { validate as validate_evidence, selection_snapshot, measurement_identity } from "./core/evidence.uc";
import { append as append_events, validate as validate_events } from "./core/events.uc";
import { enable_precondition, is_active, recovery_owner, recovery_profile, passthrough_outcome, preferred_runtime_ready, expected_runtime_groups, expected_runtime_residue_groups } from "./core/activation.uc";
import { build as build_status, resolve_runtime } from "./core/status.uc";
import { enabled_sections as enabled_subscription_sections, quota_config as subscription_quota_config, cache_accepted, evaluate_entry, summarize as summarize_refresh, public_results as public_subscription_results, unavailable_results, project as project_subscriptions } from "./core/subscription.uc";
import { service_state } from "./adapters/service.uc";
import { load as load_provider_profile_result } from "./application/providers.uc";
import { get as onboarding_get, apply as onboarding_apply } from "./application/onboarding.uc";
import { get as config_get, validate as config_validate, save as config_save, apply as config_apply } from "./application/configuration.uc";
import { ok, fail } from "./output.uc";
import { run as native_sources } from "./application/native_sources.uc";

const REFRESH_DIR = "/tmp/opl-netfleet-subscription-refresh";
const MAIN_PATH = "/usr/libexec/opl-netfleet/main.uc";
const INSTALLED_IDENTITY_PATH = "/etc/opl-netfleet/installed.json";
const PACKAGE_BUILD_PATH = "/usr/share/opl-netfleet/build.json";

function normalized_build(identity, version_field) {
	const version = type(identity) == "object" ? identity[version_field] : null;
	const commit = identity?.source_commit;
	const tree = identity?.source_tree;
	if (type(version) != "string" || !match(version, /^[0-9][0-9A-Za-z.+~-]*$/) ||
		type(commit) != "string" || !match(commit, /^[0-9a-f]{40}$/) ||
		type(tree) != "string" || !match(tree, /^[0-9a-f]{40}$/)) return null;
	return { version: version, source_commit: commit, source_tree: tree };
};

function installed_build() {
	const packaged = normalized_build(read_json(PACKAGE_BUILD_PATH), "version");
	if (packaged != null) return packaged;
	const deployed = normalized_build(read_json(INSTALLED_IDENTITY_PATH), "product_version");
	return deployed ?? { version: null, source_commit: null, source_tree: null };
};

function load_policy(path) {
	const source = path ?? POLICY_PATH;
	const policy = read_json(source);
	if (policy == null) {
		return null;
	}
	const validation = validate_policy(policy);
	if (!validation.ok) {
		return null;
	}
	return policy;
};

function load_evidence() {
	const evidence = read_json(EVIDENCE_PATH);
	const validation = validate_evidence(evidence);
	return validation.ok ? evidence : null;
};

function record_events(additions) {
	const existing = read_events();
	const current = validate_events(existing).ok ? existing : null;
	return write_events(append_events(current, additions));
};

function event_initiator(requested, trigger) {
	if (trigger == "scheduled") return "supervisor";
	return index(["luci", "cli", "deployer", "supervisor"], requested) >= 0 ? requested : "cli";
};

function decision_event(action, capability, before_group, selection, result, initiator) {
	const decision = result?.decision;
	return {
		at: int(time()),
		action: action,
		capability: capability ?? null,
		from_group: before_group ?? null,
		to_group: selection?.selected_group ?? decision?.group ?? null,
		region_id: decision?.region_id ?? null,
		provider_id: decision?.provider_id ?? null,
		leaf: selection?.selected_leaf ?? null,
		delay_ms: decision?.delay_ms ?? null,
		reason: decision?.reason ?? (action == "disable" ? "native_restored" : "manual_or_initial"),
		trigger: selection?.trigger ?? null,
		initiator: event_initiator(initiator, selection?.trigger)
	};
};

function refresh_event(result, requested) {
	return {
		at: int(time()),
		action: "refresh",
		reason: result.reason,
		initiator: event_initiator(requested, requested == "scheduled" ? "scheduled" : null),
		provider_count: result.provider_count ?? 0,
		changed_count: result.changed_count ?? 0,
		failed_count: result.failed_count ?? 0,
		reloaded: result.reloaded == true,
		ok: result.ok == true,
		subscriptions: result.subscriptions ?? []
	};
};

function load_manifest() {
	const manifest = read_json(MANIFEST_PATH);
	if (manifest == null) {
		fail("runtime", "staged_manifest_missing", MANIFEST_PATH);
	}
	return manifest;
};

function sorted_keys(object) {
	const result = [];
	const names = keys(object ?? {});
	for (let i = 0; i < length(names); i++) {
		push(result, names[i]);
		for (let j = length(result) - 1; j > 0 && result[j] < result[j - 1]; j--) {
			const previous = result[j - 1];
			result[j - 1] = result[j];
			result[j] = previous;
		}
	}
	return result;
};

function subscription_facts(policy) {
	const facts = [];
	const sections = enabled_subscription_sections(policy);
	for (let i = 0; i < length(sections); i++) {
		const section = sections[i];
		const path = resolve_profile(`subscription:${section}`);
		const digest = path == null ? null : sha256(path);
		const parsed = digest == null ? null : read_yaml(path);
		push(facts, {
			section: section,
			ref: `subscription:${section}`,
			display_name: subscription_display_name(section),
			present: digest != null,
			digest: digest,
			valid: cache_accepted(parsed),
			node_count: type(parsed?.proxies) == "array" ? length(parsed.proxies) : null,
			updated_at: path == null ? null : file_mtime(path),
			quota: subscription_quota(section, subscription_quota_config(policy, section))
		});
	}
	return facts;
};

function subscription_refresh_projection(policy) {
	const store = read_events();
	const events = validate_events(store).ok ? store?.events ?? [] : [];
	return project_subscriptions(automation_config(policy), subscription_facts(policy), events);
};

function automatic_capability_order(policy, manifest) {
	const pending = [];
	const generated = manifest?.generated_groups ?? {};
	const names = sorted_keys(generated);
	for (let i = 0; i < length(names); i++) {
		const name = names[i];
		if (policy.capabilities?.[name]?.enabled == true && generated[name]?.mode == "automatic") {
			push(pending, name);
		}
	}
	const result = [];
	const added = {};
	for (let pass = 0; pass < length(pending); pass++) {
		let progress = false;
		for (let i = 0; i < length(pending); i++) {
			const name = pending[i];
			const parent = policy.capabilities?.[name]?.prefer_region_from;
			if (added[name] == true || (parent != null && added[parent] != true)) {
				continue;
			}
			push(result, name);
			added[name] = true;
			progress = true;
		}
		if (!progress) break;
	}
	return length(result) == length(pending) ? result : [];
};

function provider_sources(entry) {
	const result = [];
	const providers = entry?.providers ?? {};
	const names = keys(providers);
	for (let i = 0; i < length(names); i++) {
		const source = providers[names[i]]?.source_name;
		if (type(source) == "string" && length(source) > 0) {
			push(result, source);
		}
	}
	return result;
};

function automatic_provider_sources(manifest, capability_names) {
	const result = [];
	const seen = {};
	for (let i = 0; i < length(capability_names); i++) {
		const sources = provider_sources(manifest?.generated_groups?.[capability_names[i]]);
		for (let j = 0; j < length(sources); j++) {
			if (seen[sources[j]] != true) {
				seen[sources[j]] = true;
				push(result, sources[j]);
			}
		}
	}
	return result;
};

function require_provider_profiles(policy, stage) {
	const result = load_provider_profile_result(policy);
	if (!result.ok) {
		fail(stage, result.error, result.detail);
	}
	return result.profiles;
};

function recovery_runtime_groups(profile, manifest) {
	const recovery = manifest?.recovery_profile;
	const path = resolve_profile(profile);
	if (is_active(profile) || path == null || recovery?.ref != profile ||
		type(recovery?.sha256) != "string" || sha256(path) != recovery.sha256) return [];
	const source = read_yaml(path);
	const groups = source?.["proxy-groups"] ?? [];
	const result = [];
	for (let i = 0; i < length(groups); i++) {
		const name = groups[i]?.name;
		if (type(name) == "string" && length(name) > 0) push(result, name);
	}
	return result;
};

function state_has_netfleet(state, manifest, profile) {
	const current = state?.proxies ?? {};
	const expected = is_active(profile) ? expected_runtime_groups(manifest) :
		expected_runtime_residue_groups(manifest, recovery_runtime_groups(profile, manifest));
	for (let i = 0; i < length(expected); i++) {
		if (current[expected[i]] != null) return true;
	}
	return false;
};

function runtime_readback(profile, manifest) {
	const secret = api_secret();
	const proxy_state = secret ? proxies(secret) : null;
	const current = proxy_state?.proxies ?? {};
	const selected = {};
	const expected = expected_runtime_groups(manifest);
	const residue = is_active(profile) ? expected :
		expected_runtime_residue_groups(manifest, recovery_runtime_groups(profile, manifest));
	const expected_set = {};
	let present_count = 0;
	let missing_count = 0;
	let residue_present_count = 0;
	for (let i = 0; i < length(expected); i++) {
		expected_set[expected[i]] = true;
		if (current[expected[i]] != null) {
			present_count++;
			selected[expected[i]] = current[expected[i]]?.now ?? null;
		} else {
			missing_count++;
		}
	}
	for (let i = 0; i < length(residue); i++) {
		if (current[residue[i]] != null) residue_present_count++;
	}
	const unexpected_netfleet = false;
	const profile_match = current_profile() == profile;
	const manifest_valid = manifest?.kind == "opl-netfleet-manifest" &&
		manifest?.schema_version == 2 && type(manifest?.artifact_sha256) == "string" &&
		match(manifest.artifact_sha256, /^[0-9a-f]{64}$/);
	const artifact_identity_ok = !is_active(profile) ||
		(manifest_valid && sha256(ARTIFACT_PATH) == manifest.artifact_sha256);
	const generated_complete = length(expected) > 0 && missing_count == 0;
	const netfleet_present = residue_present_count > 0 || unexpected_netfleet;
	return {
		profile: profile,
		profile_match: profile_match,
		mihomo_running: running(),
		mihomo_config_valid: test_runtime(),
		state_available: proxy_state?.proxies != null,
		netfleet_present: netfleet_present,
		generated_complete: generated_complete,
		unexpected_netfleet: unexpected_netfleet,
		expected_group_count: length(expected),
		present_group_count: present_count,
		missing_group_count: missing_count,
		residue_group_count: length(residue),
		residue_present_count: residue_present_count,
		artifact_identity_ok: artifact_identity_ok,
		runtime_identity_ok: profile_match && artifact_identity_ok &&
			(is_active(profile) ? generated_complete && !unexpected_netfleet : !netfleet_present),
		selected: selected
	};
};

function automatic_selectors_ready(readback, manifest, capability_names) {
	for (let i = 0; i < length(capability_names); i++) {
		const entry = manifest?.generated_groups?.[capability_names[i]];
		if (type(entry?.name) != "string" || type(entry?.automatic_name) != "string" ||
			readback?.selected?.[entry.name] != entry.automatic_name) {
			return false;
		}
	}
	return true;
};

function restore_profile(profile, manifest) {
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

function require_protected_probes(policy, action) {
	const result = protected_probes(policy);
	if (!result.ok) {
		fail(action, result.error, result);
	}
	return result;
};

function initial_choice(manifest, capability) {
	const entry = manifest?.generated_groups?.[capability];
	const groups = entry?.candidate_groups ?? [];
	for (let i = 0; i < length(groups); i++) {
		if (groups[i]?.role == "primary") {
			return groups[i].name;
		}
	}
	return entry?.members?.[0] ?? null;
};

function initial_user_choice(entry, candidate_group) {
	if (entry?.mode == "automatic") return entry?.automatic_name;
	let candidate_region = null;
	const candidates = entry?.candidate_groups ?? [];
	for (let i = 0; i < length(candidates); i++) {
		if (candidates[i]?.name == candidate_group) candidate_region = candidates[i]?.region;
	}
	const regions = entry?.region_groups ?? [];
	for (let i = 0; i < length(regions); i++) {
		if (regions[i]?.region == candidate_region) return regions[i].name;
	}
	return regions[0]?.name ?? entry?.direct_name ?? "DIRECT";
};

function compile_result(policy, allow_active) {
	const current = current_profile();
	if (is_active(current) && allow_active != true) {
		return { ok: false, error: "active_profile_requires_disable", detail: current };
	}
	const source_path = resolve_policy_source(policy.policy_source);
	if (source_path == null || system(`test -f ${shell_quote(source_path)}`) != 0) {
		return { ok: false, error: "policy_source_missing", detail: policy.policy_source.ref };
	}
	const baseline = load_policy_source(policy.policy_source);
	if (baseline == null) {
		return { ok: false, error: "policy_source_unreadable", detail: source_path };
	}
	const recovery_path = resolve_profile(policy.recovery_profile.ref);
	if (recovery_path == null || system(`test -f ${shell_quote(recovery_path)}`) != 0) {
		return { ok: false, error: "recovery_profile_missing", detail: policy.recovery_profile.ref };
	}
	const provider_result = load_provider_profile_result(policy);
	if (!provider_result.ok) {
		return provider_result;
	}
	const provider_profiles = provider_result.profiles;
	const result = compile_profile(baseline, policy, sha256(source_path), sha256(recovery_path),
		sha256(POLICY_PATH), provider_profiles);
	if (!result.ok) {
		return { ok: false, error: "compile_rejected", detail: result.errors };
	}
	if (!prepare_provider_links(provider_profiles)) {
		// A partially prepared SAFE_PATH must not survive a failed compile.  The
		// active Nikki profile is untouched, but stale links would contaminate a
		// later staged attempt.
		if (allow_active != true) remove_provider_links(provider_profiles);
		return { ok: false, error: "provider_link_prepare_failed", detail: null };
	}
	if (!test_profile_object(result.profile)) {
		if (allow_active != true) remove_provider_links(provider_profiles);
		return { ok: false, error: "staged_profile_test_failed", detail: null };
	}
	if (!install_artifact(result.profile, result.manifest) || !test_profile(ARTIFACT_PATH)) {
		if (allow_active != true) remove_provider_links(provider_profiles);
		return { ok: false, error: "staged_readback_failed", detail: null };
	}
	return { ok: true, result: {
		state: "staged",
		artifact: ARTIFACT_PATH,
		manifest: MANIFEST_PATH,
		policy_source: policy.policy_source,
		recovery_profile: policy.recovery_profile.ref,
		binding_count: length(keys(policy.bindings))
	} };
};

function compile_action(policy) {
	const result = compile_result(policy, false);
	if (!result.ok) {
		fail("compile", result.error, result.detail);
	}
	ok("compile", result.result);
};

function protected_probes_after_restart(policy) {
	let result = null;
	// Nikki restart can leave the data plane unavailable briefly on slower
	// targets.  Keep the total probe window bounded; a failed probe is never a
	// reason to restart Nikki again from this helper.
	for (let attempt = 0; attempt < 4; attempt++) {
		result = protected_probes(policy, 4);
		if (result.ok || attempt == 3) {
			return result;
		}
		system("sleep 1");
	}
	return result;
};

function restore_profile_with_probes(profile, policy) {
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

function enter_passthrough(policy, reason, owner_claim) {
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
	const disabled = set_nikki_enabled(false);
	// Nikki remains the sole owner of Mihomo, DNS, nft and policy-routing teardown.
	// NetFleet never assembles a parallel cleanup command.
	const stop_result = stop_nikki();
	const cleanup = stop_result?.readback ?? cleanup_state();
	const persistent = recovery_valid && profile_set && current_profile() == recovery_profile_ref &&
		disabled == true && nikki_enabled() == false;
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
		nikki_disabled: disabled,
		stop_ok: stop_result?.ok == true,
		cleanup: cleanup,
		mihomo_stopped: cleanup?.mihomo_stopped == true,
		upstream_ready: route_ready,
		business_ok: outcome.business_ok,
		direct_probes: probes,
		protected_probes: probes
	};
};

function native_profile_readback(profile, policy) {
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

function restore_recovery_action(policy) {
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

function prepare_recovery_action(policy) {
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
	const was_enabled = nikki_enabled();
	if (was_enabled != true && !set_nikki_enabled(true)) {
		fail("prepare-recovery", "nikki_enable_failed", { profile: current });
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

function recover_fail_open(policy, preferred_profile, reason) {
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

function policy_provider_profiles(policy) {
	const result = {};
	const names = keys(policy.providers ?? {});
	for (let i = 0; i < length(names); i++) {
		const name = names[i];
		const section = policy.providers[name]?.section;
		if (type(section) == "string" && length(section) > 0) {
			result[name] = { path: resolve_profile(`subscription:${section}`) };
		}
	}
	return result;
};

function manifest_provider_profiles(manifest) {
	const result = {};
	const generated = manifest?.generated_groups ?? {};
	const capability_names = keys(generated);
	for (let capability_index = 0; capability_index < length(capability_names); capability_index++) {
		const providers = generated[capability_names[capability_index]]?.providers ?? {};
		const names = keys(providers);
		for (let i = 0; i < length(names); i++) {
			const name = names[i];
			const section = providers[name]?.section;
			if (!match(name, /^[A-Za-z0-9_-]+$/) ||
				type(section) != "string" || !match(section, /^[A-Za-z0-9_]+$/)) {
				continue;
			}
			const path = resolve_profile(`subscription:${section}`);
			if (path != null) {
				result[name] = { path: path };
			}
		}
	}
	return result;
};

function remove_policy_provider_links(policy) {
	remove_provider_links(policy_provider_profiles(policy));
};

function wait_for_group_member(secret, group, member, wait_seconds) {
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

function selection_group(entry) {
	return entry?.selector_name ?? entry?.name;
};

function provider_source_for_group(entry, group) {
	const groups = entry?.candidate_groups ?? [];
	for (let i = 0; i < length(groups); i++) {
		if (groups[i]?.name == group) {
			return entry?.providers?.[groups[i]?.provider]?.source_name ?? null;
		}
	}
	return null;
};

function measured_group_leaf(secret, entry, group, policy) {
	const round = measure_latency(secret, group, policy.checks);
	const state = proxies(secret);
	const provider_state = proxy_providers(secret, 1)?.providers ?? null;
	const source_name = provider_source_for_group(entry, group);
	const leaf = provider_group_leaf(state?.proxies, provider_state, source_name, group);
	return {
		ok: leaf != null && round?.results?.[leaf]?.status == "ok",
		leaf: leaf,
		source_name: source_name,
		round: round,
		state: state,
		provider_state: provider_state
	};
};

function refresh_data_fallback(secret, entry, policy, provider_state) {
	const round = measure_latency(secret, entry.name, policy.checks);
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

function wait_for_preferred_runtime(secret, entry, choice, policy, provider_state, after_restart) {
	let fallback = refresh_data_fallback(secret, entry, policy, provider_state);
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

function capture_previous_choice(secret, entry, required) {
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

function activate_preferred_choice(secret, entry, choice, policy, after_restart, verify_probes) {
	const selector = selection_group(entry);
	if (!wait_for_group_member(secret, selector, choice) || !select_proxy(secret, selector, choice)) {
		return { ok: false, error: "selector_write_failed", choice: choice };
	}
	const leaf = measured_group_leaf(secret, entry, choice, policy);
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
			error: "preferred_path_unavailable",
			choice: choice,
			leaf: leaf.leaf,
			data_path: fallback.runtime?.data_path ?? "unknown"
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

function region_for_choice(entry, choice) {
	const regions = entry?.region_groups ?? [];
	for (let i = 0; i < length(regions); i++) {
		if (regions[i]?.name == choice) return regions[i]?.region ?? null;
	}
	return null;
};

function activate_manual_choice(secret, entry, choice, policy, verify_probes) {
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
	measure_latency(secret, choice, policy.checks);
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

function activate_direct_fallback(secret, entry) {
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

function activate_all_direct_fallbacks(secret, manifest, policy) {
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

function restore_recovery_with_probes(policy, reason) {
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
	return recovery;
};

function provider_quotas(policy) {
	const result = {};
	const names = keys(policy.providers ?? {});
	for (let i = 0; i < length(names); i++) {
		const name = names[i];
		const provider = policy.providers[name];
		if (provider?.enabled == true) {
			result[name] = subscription_quota(provider.section, provider.quota);
		}
	}
	return result;
};

function provider_display_names(policy) {
	const result = {};
	const names = keys(policy.providers ?? {});
	for (let i = 0; i < length(names); i++) {
		const name = names[i];
		const provider = policy.providers[name];
		result[name] = subscription_display_name(provider.section);
	}
	return result;
};

function event_display_names(policy) {
	const capabilities = {};
	const capability_names = keys(policy?.capabilities ?? {});
	for (let i = 0; i < length(capability_names); i++) {
		const name = capability_names[i];
		const display = policy.capabilities[name]?.display_name;
		if (type(display) == "string" && length(display) > 0) {
			capabilities[name] = display;
		}
	}
	const regions = {};
	const region_names = keys(policy?.regions ?? {});
	for (let i = 0; i < length(region_names); i++) {
		const name = region_names[i];
		const region = policy.regions[name] ?? {};
		const display = region.display_name;
		if (type(display) == "string" && length(display) > 0) {
			regions[name] = region.flag == null ? display : `${region.flag} ${display}`;
		}
	}
	return {
		capabilities: capabilities,
		providers: provider_display_names(policy ?? {}),
		regions: regions
	};
};

function profile_display_name(profile) {
	const prefix = "subscription:";
	if (type(profile) == "string" && index(profile, prefix) == 0) {
		const section = substr(profile, length(prefix));
		const display = subscription_display_name(section);
		return display == section ? null : display;
	}
	return null;
};

function candidate_group_names(entry) {
	const result = [];
	const groups = entry?.candidate_groups ?? [];
	for (let i = 0; i < length(groups); i++) {
		if (type(groups[i]?.name) == "string") {
			push(result, groups[i].name);
		}
	}
	return result;
};

function reset_candidate_groups(secret, entry) {
	const names = candidate_group_names(entry);
	if (length(names) == 0) {
		return false;
	}
	let reset = true;
	for (let i = 0; i < length(names); i++) {
		if (!unfix_proxy(secret, names[i])) {
			reset = false;
		}
	}
	return reset;
};

function candidate_leaf_wait_seconds(policy) {
	const timeout_ms = policy?.checks?.latency?.timeout_ms;
	if (type(timeout_ms) != "int" || timeout_ms < 1) {
		return 1;
	}
	const seconds = int((timeout_ms + 999) / 1000);
	return seconds > 30 ? 30 : seconds;
};

function candidate_provider_leaves_ready(entry, proxy_state, provider_state) {
	const groups = entry?.candidate_groups ?? [];
	if (length(groups) == 0 || type(proxy_state) != "object" ||
		type(provider_state) != "object") {
		return false;
	}
	for (let i = 0; i < length(groups); i++) {
		const group = groups[i];
		const source_name = entry?.providers?.[group?.provider]?.source_name;
		if (provider_group_leaf(proxy_state, provider_state, source_name, group?.name) == null) {
			return false;
		}
	}
	return true;
};

function wait_for_candidate_provider_leaves(secret, entry, timeout_seconds) {
	let state = null;
	let provider_state = null;
	const attempts = (type(timeout_seconds) == "int" && timeout_seconds > 0 ? timeout_seconds : 1) + 1;
	for (let attempt = 0; attempt < attempts; attempt++) {
		state = proxies(secret, 1);
		provider_state = proxy_providers(secret, 1)?.providers ?? null;
		if (candidate_provider_leaves_ready(entry, state?.proxies, provider_state)) {
			break;
		}
		if (attempt < attempts - 1) {
			system("sleep 1");
		}
	}
	return { state: state, provider_state: provider_state };
};

function automatic_candidates(manifest, quotas, state, provider_state, capability, latency_round) {
	const entry = manifest?.generated_groups?.[capability];
	const result = [];
	const groups = entry?.candidate_groups ?? [];
	for (let i = 0; i < length(groups); i++) {
		const group = groups[i];
		const group_state = state?.proxies?.[group.name];
		if (group_state == null || group_state.alive == false) {
			continue;
		}
		// Mihomo owns node-level URLTest inside each provider/region group.
		// NetFleet compares only that group's current leaf once per round.
		const source_name = entry?.providers?.[group.provider]?.source_name;
		const candidate_id = provider_group_leaf(state?.proxies, provider_state,
			source_name, group.name);
		if (candidate_id == null) {
			continue;
		}
		const latency = latency_round?.results?.[group.name] ??
			{ method: "mihomo_delay", status: "unavailable", reason: "delay_test_failed" };
		const available = latency?.status == "ok";
		const candidate = {
			capability: capability,
			candidate_id: candidate_id,
			leaf_verified: true,
			provider_id: group.provider,
			region_id: group.region,
			role: group.role,
			group: group.name,
			available: available,
			quota: quotas[group.provider] ?? { state: "unknown" }
		};
		candidate.latency = latency;
		push(result, candidate);
	}
	return result;
};

function current_region(manifest_entry, state) {
	return resolve_runtime(manifest_entry, state)?.region_id ?? null;
};

function automatic_round(policy, manifest, manifest_entry, capability, secret, keep_current,
	freshness_baseline, provider_measurement_ok, preferred_region) {
	const before = freshness_baseline ?? proxies(secret);
	// Mihomo caches an empty-fallback selected during provider startup for up to
	// ten seconds. Clear each automatic leaf group through the controller before
	// the single capability delay; the delay still owns all node measurements and
	// Mihomo remains the only leaf selector.
	if (!reset_candidate_groups(secret, manifest_entry)) {
		return { ok: false, error: "candidate_group_reset_failed", candidates: [] };
	}
	let latency_round = measure_latency(secret, selection_group(manifest_entry), policy.checks);
	let measured_state = proxies(secret);
	if (measured_state == null || measured_state.proxies == null) {
		return { ok: false, error: "mihomo_state_unavailable_after_delay", candidates: [] };
	}
	let provider_state = proxy_providers(secret, 1)?.providers ?? null;
	if (!candidate_provider_leaves_ready(manifest_entry, measured_state.proxies, provider_state)) {
		const waited = wait_for_candidate_provider_leaves(secret, manifest_entry,
			candidate_leaf_wait_seconds(policy));
		if (waited.state != null && waited.state.proxies != null) {
			measured_state = waited.state;
		}
		provider_state = waited.provider_state ?? provider_state;
	}
	latency_round = complete_from_fresh_history(latency_round, before, measured_state,
		candidate_group_names(manifest_entry), policy.checks);
	const candidates = automatic_candidates(manifest, provider_quotas(policy), measured_state,
		provider_state, capability, latency_round);
	const decision = choose_automatic(candidates, policy, capability,
		keep_current ? current_region(manifest_entry, measured_state) : null, preferred_region);
	return {
		ok: decision.ok == true,
		error: decision.error,
		decision: decision,
		candidates: candidates,
		summary: provider_round_summary(manifest_entry, measured_state?.proxies, provider_state),
		latency_round: latency_round,
		provider_state_available: provider_state != null,
		provider_measurement_ok: provider_measurement_ok
	};
};

function fail_enable_after_switch(policy, original_profile, reason, details) {
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

function enable_action(policy, evidence) {
	const current = current_profile();
	if (policy.main.enabled != true) {
		fail("enable", "disabled_by_policy", null);
	}
	if (!upstream_ready()) {
		fail("enable", "upstream_unavailable", { profile: current });
	}
	const base_probes = require_protected_probes(policy, "enable");
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
	const precondition = enable_precondition(current, recovery_profile_ref, manifest);
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
	for (let i = 0; i < length(automatic_names); i++) {
		const capability = automatic_names[i];
		const entry = manifest.generated_groups[capability];
		const parent = policy.capabilities?.[capability]?.prefer_region_from;
		const preferred_region = parent == null ? null : automatic_results[parent]?.decision?.region_id;
		const result = automatic_round(policy, manifest, entry, capability, secret, false,
			enable_freshness_baseline, provider_measurement_ok, preferred_region);
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
				policy, true, false) :
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
				result.decision, activation_probes, measurement_identity(policy, manifest));
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
	ok("enable", {
		readback: readback,
		capabilities: selections,
		selected_group: sole_selection?.selected_group ?? null,
		selected_leaf: sole_selection?.selected_leaf ?? null,
		data_path: sole_selection?.data_path ?? null,
		protected_probes: activation_probes,
		base_probes: base_probes,
		evidence_recorded: evidence_recorded,
		events_recorded: events_recorded
	});
};

function disable_action(policy) {
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

function package_cleanup_action() {
	const profile = current_profile();
	if (is_active(profile)) {
		fail("package-cleanup", "netfleet_profile_active", { profile: profile });
	}
	const policy = load_policy();
	const manifest = read_json(MANIFEST_PATH);
	const policy_links_removed = policy == null || remove_provider_links(policy_provider_profiles(policy));
	const manifest_links_removed = manifest == null || remove_provider_links(manifest_provider_profiles(manifest));
	if (!policy_links_removed || !manifest_links_removed) {
		fail("package-cleanup", "provider_link_cleanup_failed", null);
	}
	if (!remove_artifact()) {
		fail("package-cleanup", "artifact_cleanup_failed", null);
	}
	ok("package-cleanup", { profile: profile, artifact_removed: true });
};

function public_candidates(candidates) {
	const result = [];
	for (let i = 0; i < length(candidates) && i < 256; i++) {
		const candidate = candidates[i];
		push(result, {
			candidate_id: candidate.candidate_id,
			provider_id: candidate.provider_id,
			region_id: candidate.region_id,
			group: candidate.group,
			available: candidate.available,
			latency: candidate.latency,
			quota: candidate.quota?.state == "available" ?
				{ state: "available", remaining_bytes: candidate.quota.remaining_bytes ?? null } :
				{ state: candidate.quota?.state ?? "unknown" }
		});
	}
	return result;
};

function status_action(policy, evidence) {
	const profile = current_profile();
	const manifest = read_json(MANIFEST_PATH);
	const secret = api_secret();
	const state = secret ? proxies(secret, 1) : null;
	if (state != null) {
		state.providers = proxy_providers(secret, 1)?.providers ?? null;
	}
	const enabled = nikki_enabled();
	const mihomo_running = running();
	let cleanup = null;
	if (enabled == false || !mihomo_running) {
		try {
			cleanup = cleanup_state();
		} catch (error) {
			cleanup = { ok: false, error: "cleanup_readback_error" };
		}
	}
	ok("status", build_status(policy, manifest, state, evidence, {
		build: installed_build(),
		active: is_active(profile),
		profile: profile,
		profile_display_name: profile_display_name(profile),
		recovery_profile_display_name: profile_display_name(policy.recovery_profile.ref),
		netfleet_present: state_has_netfleet(state, manifest, profile),
		nikki_enabled: enabled,
		mihomo_running: mihomo_running,
		lan_runtime: mihomo_running ? lan_runtime_state(guard_probe_url(policy)) : null,
		cleanup: cleanup,
		quotas: provider_quotas(policy),
		provider_names: provider_display_names(policy),
		automation: automation_config(policy),
		subscription_refresh: subscription_refresh_projection(policy),
		supervisor: service_state()
	}));
};

function events_action() {
	const store = read_events();
	const validation = validate_events(store);
	const manifest = read_json(MANIFEST_PATH);
	const policy = load_policy();
	ok("events", {
		events: validation.ok ? store?.events ?? [] : [],
		store_valid: validation.ok,
		store_error: validation.ok ? null : validation.error,
		display_names: event_display_names(policy),
		nikki_lines: nikki_netfleet_lines(expected_runtime_groups(manifest)),
		nikki_lines_persistent: false
	});
};

function connections_action() {
	const secret = api_secret();
	const result = secret ? current_connections(secret, 3) : null;
	if (result == null) fail("connections", "mihomo_connections_unavailable", null);
	ok("connections", result);
};

function automatic_mode_active(manifest, capability_names, state) {
	for (let i = 0; i < length(capability_names); i++) {
		const entry = manifest?.generated_groups?.[capability_names[i]];
		if (entry?.automatic_name == null || state?.proxies?.[entry?.name]?.now != entry.automatic_name) {
			return false;
		}
	}
	return length(capability_names) > 0;
};

function restore_runtime_selections(secret, manifest, before_groups, policy) {
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

function capture_runtime_selections(manifest) {
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

function prepare_refresh_snapshot(policy, active) {
	if (system(`rm -rf ${shell_quote(REFRESH_DIR)}`) != 0 ||
		system(`mkdir -p ${shell_quote(`${REFRESH_DIR}/subscriptions`)}`) != 0) {
		return { ok: false, error: "snapshot_directory_failed" };
	}
	const entries = [];
	const sections = enabled_subscription_sections(policy);
	for (let i = 0; i < length(sections); i++) {
		const path = resolve_profile(`subscription:${sections[i]}`);
		const backup = `${REFRESH_DIR}/subscriptions/${sections[i]}.yaml`;
		const digest = path == null ? null : sha256(path);
		if (path == null || digest == null ||
			system(`cp -p ${shell_quote(path)} ${shell_quote(backup)}`) != 0 || sha256(backup) != digest) {
			return { ok: false, error: "subscription_snapshot_failed", section: sections[i] };
		}
		push(entries, { section: sections[i], path: path, backup: backup, digest: digest });
	}
	let manifest = null;
	if (active == true) {
		manifest = read_json(MANIFEST_PATH);
		if (manifest == null || sha256(ARTIFACT_PATH) == null || sha256(MANIFEST_PATH) == null ||
			system(`cp -p ${shell_quote(ARTIFACT_PATH)} ${shell_quote(`${REFRESH_DIR}/artifact.json`)}`) != 0 ||
			system(`cp -p ${shell_quote(MANIFEST_PATH)} ${shell_quote(`${REFRESH_DIR}/manifest.json`)}`) != 0) {
			return { ok: false, error: "runtime_snapshot_failed" };
		}
	}
	return { ok: true, active: active == true, entries: entries, manifest: manifest };
};

function restore_refresh_entry(entry) {
	return system(`cp -p ${shell_quote(entry.backup)} ${shell_quote(entry.path)}`) == 0 &&
		sha256(entry.path) == entry.digest;
};

function restore_refresh_files(snapshot) {
	let restored = true;
	for (let i = 0; i < length(snapshot?.entries ?? []); i++) {
		if (!restore_refresh_entry(snapshot.entries[i])) restored = false;
	}
	if (snapshot?.active == true) {
		if (system(`cp -p ${shell_quote(`${REFRESH_DIR}/artifact.json`)} ${shell_quote(ARTIFACT_PATH)}`) != 0 ||
			system(`cp -p ${shell_quote(`${REFRESH_DIR}/manifest.json`)} ${shell_quote(MANIFEST_PATH)}`) != 0 ||
			sha256(ARTIFACT_PATH) != sha256(`${REFRESH_DIR}/artifact.json`) ||
			sha256(MANIFEST_PATH) != sha256(`${REFRESH_DIR}/manifest.json`)) {
			restored = false;
		}
	}
	return restored;
};

function cleanup_refresh_snapshot() {
	system(`rm -rf ${shell_quote(REFRESH_DIR)}`);
};

function wait_active_runtime(manifest) {
	let readback = null;
	for (let attempt = 0; attempt < 12; attempt++) {
		readback = runtime_readback(COMPILED_PROFILE, manifest);
		if (readback.mihomo_running && readback.mihomo_config_valid &&
			readback.state_available && readback.runtime_identity_ok) {
			return { ok: true, readback: readback };
		}
		if (attempt < 11) system("sleep 1");
	}
	return { ok: false, error: "owner_readback_failed", readback: readback };
};

function run_refresh_selection(requested) {
	const trigger = requested == "scheduled" ? "scheduled" : "refresh";
	const initiator = event_initiator(requested, requested == "scheduled" ? "scheduled" : null);
	const output = `${REFRESH_DIR}/selection.json`;
	const error_output = `${REFRESH_DIR}/selection.stderr`;
	const exit_code = system(`ucode ${shell_quote(MAIN_PATH)} maintain ${shell_quote(trigger)} ${shell_quote(initiator)} >${shell_quote(output)} 2>${shell_quote(error_output)}`);
	const response = read_json(output);
	return {
		ok: exit_code == 0 && response?.ok == true,
		state: response?.result?.state ?? null,
		error: response?.error ?? (exit_code == 0 ? "selection_readback_failed" : "selection_failed")
	};
};

function rollback_refresh(snapshot, policy, selections) {
	if (!restore_refresh_files(snapshot)) {
		return { ok: false, error: "snapshot_restore_failed" };
	}
	if (snapshot.active != true) {
		return { ok: true, state: "cache_restored" };
	}
	if ((nikki_enabled() != true && !set_nikki_enabled(true)) ||
		!set_profile(COMPILED_PROFILE) || !restart()) {
		return { ok: false, error: "runtime_restart_failed" };
	}
	const runtime = wait_active_runtime(snapshot.manifest);
	const secret = api_secret();
	if (!runtime.ok || !secret || !restore_runtime_selections(secret, snapshot.manifest, selections, policy)) {
		return { ok: false, error: runtime.error ?? "runtime_selection_restore_failed", readback: runtime.readback };
	}
	return { ok: true, state: "runtime_restored", readback: runtime.readback };
};

function fail_refresh(snapshot, policy, selections, requested, error, detail) {
	const rollback = rollback_refresh(snapshot, policy, selections);
	const event = {
		ok: false,
		reason: rollback.ok ? "rollback_restored" : "rollback_failed",
		provider_count: length(snapshot?.entries ?? []),
		changed_count: detail?.changed_count ?? 0,
		failed_count: detail?.failed_count ?? 0,
		reloaded: false,
		subscriptions: detail?.subscriptions ?? []
	};
	const events_recorded = record_events([refresh_event(event, requested)]);
	cleanup_refresh_snapshot();
	if (!rollback.ok) {
		const recovery = restore_recovery_with_probes(policy, "subscription_refresh_rollback_failed");
		fail("refresh", "rollback_failed", {
			error: error,
			rollback: rollback,
			recovery: recovery,
			events_recorded: events_recorded
		});
	}
	fail("refresh", error, { detail: detail, rollback: rollback, events_recorded: events_recorded });
};

function refresh_action(policy) {
	const requested = ARGV[1] ?? "cli";
	const config = automation_config(policy);
	if (requested == "scheduled" && config.subscription_refresh_enabled != true) {
		ok("refresh", { state: "disabled" });
		return;
	}
	const sections = enabled_subscription_sections(policy);
	if (length(sections) == 0) {
		ok("refresh", { state: "no_enabled_providers", provider_count: 0 });
		return;
	}
	if (!upstream_ready()) {
		const result = { ok: false, reason: "upstream_unavailable", provider_count: length(sections),
			changed_count: 0, failed_count: length(sections), reloaded: false,
			subscriptions: unavailable_results(sections) };
		result.events_recorded = record_events([refresh_event(result, requested)]);
		ok("refresh", { state: "failed", result: result });
		return;
	}
	const active = is_active(current_profile());
	let selections = {};
	if (active) {
		const manifest = read_json(MANIFEST_PATH);
		const runtime = manifest == null ? null : runtime_readback(COMPILED_PROFILE, manifest);
		const captured = manifest == null ? { ok: false, error: "staged_manifest_missing" } :
			capture_runtime_selections(manifest);
		const baseline = protected_probes(policy);
		if (runtime == null || !runtime.runtime_identity_ok || !captured.ok || !baseline.ok) {
			const result = { ok: false, reason: "active_precondition_failed", provider_count: length(sections),
				changed_count: 0, failed_count: 0, reloaded: false,
				subscriptions: unavailable_results(sections) };
			result.events_recorded = record_events([refresh_event(result, requested)]);
			ok("refresh", { state: "skipped", result: result });
			return;
		}
		selections = captured.selections;
	}
	const snapshot = prepare_refresh_snapshot(policy, active);
	if (!snapshot.ok) {
		cleanup_refresh_snapshot();
		fail("refresh", snapshot.error, { section: snapshot.section ?? null });
	}
	const outcomes = [];
	for (let i = 0; i < length(snapshot.entries); i++) {
		const entry = snapshot.entries[i];
		const updated = update_subscription(entry.section);
		const digest = updated ? sha256(entry.path) : null;
		const outcome = evaluate_entry({
			section: entry.section,
			updated: updated,
			previous_digest: entry.digest,
			digest: digest,
			parsed: digest == null ? null : read_yaml(entry.path)
		});
		if (outcome.restore && !restore_refresh_entry(entry)) {
			push(outcomes, outcome);
			const failed = summarize_refresh(outcomes);
			fail_refresh(snapshot, policy, selections, requested, "subscription_cache_restore_failed", {
				changed_count: failed.changed_count,
				failed_count: failed.failed_count,
				subscriptions: public_subscription_results(outcomes)
			});
		}
		push(outcomes, outcome);
	}
	const summary = summarize_refresh(outcomes);
	const subscriptions = public_subscription_results(outcomes);
	if (summary.changed_count == 0) {
		const result = {
			ok: summary.ok,
			reason: summary.cache_reason,
			provider_count: summary.provider_count,
			changed_count: 0,
			failed_count: summary.failed_count,
			reloaded: false,
			subscriptions: subscriptions
		};
		cleanup_refresh_snapshot();
		result.events_recorded = record_events([refresh_event(result, requested)]);
		ok("refresh", { state: result.reason, result: result });
		return;
	}
	if (!active) {
		const result = {
			ok: summary.ok,
			reason: summary.cache_reason,
			provider_count: summary.provider_count,
			changed_count: summary.changed_count,
			failed_count: summary.failed_count,
			reloaded: false,
			subscriptions: subscriptions
		};
		cleanup_refresh_snapshot();
		result.events_recorded = record_events([refresh_event(result, requested)]);
		ok("refresh", { state: result.reason, result: result });
		return;
	}
	const compiled = compile_result(policy, true);
	if (!compiled.ok) {
		fail_refresh(snapshot, policy, selections, requested, compiled.error, {
			compile_detail: compiled.detail, changed_count: summary.changed_count,
			failed_count: summary.failed_count, subscriptions: subscriptions
		});
	}
	const manifest = read_json(MANIFEST_PATH);
	if (manifest == null || !restart()) {
		fail_refresh(snapshot, policy, selections, requested, "runtime_restart_failed", {
			changed_count: summary.changed_count, failed_count: summary.failed_count,
			subscriptions: subscriptions
		});
	}
	const runtime = wait_active_runtime(manifest);
	const secret = api_secret();
	if (!runtime.ok || !secret || !restore_runtime_selections(secret, manifest, selections, policy)) {
		fail_refresh(snapshot, policy, selections, requested, runtime.error ?? "runtime_selection_restore_failed", {
			changed_count: summary.changed_count, failed_count: summary.failed_count,
			subscriptions: subscriptions
		});
	}
	const selection = run_refresh_selection(requested);
	const final_readback = runtime_readback(COMPILED_PROFILE, manifest);
	const final_probes = protected_probes(policy);
	if (!selection.ok || !final_readback.runtime_identity_ok || !final_probes.ok) {
		fail_refresh(snapshot, policy, selections, requested,
			!selection.ok ? selection.error : !final_readback.runtime_identity_ok ? "owner_readback_failed" : "protected_probe_failed", {
				changed_count: summary.changed_count, failed_count: summary.failed_count,
				selection: selection, subscriptions: subscriptions
			});
	}
	const result = {
		ok: summary.ok,
		reason: summary.active_reason,
		provider_count: summary.provider_count,
		changed_count: summary.changed_count,
		failed_count: summary.failed_count,
		reloaded: true,
		selection_state: selection.state,
		subscriptions: subscriptions
	};
	cleanup_refresh_snapshot();
	result.events_recorded = record_events([refresh_event(result, requested)]);
	ok("refresh", { state: result.reason, result: result, readback: final_readback,
		protected_probes: final_probes });
};

function automatic_select_action(policy, capability, evidence, trigger, initiator) {
	const current = current_profile();
	if (!is_active(current)) fail("select", "profile_not_active", current);
	const manifest = load_manifest();
	const automatic_names = automatic_capability_order(policy, manifest);
	if (length(automatic_names) == 0 || capability != automatic_names[0]) {
		fail("select", "automatic_root_required", automatic_names[0] ?? null);
	}
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
	const results = {};
	for (let i = 0; i < length(automatic_names); i++) {
		const name = automatic_names[i];
		const parent = policy.capabilities?.[name]?.prefer_region_from;
		const preferred_region = parent == null ? null : results[parent]?.decision?.region_id;
		const result = automatic_round(policy, manifest, manifest.generated_groups[name], name, secret,
			baseline_probes.ok, state, provider_measurement_ok, preferred_region);
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
		const activation = activate_preferred_choice(secret, manifest.generated_groups[name],
			result.decision.group, policy, false, false);
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
			result.decision, activation_probes, measurement_identity(policy, manifest));
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

function select_action(policy, evidence) {
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
	if (choice == "auto") {
		automatic_select_action(policy, capability, evidence, "manual", ARGV[3]);
		return;
	}
	const manifest = load_manifest();
	const allowed = manual_member(manifest, capability, choice);
	if (!allowed.ok) {
		fail("select", allowed.error, null);
	}
	const secret = api_secret();
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

function maintain_action(policy, evidence) {
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
	automatic_select_action(policy, root, evidence, ARGV[1] ?? "scheduled", ARGV[2] ?? "supervisor");
};

function recover_action(policy) {
	const reason = ARGV[1] ?? "runtime_unavailable";
	const before = current_profile();
	const manifest = read_json(MANIFEST_PATH);
	const state = api_secret() ? proxies(api_secret(), 1) : null;
	if (!is_active(before) && !state_has_netfleet(state, manifest, before)) {
		ok("recover", { state: "unchanged", profile: before, reason: reason });
		return;
	}
	if (reason == "lan_ingress_unavailable" || reason == "dns_ingress_unavailable") {
		// Recovery Profiles inherit Nikki's global LAN/listener platform values.
		// Switching Profile cannot repair this failure and would preserve the same
		// black hole, so ask Nikki to remove interception and persist passthrough.
		const passthrough = enter_passthrough(policy, reason, true);
		if (!passthrough.ok) fail("recover", "fail_open_recovery_failed", passthrough);
		ok("recover", passthrough);
		return;
	}
	const recovery = restore_recovery_with_probes(policy, reason);
	if (!recovery.ok) fail("recover", "fail_open_recovery_failed", recovery);
	ok("recover", recovery);
};

function guarded_mutation(action, policy, callback) {
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

function disable_without_policy(action_name) {
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
	const disabled = set_nikki_enabled(false);
	const stop_result = stop_nikki();
	const cleanup = stop_result?.readback ?? cleanup_state();
	const persistent = recovery_valid && profile_set && current_profile() == recovery &&
		disabled == true && nikki_enabled() == false;
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
		nikki_disabled: disabled,
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

const action = ARGV[0] ?? "";
if (index(["native-sources-get", "native-sources-set", "native-sources-refresh"], action) >= 0) {
	native_sources(action, ARGV[1]);
	exit(0);
}
if (action == "events") {
	events_action();
	exit(0);
}
if (action == "connections") {
	connections_action();
	exit(0);
}
if (action == "onboarding-get") {
	onboarding_get(load_policy());
	exit(0);
}
if (action == "onboarding-apply") {
	onboarding_apply(ARGV[1]);
	exit(0);
}
if (action == "package-cleanup") {
	package_cleanup_action();
	exit(0);
}
const policy_path = action == "validate" || action == "validate-schema" ? (ARGV[1] ?? POLICY_PATH) : POLICY_PATH;
const policy = load_policy(policy_path);
if (policy == null) {
	if (action == "disable" || action == "recover") {
		disable_without_policy(action);
		exit(0);
	}
	fail(action || "load", "policy_unreadable", policy_path);
}
const evidence = load_evidence();

if (action == "status") {
	status_action(policy, evidence);
} else if (action == "config-get") {
	config_get(policy);
} else if (action == "config-validate") {
	config_validate(policy, ARGV[1]);
} else if (action == "config-save") {
	config_save(policy, ARGV[1]);
} else if (action == "config-apply") {
	config_apply(policy, ARGV[1]);
} else if (action == "probe") {
	const result = protected_probes_after_restart(policy);
	if (!result.ok) {
		fail("probe", result.error, result);
	}
	ok("probe", result);
} else if (action == "validate-schema") {
	ok("validate-schema", { policy_schema: policy.schema_version });
} else if (action == "validate") {
	const source_path = resolve_policy_source(policy.policy_source);
	if (source_path == null || system(`test -f ${shell_quote(source_path)}`) != 0) {
		fail("validate", "policy_source_missing", policy.policy_source.ref);
	}
	const baseline = load_policy_source(policy.policy_source);
	const recovery_path = resolve_profile(policy.recovery_profile.ref);
	if (recovery_path == null || system(`test -f ${shell_quote(recovery_path)}`) != 0) {
		fail("validate", "recovery_profile_missing", policy.recovery_profile.ref);
	}
	const provider_profiles = require_provider_profiles(policy, "validate");
	const result = compile_profile(baseline, policy, sha256(source_path), sha256(recovery_path),
		sha256(policy_path), provider_profiles);
	if (!result.ok) {
		fail("validate", "compile_rejected", result.errors);
	}
	ok("validate", { current_profile: current_profile(), policy_source: policy.policy_source,
		recovery_profile: policy.recovery_profile.ref, would_generate: true });
} else if (action == "compile") {
	compile_action(policy);
} else if (action == "prepare-recovery") {
	guarded_mutation("prepare-recovery", policy, () => prepare_recovery_action(policy));
} else if (action == "restore-recovery") {
	guarded_mutation("restore-recovery", policy, () => restore_recovery_action(policy));
} else if (action == "enable") {
	guarded_mutation("enable", policy, () => enable_action(policy, evidence));
} else if (action == "disable") {
	guarded_mutation("disable", policy, () => disable_action(policy));
} else if (action == "select") {
	guarded_mutation("select", policy, () => select_action(policy, evidence));
} else if (action == "maintain") {
	guarded_mutation("maintain", policy, () => maintain_action(policy, evidence));
} else if (action == "refresh") {
	refresh_action(policy);
} else if (action == "recover") {
	guarded_mutation("recover", policy, () => recover_action(policy));
} else {
	fail("usage", "unknown_action", "onboarding-get|onboarding-apply|package-cleanup|status|events|connections|probe|validate-schema|validate|compile|enable|disable|select|refresh|maintain|recover");
};
