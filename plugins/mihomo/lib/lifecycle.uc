import * as fs from "fs";

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let failure, saved_state, directory, observer_stopped, owns_backend, external_unchanged, resume_failed, drain, resume;

const runtime = context.use("platform.runtime");
const storage = context.use("platform.storage");
const profile = context.use("platform.profile");
const credentials = context.use("platform.credentials");
const files = context.use("platform.files");
const supervisor = context.use("platform.service");
const backend = context.use("mihomo.backend");
const readback = context.use("mihomo.readback").runtime_readback;
const paths = context.use("mihomo.paths");
const is_active = context.use("models.activation").is_active;
const load_policy = context.use("platform.documents").load_policy;

const ROOT = "/var/run/opl-netfleet-mihomo-handoff";
const SAVED = `${ROOT}/state.json`;

failure = function(error, result) { return { ok: false, error: error, result: result }; };
saved_state = function() { return files.private_file(SAVED) ? storage.read_json(SAVED) : null; };
directory = function() { return fs.lstat(ROOT) == null ? fs.mkdir(ROOT, 0700) : files.private_directory(ROOT); };
observer_stopped = function() {
	const process = fs.popen(`ubus call service list '${sprintf("%J", { name: runtime.SERVICE })}' 2>/dev/null`);
	let services = null;
	try { services = process == null ? null : json(process.read("all")); } catch (error) {}
	if (process == null || process.close() != 0 || type(services) != "object") return false;
	for (let instance in values(services?.[runtime.SERVICE]?.instances ?? {}))
		if (instance.running == true) return false;
	return true;
};

owns_backend = function(before) { return before.backend == "native-mihomo" || before.active == true; };
external_unchanged = function(before) {
	if (backend.running() != before.running) return false;
	if (!before.running) return true;
	const state = readback(before.profile, storage.read_json(backend.MANIFEST_PATH));
	return state.mihomo_running && state.mihomo_config_valid && state.state_available && state.runtime_identity_ok;
};

resume_failed = function(error) {
	system(`/etc/init.d/${runtime.SERVICE} stop >/dev/null 2>&1`);
	const cleanup = backend.stop();
	return failure(cleanup.ok && observer_stopped() ? error : "handoff_rollback_cleanup_failed",
		{ cause: error, cleanup: cleanup, saved: saved_state() });
};

drain = function(params) {
	if (!directory()) return failure("handoff_directory_unsafe");
	let before = saved_state();
	if (fs.lstat(SAVED) != null && before == null) return failure("handoff_state_unreadable");
	if (before == null) {
		const current = profile.current_profile();
		const active = is_active(current);
		const running = backend.running();
		const manifest = storage.read_json(backend.MANIFEST_PATH);
		const selections = running && active ? paths.capture_runtime_selections(manifest) : null;
		if (running && active && selections?.ok != true) return failure("handoff_selection_unavailable");
		before = { schema: 1, backend: runtime.KIND, profile: current, enabled: profile.backend_enabled(),
			running: running, active: active, supervisor: supervisor.service_state(), selections: selections?.selections ?? null };
		// Save before stopping owners so retries retain the original resume intent.
		if (!files.atomic_json(SAVED, before)) return failure("handoff_state_write_failed");
	}
	if (before.schema != 1 || before.backend != runtime.KIND) return failure("handoff_state_incompatible");
	if (before.supervisor?.installed == true &&
		!supervisor.set_service_state({ ...before.supervisor, running: false }).ok)
		return failure("handoff_supervisor_stop_failed", before);
	if (!owns_backend(before))
		return external_unchanged(before) ? { ok: true, result: before } : failure("handoff_external_owner_changed", before);
	// The observer can outlive a stopped core. Stop the whole owner service.
	system(`/etc/init.d/${runtime.SERVICE} stop >/dev/null 2>&1`);
	let cleanup = null;
	let stopped = false;
	for (let attempt = 0; attempt < 10; attempt++) {
		cleanup = backend.cleanup_state();
		stopped = cleanup?.ok == true && observer_stopped();
		if (stopped) break;
		if (attempt < 9) sleep(1000);
	}
	if (!stopped) return failure("handoff_owner_cleanup_unconfirmed", { saved: before, cleanup: cleanup });
	return { ok: true, result: before };
};

resume = function(saved) {
	const before = saved_state();
	if (before == null || before.schema != 1 || before.backend != runtime.KIND ||
		(type(saved) == "object" && sprintf("%J", saved) != sprintf("%J", before)))
		return failure("handoff_state_incompatible");
	if (profile.current_profile() != before.profile || profile.backend_enabled() != before.enabled)
		return failure("handoff_configuration_changed");
	if (!owns_backend(before)) {
		if (!external_unchanged(before)) return failure("handoff_external_owner_changed", before);
	} else if (before.running == true) {
		if (!backend.restart()) return resume_failed("handoff_owner_restart_failed");
		const manifest = storage.read_json(backend.MANIFEST_PATH);
		let ready = false;
		for (let attempt = 0; attempt < 30; attempt++) {
			const state = readback(before.profile, manifest);
			ready = state.mihomo_running && state.mihomo_config_valid && state.state_available && state.runtime_identity_ok;
			if (ready) break;
			if (attempt < 29) sleep(1000);
		}
		if (!ready) return resume_failed("handoff_owner_readback_failed");
		if (before.active == true) {
			const policy = load_policy();
			if (policy == null || !paths.restore_runtime_selections(credentials.api_secret(), manifest, before.selections, policy))
				return resume_failed("handoff_selection_restore_failed");
		}
	} else if (backend.cleanup_state()?.ok != true || !observer_stopped()) {
		return failure("handoff_stopped_owner_changed");
	}
	if (before.supervisor?.installed == true && !supervisor.set_service_state(before.supervisor).ok)
		return failure("handoff_supervisor_restore_failed");
	if (!fs.unlink(SAVED) || !fs.rmdir(ROOT)) return failure("handoff_state_cleanup_failed");
	return { ok: true, result: { restored: true, running: before.running, profile: before.profile } };
};

return { drain, resume };
};
