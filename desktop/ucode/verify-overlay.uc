import { create } from './kernel/host.uc';
import { API_VERSION } from './kernel/schema.uc';
import { create as create_adapter } from './adapters/macos.uc';

const root = sourcepath(0, true), staging_root = ARGV[0], id = ARGV[1];
try {
	const options = { adapter: create_adapter(root), code_locks: false, lazy_inspection: true };
	const before = create(root, options);
	const staged = create(staging_root, { ...options, system: before.all_system });
	const candidate = staged.inspect(id);
	if (candidate?.ok != true) die(candidate?.error ?? 'plugin_not_installed');
	if (candidate.manifest.api_version != API_VERSION) die('plugin_api_incompatible');
	staged.release();

	// Inspect only the staged plugin, then resolve it in the current desktop composition.
	const inspected = { ...before.found };
	inspected[id] = candidate;
	for (let instance in ['default', ...keys(before.all_system.instances ?? {})]) {
		const original = instance == 'default' ? before : create(root, { ...options, instance, inspected: before.found });
		const after = create(root, { ...options, instance, inspected });
		for (let service, provider in original.system.bindings) {
			if (provider != id || original.system.enabled[provider] != true) continue;
			const version = before.found[id]?.manifest?.services?.[service]?.version ?? 1;
			after.graph(service, version, {}, {}, {});
		}
		for (let name in keys(before.found[id]?.manifest?.commands ?? {})) {
			if (original.command(name)?.id == id && after.command(name)?.id != id) die('plugin_command_missing');
		}
		for (let name in keys(candidate.manifest.commands)) after.command(name);
		after.release();
		if (original != before) original.release();
	}
	before.release();
	printf('%J\n', { ok: true });
} catch (error) {
	printf('%J\n', { ok: false, error: error.message ?? 'overlay_compatibility_check_failed' });
}
