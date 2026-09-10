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
			const model = context.use('configuration.onboarding-model');
			const builtin = candidate.builtin == true ? context.use('platform.storage').read_json(
				context.use('platform.paths').POLICY_SOURCE_DIR + '/base-v1.json') : null;
			if (candidate.builtin == true && builtin == null) return { ok: false, error: 'builtin_policy_missing' };
			if (candidate.switch_builtin == true) return { ok: true, result: { policy: model.use_builtin(candidate.policy, builtin) } };
			const discovery = builtin != null ? model.draft_builtin(candidate, builtin) : model.draft(candidate);
			return { ok: true, result: candidate.section == null ? discovery :
				{ ...discovery, ...model.merge_provider(candidate.policy, discovery, candidate.section) } };
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
	function command_sources(argv) {
		const input = context.use('platform.storage').read_json(argv[1]);
		const normalized = context.use('models.subscriptions').normalize_sources(input?.sources, input?.previous, input?.imported);
		if (!normalized.ok) return normalized;
		const planned = input?.reconcile == true ? context.use('configuration.onboarding-model').reconcile_sources(input.policy, normalized.sources) : { ok: true };
		return planned.ok ? { ok: true, result: { sources: normalized.sources, policy: planned.policy } } : planned;
	}
	return { command_tick, command_discover, command_sources };
};
