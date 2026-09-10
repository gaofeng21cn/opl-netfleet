import * as fs from 'fs';
const rpc = global.__netfleetDesktopOwner.rpc;
return function(context) {
	function command_tick(argv) {
		let previous = {};
		if (argv[1] != null) try { previous = json(argv[1]); } catch (error) { return { ok: false, error: 'scheduler_state_invalid' }; }
		return { ok: true, result: context.use('scheduler.control').tick(previous) };
	}
	function command_discover(argv) {
		if (argv[1] != null) {
			const candidate = context.use('platform.storage').read_json(argv[1]);
			return { ok: true, result: context.use('configuration.onboarding-model').draft(candidate) };
		}
		const state = rpc('state.get'), backend = context.use('mihomo.backend'), storage = context.use('platform.storage');
		const path = backend.resolve_profile(state.profile);
		const subscriptions = [];
		for (let id, value in state.subscriptions ?? {}) {
			if (value.enabled == false) continue;
			const source = backend.resolve_profile(`subscription:${id}`);
			push(subscriptions, { section: id, display_name: value.name ?? id, profile: storage.read_yaml(source), digest: storage.sha256(source) });
		}
		const discovery = context.use('configuration.onboarding-model').draft({
			current_profile: state.profile, current_profile_object: path == null ? null : storage.read_yaml(path),
			current_profile_digest: path == null ? null : storage.sha256(path),
			generated_artifacts_present: fs.stat(backend.ARTIFACT_PATH) != null, subscriptions,
			target: 'macos', evidence_path: context.use('platform.paths').EVIDENCE_PATH });
		return { ok: true, result: discovery };
	}
	return { command_tick, command_discover };
};
