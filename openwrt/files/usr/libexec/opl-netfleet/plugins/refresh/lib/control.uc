

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let prepare_refresh_snapshot, restore_refresh_entry, restore_refresh_files, cleanup_refresh_snapshot, wait_active_runtime, run_refresh_selection, reload_refresh_profile, rollback_refresh, fail_refresh, refresh_action, command_refresh, command_subscriptions_refresh;

const ARGV = context.argv ?? [];
const compile_result = context.use("compilation.control").compile_result;
const operation_update = context.use("events.operation").update;
const operation_begin = context.use("events.operation").begin;
const fail = context.use("events.output").fail;
const ok = context.use("events.output").ok;
const event_initiator = context.use("events.record").event_initiator;
const record_events = context.use("events.record").record_events;
const refresh_event = context.use("events.record").refresh_event;
const resolve_profile = context.use("mihomo.backend").resolve_profile;
const MANIFEST_PATH = context.use("mihomo.backend").MANIFEST_PATH;
const ARTIFACT_PATH = context.use("mihomo.backend").ARTIFACT_PATH;
const running = context.use("mihomo.backend").running;
const COMPILED_PROFILE = context.use("mihomo.backend").COMPILED_PROFILE;
const lan_runtime_state = context.use("mihomo.backend").lan_runtime_state;
const restart = context.use("mihomo.backend").restart;
const stop_backend = context.use("mihomo.backend").stop;
const cleanup_state = context.use("mihomo.backend").cleanup_state;
const update_subscription = context.use("mihomo.backend").update_subscription;
const protected_probes = context.use("mihomo.controller").protected_probes;
const restore_runtime_selections = context.use("mihomo.paths").restore_runtime_selections;
const capture_runtime_selections = context.use("mihomo.paths").capture_runtime_selections;
const runtime_readback = context.use("mihomo.readback").runtime_readback;
const is_active = context.use("models.activation").is_active;
const guard_probe_url = context.use("models.policy").guard_probe_url;
const automation_config = context.use("models.policy").automation;
const referenced_subscription_sections = context.use("models.subscription").referenced_sections;
const enabled_subscription_sections = context.use("models.subscription").enabled_sections;
const unavailable_results = context.use("models.subscription").unavailable_results;
const evaluate_entry = context.use("models.subscription").evaluate_entry;
const summarize_refresh = context.use("models.subscription").summarize;
const public_subscription_results = context.use("models.subscription").public_results;
const load_policy = context.use("platform.documents").load_policy;
const BACKEND_KIND = context.use("platform.runtime").KIND;
const shell_quote = context.use("platform.process").shell_quote;
const sha256 = context.use("platform.storage").sha256;
const read_json = context.use("platform.storage").read_json;
const current_profile = context.use("platform.profile").current_profile;
const backend_enabled = context.use("platform.profile").backend_enabled;
const set_backend_enabled = context.use("platform.profile").set_backend_enabled;
const set_profile = context.use("platform.profile").set_profile;
const api_secret = context.use("platform.credentials").api_secret;
const upstream_ready = context.use("platform.device").upstream_ready;
const subscription_display_name = context.use("platform.subscriptions").subscription_display_name;
const read_yaml = context.use("platform.storage").read_yaml;
const POLICY_PATH = context.use("platform.paths").POLICY_PATH;
const restore_profile = context.use("recovery.control").restore_profile;
const restore_recovery_with_probes = context.use("recovery.control").restore_recovery_with_probes;
const subscription_update = context.use("subscriptions.store").update_result;

const MAIN_PATH = "/usr/libexec/opl-netfleet/main.uc";
const REFRESH_DIR = "/tmp/opl-netfleet-subscription-refresh";
prepare_refresh_snapshot = function(policy, active, sections) {
	if (system(`rm -rf ${shell_quote(REFRESH_DIR)}`) != 0 ||
		system(`mkdir -p ${shell_quote(`${REFRESH_DIR}/subscriptions`)}`) != 0) {
		return { ok: false, error: "snapshot_directory_failed" };
	}
	const entries = [];
	let backend_config = null;
	if (BACKEND_KIND == "native-mihomo") {
		const path = "/etc/config/netfleet";
		const backup = `${REFRESH_DIR}/netfleet`;
		const digest = sha256(path);
		if (digest == null || system(`cp -p ${shell_quote(path)} ${shell_quote(backup)}`) != 0 || sha256(backup) != digest)
			return { ok: false, error: "backend_config_snapshot_failed" };
		backend_config = { path: path, backup: backup, digest: digest };
	}
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
	const native_running = BACKEND_KIND == "native-mihomo" && !active && running();
	return { ok: true, active: active == true, entries: entries, manifest: manifest, backend_config: backend_config,
		profile: current_profile(), native_running: native_running,
		protected_baseline: native_running && policy != null ? protected_probes(policy).ok : false };
};

restore_refresh_entry = function(entry) {
	return system(`cp -p ${shell_quote(entry.backup)} ${shell_quote(entry.path)}`) == 0 &&
		sha256(entry.path) == entry.digest;
};

restore_refresh_files = function(snapshot) {
	let restored = true;
	if (snapshot?.backend_config != null && !restore_refresh_entry(snapshot.backend_config)) restored = false;
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

cleanup_refresh_snapshot = function() {
	system(`rm -rf ${shell_quote(REFRESH_DIR)}`);
};

wait_active_runtime = function(manifest) {
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

run_refresh_selection = function(requested, parent_id) {
	const trigger = requested == "scheduled" ? "scheduled" : "refresh";
	const initiator = event_initiator(requested, requested == "scheduled" ? "scheduled" : null);
	const output = `${REFRESH_DIR}/selection.json`;
	const error_output = `${REFRESH_DIR}/selection.stderr`;
	const exit_code = system(`ucode ${shell_quote(MAIN_PATH)} maintain ${shell_quote(trigger)} ${shell_quote(initiator)} ${shell_quote(parent_id ?? "")} >${shell_quote(output)} 2>${shell_quote(error_output)}`);
	const response = read_json(output);
	return {
		ok: exit_code == 0 && response?.ok == true,
		state: response?.result?.state ?? null,
		error: response?.error ?? (exit_code == 0 ? "selection_readback_failed" : "selection_failed")
	};
};

reload_refresh_profile = function(snapshot, policy, rolling_back) {
	if (!rolling_back) operation_update("reloading", { subject: null });
	if (!restore_profile(snapshot.profile, null)) return { ok: false, error: "runtime_restart_failed" };
	if (!rolling_back) operation_update("verifying");
	const readback = runtime_readback(snapshot.profile, null);
	const lan = lan_runtime_state(guard_probe_url(policy));
	const probes = policy == null ? null : protected_probes(policy);
	return { ok: readback.runtime_identity_ok && lan.transparent_proxy_ready && lan.dns_ready &&
		(snapshot.protected_baseline != true || probes?.ok == true),
		error: "owner_readback_failed", readback: readback, lan_runtime: lan, protected_probes: probes };
};

rollback_refresh = function(snapshot, policy, selections) {
	if (!restore_refresh_files(snapshot)) {
		return { ok: false, error: "snapshot_restore_failed" };
	}
	if (snapshot.active != true) {
		if (snapshot.native_running == true) {
			const restored = reload_refresh_profile(snapshot, policy, true);
			restored.state = restored.ok ? "runtime_restored" : "runtime_restore_failed";
			return restored;
		}
		return { ok: true, state: "cache_restored" };
	}
	if ((backend_enabled() != true && !set_backend_enabled(true)) ||
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

fail_refresh = function(snapshot, policy, selections, requested, error, detail) {
	operation_update("rolling_back", { subject: null });
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
		let recovery;
		if (policy != null) recovery = restore_recovery_with_probes(policy, "subscription_refresh_rollback_failed");
		else {
			const disabled = set_backend_enabled(false);
			const stopped = stop_backend();
			const cleanup = cleanup_state();
			recovery = { ok: disabled && stopped && cleanup.ok, mode: "direct", cleanup: cleanup };
		}
		fail("refresh", "rollback_failed", {
			error: error,
			rollback: rollback,
			recovery: recovery,
			events_recorded: events_recorded
		});
	}
	fail("refresh", error, { detail: detail, rollback: rollback, events_recorded: events_recorded });
};

refresh_action = function(policy, section, initiator) {
	operation_begin("subscription", "preparing");
	const requested = initiator ?? ARGV[1] ?? "cli";
	const config = automation_config(policy);
	if (requested == "scheduled" && config.subscription_refresh_enabled != true) {
		ok("refresh", { state: "disabled" });
		return;
	}
	const sections = section != null ? [section] : BACKEND_KIND == "native-mihomo" ?
		referenced_subscription_sections(policy, current_profile()) : enabled_subscription_sections(policy);
	operation_update("preparing", { total: length(sections) });
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
	const active = is_active(current_profile()) && running();
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
	const snapshot = prepare_refresh_snapshot(policy, active, sections);
	if (!snapshot.ok) {
		cleanup_refresh_snapshot();
		fail("refresh", snapshot.error, { section: snapshot.section ?? null });
	}
	const outcomes = [];
	for (let i = 0; i < length(snapshot.entries); i++) {
		const entry = snapshot.entries[i];
		const subject = subscription_display_name(entry.section);
		operation_update("downloading", { completed: i, subject: subject });
		const updated = update_subscription(entry.section);
		operation_update("validating", { completed: i, subject: subject });
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
		operation_update("validating", { completed: i + 1, subject: subject });
	}
	operation_update("validating", { subject: null });
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
		const reloaded = snapshot.native_running == true ? reload_refresh_profile(snapshot, policy) : null;
		if (reloaded != null && !reloaded.ok) {
			fail_refresh(snapshot, policy, selections, requested, reloaded.error, {
				changed_count: summary.changed_count, failed_count: summary.failed_count,
				subscriptions: subscriptions, runtime: reloaded
			});
		}
		const result = {
			ok: summary.ok,
			reason: reloaded != null ? summary.active_reason : summary.cache_reason,
			provider_count: summary.provider_count,
			changed_count: summary.changed_count,
			failed_count: summary.failed_count,
			reloaded: reloaded != null,
			subscriptions: subscriptions
		};
		cleanup_refresh_snapshot();
		result.events_recorded = record_events([refresh_event(result, requested)]);
		ok("refresh", { state: result.reason, result: result, readback: reloaded?.readback ?? null,
			protected_probes: reloaded?.protected_probes ?? null });
		return;
	}
	operation_update("compiling");
	const compiled = compile_result(policy, true);
	if (!compiled.ok) {
		fail_refresh(snapshot, policy, selections, requested, compiled.error, {
			compile_detail: compiled.detail, changed_count: summary.changed_count,
			failed_count: summary.failed_count, subscriptions: subscriptions
		});
	}
	const manifest = read_json(MANIFEST_PATH);
	operation_update("reloading");
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
	const operation = operation_update("selecting");
	const selection = run_refresh_selection(requested, operation?.id);
	operation_update("verifying");
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

command_refresh = function(argv) {
	const policy = load_policy();
	if (policy == null) fail(argv[0], "policy_unreadable", POLICY_PATH);
	refresh_action(policy);
};

command_subscriptions_refresh = function(argv) {
	const action = argv[0];
	const id = ARGV[1];
	if (BACKEND_KIND != "native-mihomo" || type(id) != "string" || !match(id, /^[A-Za-z0-9_]+$/))
		fail(action, "invalid_native_subscription");
	const policy = load_policy();
	if (index(referenced_subscription_sections(policy, current_profile()), id) >= 0) {
		refresh_action(policy, id, ARGV[2] ?? "cli");
	} else {
		operation_begin("subscription", "downloading", { total: 1, subject: subscription_display_name(id) });
		const result = subscription_update(id);
		if (!result.ok) fail(action, result.error);
		operation_update("validating", { completed: 1 });
		ok(action, { updated: true, changed: result.changed });
	}
};

return { prepare_refresh_snapshot, restore_refresh_entry, restore_refresh_files, cleanup_refresh_snapshot, wait_active_runtime, run_refresh_selection, reload_refresh_profile, rollback_refresh, fail_refresh, refresh_action, command_refresh, command_subscriptions_refresh };
};
