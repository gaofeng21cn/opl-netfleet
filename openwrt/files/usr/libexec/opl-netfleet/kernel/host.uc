import * as fs from 'fs';
import { API_VERSION, valid_id, service_name, descriptor_error, action_access } from './schema.uc';
import { read_json, trusted, mkdir_private, atomic_json } from './io.uc';
import { dispatch as process_dispatch, lifecycle as process_lifecycle } from './process.uc';
import { create_scope } from './scope.uc';

const RESERVED = ['plugins-list','plugin-read','plugin-call','plugin-drain','plugin-package-drain','plugin-package-resume','plugin-package-remove','plugin-package-ready'];

function failure(error) { return { ok: false, error: error }; };
function clone(value) { return json(sprintf('%J', value)); };
function raise(error) { die(error); };
function guarded(work, cleanup) {
	let result, failed;
	try { result = work(); } catch (error) { failed = error.message; }
	try { cleanup(); } catch (error) { failed = failed == null ? error.message : `${failed}; ${error.message}`; }
	if (failed != null) raise(failed);
	return result;
};
function host_options(options) {
	options = options ?? {};
	const adapter = options.adapter;
	if (type(adapter) != 'object' || type(adapter.paths) != 'object') raise('plugin_host_adapter_required');
	return { ...options, trusted_owner: options.trusted_owner ?? adapter.trusted_owner,
		override_path: options.override_path ?? adapter.paths.override,
		network_lock: options.network_lock ?? adapter.paths.network_lock,
		lock_root: options.lock_root ?? adapter.paths.code_locks,
		maintenance_root: options.maintenance_root ?? adapter.paths.maintenance,
	};
};
function checked_overlay(value) {
	if (type(value) != 'object' || type(value.bindings ?? {}) != 'object' || type(value.enabled ?? {}) != 'object' ||
		type(value.config ?? {}) != 'object') raise('plugin_system_invalid');
	for (let name, id in value.bindings ?? {}) if (!service_name(name) || !valid_id(id)) raise('plugin_system_invalid');
	for (let id, enabled in value.enabled ?? {}) if (!valid_id(id) || type(enabled) != 'bool') raise('plugin_system_invalid');
	for (let id, config in value.config ?? {}) if (!valid_id(id) || type(config) != 'object') raise('plugin_system_invalid');
	return value;
};
function overlay_profile(base, overlay) {
	const config = { ...(base.config ?? {}) };
	for (let id, value in overlay.config ?? {}) config[id] = { ...(config[id] ?? {}), ...value };
	return { ...base, ...overlay, bindings: { ...base.bindings, ...(overlay.bindings ?? {}) },
		enabled: { ...base.enabled, ...(overlay.enabled ?? {}) }, config: config };
};
function checked_system(value) {
	if (type(value) != 'object' || value.schema != 'opl-netfleet-system.v1' ||
		type(value.bindings) != 'object' || type(value.enabled) != 'object') raise('plugin_system_invalid');
	checked_overlay(value);
	if (type(value.instances ?? {}) != 'object') raise('plugin_system_invalid');
	for (let name, instance in value.instances ?? {}) {
		if (!valid_id(name) || name == 'default') raise('plugin_instance_invalid');
		checked_overlay(instance);
		for (let key in keys(instance)) if (index(['bindings','enabled','config'], key) < 0) raise('plugin_instance_invalid');
	}
	return value;
};
function system_profile(root, options) {
	if (options.system != null) return checked_system(clone(options.system));
	if (fs.lstat(`${root}/system.json`) != null) return checked_system(read_json(`${root}/system.json`));
	const default_path = options.adapter.paths.default_system;
	let profile = read_json(default_path) ??
		{ schema: 'opl-netfleet-system.v1', bindings: {}, enabled: {} };
	profile = checked_system(profile);
	const path = options.override_path;
	if (fs.lstat(path) != null) {
		if (!trusted(path, 'file', options.trusted_owner) || (fs.lstat(path).mode & 077)) raise('plugin_system_override_unsafe');
		const overlay = checked_system(read_json(path));
		const instances = { ...(profile.instances ?? {}) };
		for (let name, value in overlay.instances ?? {}) instances[name] = overlay_profile(instances[name] ?? { bindings: {}, enabled: {} }, value);
		profile = { ...overlay_profile(profile, overlay), instances: instances };
	}
	return profile;
};

function plugin_files(directory, owner, relative, files) {
	const path = relative == '' ? directory : `${directory}/${relative}`;
	if (!trusted(path, 'directory', owner)) raise('plugin_files_unsafe');
	for (let name in sort(fs.lsdir(path) ?? [])) {
		if (!match(name, /^[A-Za-z0-9][A-Za-z0-9._-]*$/)) raise(`plugin_payload_name_invalid:${name}`);
		const child = relative == '' ? name : `${relative}/${name}`, full = `${directory}/${child}`;
		const info = fs.lstat(full);
		if (info?.type == 'directory') plugin_files(directory, owner, child, files);
		else {
			if (!trusted(full, 'file', owner) || info.size > 1048576 || length(files) >= 512) raise('plugin_files_unsafe');
			push(files, full);
		}
	}
};
function inspect(root, id, owner, adapter) {
	const directory = `${root}/plugins/${id}`, path = `${directory}/manifest.json`;
	if (fs.lstat(directory) == null) return failure('plugin_not_installed');
	try {
		if (!trusted(`${root}/plugins`, 'directory', owner) || !trusted(path, 'file', owner) || fs.lstat(path).size > 16384) return failure('plugin_files_unsafe');
		const manifest = read_json(path), error = descriptor_error(manifest, id);
		if (error != null) return failure(error);
		const files = [];
		plugin_files(directory, owner, '', files);
		const process = manifest.schema == 'opl-netfleet-plugin.v1';
		if (process && (!trusted(`${directory}/control`, 'file', owner) || !(fs.lstat(`${directory}/control`).mode & 0111))) return failure('plugin_files_unsafe');
		for (let name, service in manifest.services ?? {}) if (index(files, `${directory}/${service.module}`) < 0) return failure('plugin_module_missing');
		for (let page in manifest.ui ?? []) if (index(files, `${directory}/${page.module}`) < 0) return failure('plugin_ui_module_missing');
		const digest = adapter.inspect_digest(directory, files);
		if (type(digest) != 'string' || !match(digest, /^[a-f0-9]{64}$/)) return failure('plugin_identity_unreadable');
		return { ok: true, manifest: manifest, directory: directory, entry: `${directory}/control`, revision: digest, process: process };
	} catch (error) { return failure(error.message ?? 'plugin_inspection_failed'); }
};

export function create(root, options) {
	const explicit_locks = options?.lock_root != null;
	options = host_options(options);
	root = fs.realpath(root) ?? root;
	const adapter = options.adapter, all_system = system_profile(root, options);
	const instance_id = options.instance ?? 'default';
	if (!valid_id(instance_id) || (instance_id != 'default' && all_system.instances?.[instance_id] == null)) raise('plugin_instance_unknown');
	const system = instance_id == 'default' ? all_system : overlay_profile(all_system, all_system.instances[instance_id]);
	const found = {}, instances = {}, service_scopes = {}, leases = {}, loading = {}, scope = create_scope();
	const owner = options.trusted_owner;
	const maintenance_root = options.maintenance_root, lock_root = options.lock_root;
	const state_store = options.states ?? {};
	if (instance_id != 'default') { state_store.__instances = state_store.__instances ?? {}; state_store.__instances[instance_id] = state_store.__instances[instance_id] ?? {}; }
	const states = instance_id == 'default' ? state_store : state_store.__instances[instance_id];
	const delegated = adapter.coordinator_parent(`${maintenance_root}/.coordinator`);
	let closed = false;
	let inventory;
	for (let id in sort(fs.lsdir(`${root}/plugins`) ?? [])) if (valid_id(id)) found[id] = inspect(root, id, owner, adapter);
	function blocked(id) {
		if (options.allow_maintenance || delegated) return false;
		return fs.lstat(maintenance_root) != null && (!trusted(maintenance_root, 'directory', owner) || fs.lstat(`${maintenance_root}/${id}`) != null);
	};
	function provider(name, major) {
		const id = system.bindings[name];
		if (id == null) raise(`plugin_service_unbound:${name}`);
		if (system.enabled[id] != true) raise(`plugin_disabled:${id}`);
		const plugin = found[id];
		if (!plugin?.ok) raise(`${plugin?.error ?? 'plugin_not_installed'}:${id}`);
		if (instance_id != 'default' && plugin.manifest.lifecycle != null && plugin.manifest.lifecycle.scope != 'instance') raise(`plugin_resource_scope_required:${id}`);
		if (plugin.manifest.api_version != API_VERSION) raise(`plugin_api_incompatible:${id}`);
		if (blocked(id)) raise(`plugin_package_maintenance:${id}`);
		const service = plugin.manifest.services?.[name];
		if (service == null) raise(`plugin_service_missing:${name}`);
		if (service.version != major) raise(`plugin_service_incompatible:${name}`);
		return { id: id, plugin: plugin, service: service };
	};
	function graph(name, major, visiting, complete, plugins) {
		if (visiting[name]) raise(`plugin_dependency_cycle:${name}`);
		const item = provider(name, major);
		if (complete[name]) return;
		visiting[name] = true;
		for (let dependency, version in item.service.requires) graph(dependency, version, visiting, complete, plugins);
		delete visiting[name]; complete[name] = true; plugins[item.id] = true;
	};
	function acquire(plugins) {
		if (options.code_locks == false || (root != adapter.paths.installed_root && !explicit_locks)) return;
		if (!mkdir_private(lock_root, owner)) raise('plugin_code_lock_unsafe');
		for (let id in sort(keys(plugins))) {
			if (leases[id] != null) continue;
			const path = `${lock_root}/${id}.lock`;
			if (fs.lstat(path) != null && !trusted(path, 'file', owner)) raise('plugin_code_lock_unsafe');
			const lease = fs.open(path, 'ae', 0600);
			if (lease == null || !lease.lock('sn')) { lease?.close(); raise(`plugin_code_busy:${id}`); }
			leases[id] = lease;
			if (blocked(id)) raise(`plugin_package_maintenance:${id}`);
			const current = inspect(root, id, owner, adapter);
			if (!current.ok || current.revision != found[id].revision) raise(`plugin_code_changed:${id}`);
		}
	};
	function resolve(name, major) {
		const item = provider(name, major);
		if (instances[name] != null) {
			if (service_scopes[name].closed()) raise(`plugin_service_disposed:${name}`);
			return instances[name];
		}
		if (loading[name]) raise(`plugin_dependency_cycle:${name}`);
		loading[name] = true;
		for (let dependency, version in item.service.requires) resolve(dependency, version);
		states[item.id] = states[item.id] ?? {};
		const resources = scope.scope();
		const context = {
			id: item.id, instance: instance_id, root: root, argv: options.argv ?? [], state: states[item.id], system: clone(system),
			config: clone(system.config?.[item.id] ?? {}),
			effect: resources.effect, on: resources.on, emit: resources.emit, scope: resources.scope, dispose: resources.dispose,
			use: dependency => {
				if (closed || resources.closed()) raise('plugin_context_closed');
				const version = item.service.requires[dependency];
				if (version == null) raise(`plugin_dependency_undeclared:${name}:${dependency}`);
				return resolve(dependency, version);
			},
			inventory: versions => inventory(versions),
		};
		try {
			const factory = loadfile(`${item.plugin.directory}/${item.service.module}`)();
			if (type(factory) != 'function') raise(`plugin_factory_invalid:${name}`);
			const instance = factory(context);
			if (type(instance) != 'object') raise(`plugin_service_invalid:${name}`);
			instances[name] = instance; service_scopes[name] = resources; delete loading[name];
			return instance;
		} catch (error) {
			delete loading[name];
			guarded(() => raise(error.message), resources.dispose);
		}
	};
	function use(name, major) {
		if (closed) raise('plugin_context_closed');
		major = major ?? 1;
		const plugins = {};
		graph(name, major, {}, {}, plugins);
		acquire(plugins);
		return resolve(name, major);
	};
	inventory = function(versions) {
		const rows = [];
		for (let id in sort(keys(found))) {
			const item = found[id];
			if (!item.ok) { push(rows, { id: id, label: id, kind: 'plugin', state: 'invalid', reason: item.error, instance: instance_id }); continue; }
			const manifest = item.manifest;
			if (instance_id != 'default' && item.process) continue;
			const dependencies = map(manifest.package_dependencies ?? manifest.dependencies ?? [], name => ({ id: name,
				installed_version: versions?.[name] ?? null, available: versions == null ? null : versions[name] != null }));
			let reason = blocked(id) ? 'plugin_package_maintenance' : manifest.api_version != API_VERSION ? 'plugin_api_incompatible' : null;
			if (reason == null && !item.process && system.enabled[id] != true) reason = 'plugin_disabled';
			if (reason == null && length(filter(dependencies, entry => entry.available == false))) reason = 'plugin_dependency_missing';
			if (reason == null && !item.process) try {
				for (let name, definition in manifest.services) if (system.bindings[name] == id) graph(name, definition.version, {}, {}, {});
			} catch (error) { reason = error.message; }
			push(rows, { ...manifest, kind: 'plugin', runtime: item.process ? 'process' : 'service', revision: item.revision,
				ui: filter(manifest.ui ?? [], page => instance_id == 'default' || page.scope != 'host'),
				dependencies: dependencies, installed_version: versions?.[manifest.package] ?? null,
				state: reason == null ? 'available' : 'unavailable', reason: reason,
				enabled: item.process ? null : system.enabled[id] == true, instance: instance_id });
		}
		return rows;
	};
	function command(name) {
		let result = null;
		for (let id, item in found) {
			if (!item.ok || system.enabled[id] != true || item.process) continue;
			const value = item.manifest.commands[name];
			if (value == null || system.bindings[value.service] != id) continue;
			if (result != null || index(RESERVED, name) >= 0) raise(`plugin_command_conflict:${name}`);
			result = { ...value, id: id };
		}
		return result;
	};
	function call(service, method, args) {
		const version = found[system.bindings[service]]?.manifest?.services?.[service]?.version;
		const instance = use(service, version);
		if (type(instance[method]) != 'function') raise(`plugin_method_missing:${service}:${method}`);
		return instance[method](args);
	};
	function release() {
		if (closed) return;
		closed = true;
		guarded(scope.dispose, () => { for (let id in keys(leases)) { leases[id].close(); delete leases[id]; } });
	};
	return { use: use, call: call, release: release, inventory: inventory, command: command, system: system,
		all_system: all_system, instance: instance_id, adapter: adapter,
		found: found, blocked: blocked, acquire: acquire, graph: graph, root: root, options: options };
};

function resource_owners(host, target) {
	const candidates = {}, result = [], visited = {};
	for (let id, item in host.found) {
		if (!item.ok || item.process || host.system.enabled[id] != true || item.manifest.lifecycle == null) continue;
		if (host.instance != 'default' && item.manifest.lifecycle.scope != 'instance') continue;
		const dependencies = {};
		for (let name, service in item.manifest.services) if (host.system.bindings[name] == id) host.graph(name, service.version, {}, {}, dependencies);
		if (dependencies[target]) candidates[id] = dependencies;
	}
	function visit(id) {
		if (visited[id]) return;
		visited[id] = true;
		for (let dependency in keys(candidates[id])) if (dependency != id && candidates[dependency] != null) visit(dependency);
		push(result, id);
	};
	for (let id in keys(candidates)) visit(id);
	return result;
};
function package_operation(action, id, root, options) {
	if (!valid_id(id)) return failure('plugin_id_invalid');
	const adapter = options.adapter, base = options.maintenance_root, directory = `${base}/${id}`;
	if (!mkdir_private(base, options.trusted_owner) || !mkdir_private(directory, options.trusted_owner)) return failure('plugin_package_marker_failed');
	const record_path = `${directory}/state.json`, marker = `${directory}/replacing`, resources = `${base}/.resources`;
	if (!mkdir_private(resources, options.trusted_owner)) return failure('plugin_package_marker_failed');
	const host = create(root, { ...options, instance: 'default', allow_maintenance: true, code_locks: false });
	const hosts = { default: host };
	function scoped(name) {
		if (hosts[name] == null) hosts[name] = create(root, { ...options, instance: name, allow_maintenance: true, code_locks: false });
		return hosts[name];
	};
	function resource_ref(key) {
		const fields = split(key, ':');
		return { host: scoped(length(fields) == 1 ? 'default' : fields[0]), id: fields[length(fields) - 1] };
	};
	return guarded(() => {
		if (action == 'plugin-package-drain') {
			let record = read_json(record_path) ?? { id: id, drained: [] };
			const previous = read_json(marker);
			const item = host.found[id];
			if (item != null && !item.ok) return item;
			if (item?.process) {
				const stopped = process_lifecycle(item, 'unload', {}, adapter);
				if (!stopped.ok) return stopped;
			} else {
			const owners = [];
			const names = options.lifecycle_instances ?? ['default', ...sort(keys(host.all_system.instances ?? {}))];
			for (let name in names) for (let resource in resource_owners(scoped(name), id)) push(owners, name == 'default' ? resource : `${name}:${resource}`);
			for (let resource in reverse(owners)) {
				const resource_path = `${resources}/${resource}.json`;
				let saved = read_json(resource_path) ?? { state: null, blockers: {}, drained: false };
				saved.blockers[id] = true;
				if (index(record.drained, resource) < 0) push(record.drained, resource);
				if (!atomic_json(record_path, record) || !atomic_json(resource_path, saved)) return failure('plugin_package_marker_failed');
				if (!saved.drained || previous?.phase == 'resume_failed') {
					const ref = resource_ref(resource), hook = ref.host.found[ref.id].manifest.lifecycle.drain;
					const stopped = ref.host.call(hook.service, hook.method, saved.state);
					if (!stopped?.ok) return stopped ?? failure('plugin_drain_unconfirmed');
					saved.state = stopped.result ?? {}; saved.drained = true;
					if (!atomic_json(resource_path, saved)) return failure('plugin_package_marker_failed');
				}
			}
			}
			const lock_root = options.lock_root;
			if (!mkdir_private(lock_root, options.trusted_owner)) return failure('plugin_code_lock_unsafe');
			const lease_path = `${lock_root}/${id}.lock`;
			if (fs.lstat(lease_path) != null && !trusted(lease_path, 'file', options.trusted_owner)) return failure('plugin_code_lock_unsafe');
			const lease = fs.open(lease_path, 'ae', 0600);
			if (lease == null || !lease.lock('xn')) { lease?.close(); return failure('plugin_calls_draining'); }
			const ok = atomic_json(marker, { phase: 'drained', revision: item?.revision ?? 'absent' });
			lease.close();
			return ok ? { ok: true, result: { id: id, loaded: false, state: 'replacing' } } : failure('plugin_package_marker_failed');
		}
		const record = read_json(record_path);
		if (action == 'plugin-package-resume') {
			const item = host.found[id];
			if (!item?.ok || item.manifest.api_version != API_VERSION) return failure(item?.error ?? 'plugin_not_installed');
		}
		for (let resource in reverse(record?.drained ?? [])) {
			const resource_path = `${resources}/${resource}.json`, saved = read_json(resource_path);
			if (saved == null) continue;
			delete saved.blockers[id];
			if (action == 'plugin-package-remove') saved.removed = true;
			if (!atomic_json(resource_path, saved)) return failure('plugin_package_marker_failed');
			if (length(saved.blockers)) continue;
			if (!saved.removed) {
				const ref = resource_ref(resource), hook = ref.host.found[ref.id]?.manifest?.lifecycle?.resume;
				let resumed;
				if (!atomic_json(marker, { phase: 'resume_failed' })) return failure('plugin_package_marker_failed');
				saved.drained = false;
				if (!atomic_json(resource_path, saved)) return failure('plugin_package_marker_failed');
				try { resumed = hook == null ? failure('plugin_resume_owner_missing') : ref.host.call(hook.service, hook.method, saved.state); }
				catch (error) { resumed = failure(error.message); }
				if (!resumed?.ok) {
					return resumed ?? failure('plugin_resume_unconfirmed');
				}
			}
			fs.unlink(resource_path);
		}
		fs.unlink(marker); fs.unlink(record_path); fs.rmdir(directory);
		return { ok: true, result: { id: id, state: action == 'plugin-package-remove' ? 'removed' : 'available' } };
	}, () => {
		const errors = [];
		for (let name in reverse(keys(hosts))) try { hosts[name].release(); } catch (error) { push(errors, error.message); }
		if (length(errors)) raise(join('; ', errors));
	});
};

function service_request(input, found, host) {
	const id = input.id, action = input.action;
	if (action == 'get') {
		let ready = host.system.enabled[id] == true;
		try { if (ready) for (let name, service in found.manifest.services) if (host.system.bindings[name] == id) host.graph(name, service.version, {}, {}, {}); }
		catch (error) { ready = false; }
		return { ok: true, result: { id: id, instance: host.instance, loaded: host.system.enabled[id] == true, ready: ready && !host.blocked(id), revision: found.revision, services: keys(found.manifest.services) } };
	}
	const declared = found.manifest.actions?.[action];
	if (declared != null) {
		if (host.system.bindings[declared.service] != id) return failure('plugin_action_provider_mismatch');
		const result = host.call(declared.service, declared.method, input.params ?? {});
		if (type(result) != 'object' || type(result.ok) != 'bool') return failure('plugin_response_invalid');
		return result;
	}
	if (index(['load','unload','reload'], action) < 0) return failure('plugin_action_not_allowed');
	const profile = clone(host.all_system);
	const target = host.instance == 'default' ? profile : profile.instances[host.instance];
	target.bindings = target.bindings ?? {}; target.enabled = target.enabled ?? {};
	if (action != 'unload') for (let name in keys(found.manifest.services)) {
		if (host.system.bindings[name] != null && host.system.bindings[name] != id) return failure(`plugin_binding_conflict:${name}`);
		target.bindings[name] = id;
	}
	target.enabled[id] = action != 'unload';
	const affected = [host.instance];
	if (host.instance == 'default') for (let name in keys(profile.instances ?? {})) {
		const before = overlay_profile(host.all_system, host.all_system.instances[name]);
		const after = overlay_profile(profile, profile.instances[name]);
		if (before.enabled[id] != after.enabled[id] || length(filter(keys(found.manifest.services), service => before.bindings[service] != after.bindings[service]))) push(affected, name);
	}
	if (action == 'unload') for (let name in affected) {
		const scope = create(host.root, { ...host.options, system: host.all_system, instance: name });
		const required = guarded(() => {
			for (let other, item in scope.found) {
				if (!item.ok || item.process || other == id || scope.system.enabled[other] != true ||
					(name != 'default' && item.manifest.lifecycle != null && item.manifest.lifecycle.scope != 'instance')) continue;
				for (let service, definition in item.manifest.services) if (scope.system.bindings[service] == other) {
					const closure = {}; scope.graph(service, definition.version, {}, {}, closure);
					if (closure[id]) return other;
				}
			}
			return null;
		}, scope.release);
		if (required != null) return failure(`plugin_required_by:${required}`);
	}
	const path = host.options.override_path;
	const previous = read_json(path);
	const overlay = previous == null ? { schema: 'opl-netfleet-system.v1', bindings: {}, enabled: {} } : clone(previous);
	let overlay_target = overlay;
	if (host.instance != 'default') {
		overlay.instances = overlay.instances ?? {};
		overlay.instances[host.instance] = overlay.instances[host.instance] ?? {};
		overlay_target = overlay.instances[host.instance];
	}
	overlay_target.enabled = overlay_target.enabled ?? {}; overlay_target.bindings = overlay_target.bindings ?? {};
	overlay_target.enabled[id] = action != 'unload';
	if (action != 'unload') for (let name in keys(found.manifest.services)) overlay_target.bindings[name] = id;
	const candidate = create(host.root, { ...host.options, system: profile });
	guarded(() => {
		if (action != 'unload') for (let name in keys(found.manifest.services)) candidate.use(name, found.manifest.services[name].version);
	}, () => candidate.release());
	const lifecycle_options = { ...host.options, lifecycle_instances: affected };
	const drained = package_operation('plugin-package-drain', id, host.root, lifecycle_options);
	if (!drained.ok) {
		const restored = package_operation('plugin-package-resume', id, host.root, lifecycle_options);
		return { ...drained, rollback: restored };
	}
	if (!atomic_json(path, overlay)) return { ...failure('plugin_system_write_failed'), rollback: package_operation('plugin-package-resume', id, host.root, lifecycle_options) };
	const complete = package_operation(action == 'unload' ? 'plugin-package-remove' : 'plugin-package-resume', id, host.root, { ...lifecycle_options, system: profile });
	if (!complete.ok) { if (previous == null) fs.unlink(path); else atomic_json(path, previous); return complete; }
	return { ok: true, result: { id: id, loaded: action != 'unload', ready: action != 'unload', revision: found.revision } };
};

function management(action, argv, root, options) {
	if (action == 'plugin-package-ready') {
		if (!valid_id(argv[1])) return failure('plugin_id_invalid');
		const host = create(root, options);
		return guarded(() => host.blocked(argv[1]) ? failure('plugin_package_maintenance') : { ok: true, result: { ready: true } }, () => host.release());
	}
	if (action == 'plugins-list') {
		const host = create(root, options);
		return guarded(() => {
			const plugins = host.inventory(null), names = sort(keys(host.all_system.instances ?? {}));
			for (let name in names) {
				const instance = create(root, { ...options, instance: name });
				guarded(() => { for (let row in instance.inventory(null)) push(plugins, row); }, instance.release);
			}
			return { ok: true, result: { plugins: plugins, instances: ['default', ...names] } };
		}, () => host.release());
	}
	const adapter = options.adapter;
	const lock = adapter.network_lock(options.network_lock, action != 'plugin-read');
	if (lock == null) return failure('mutation_busy');
	let host;
	const base = options.maintenance_root;
	return guarded(() => {
		if (action != 'plugin-read' && (!mkdir_private(base, options.trusted_owner) || !atomic_json(`${base}/.coordinator`, adapter.process_identity()))) return failure('plugin_package_marker_failed');
		if (index(['plugin-package-drain','plugin-package-resume','plugin-package-remove'], action) >= 0) {
			let result = failure('plugin_id_invalid');
			for (let id in slice(argv, 1)) {
				result = package_operation(action, id, root, options);
				if (!result.ok) return result;
			}
			return result;
		}
		const path = argv[1];
		if (!adapter.private_file(path) || fs.lstat(path).size > 65536) return failure('plugin_private_request_required');
		const input = read_json(path)?.request;
		if (type(input) != 'object' || !valid_id(input.id) || type(input.action) != 'string' ||
			(input.instance != null && !valid_id(input.instance)) || (input.params != null && type(input.params) != 'object')) return failure('plugin_request_invalid');
		host = create(root, { ...options, instance: input.instance ?? 'default' });
		const item = host.found[input.id];
		if (action == 'plugin-drain') {
			if (input.action != 'unload' || input.confirm != true) return failure('plugin_confirmation_or_revision_required');
			if (input.revision != (item?.revision ?? 'absent')) return failure('plugin_confirmation_or_revision_required');
			return package_operation('plugin-package-drain', input.id, root, options);
		}
		if (!item?.ok) return failure(item?.error ?? 'plugin_not_installed');
		const access = action_access(item.manifest, input.action);
		if (access != (action == 'plugin-read' ? 'read' : 'write')) return failure('plugin_action_not_allowed');
		if (access == 'write' && (input.confirm != true || input.revision != item.revision)) return failure('plugin_confirmation_or_revision_required');
		if (host.blocked(input.id)) {
			const marker = `${base}/${input.id}/replacing`;
			if (access != 'write' || index(['load','unload','reload'], input.action) < 0 || !adapter.private_file(marker) || read_json(marker)?.phase != 'resume_failed') return failure('plugin_package_maintenance');
			const reconciled = package_operation('plugin-package-resume', input.id, root, options);
			if (!reconciled.ok) return reconciled;
		}
		if (item.manifest.api_version != API_VERSION && index(['get','unload'], input.action) < 0) return failure('plugin_api_incompatible');
		if (!item.process) return service_request(input, item, host);
		if (host.instance != 'default') return failure('plugin_process_instance_unsupported');
		if (index(['get','unload'], input.action) < 0) {
			if (length(item.manifest.backends)) {
				const environment_service = host.system.environment;
				const environment = environment_service == null ? null : host.use(environment_service.service)[environment_service.method]();
				if (environment?.backend == null || index(item.manifest.backends, environment.backend) < 0) return failure('plugin_backend_unsupported');
			}
			for (let name in item.manifest.dependencies) if (!adapter.package_available(name)) return failure('plugin_dependency_missing');
		}
		host.acquire({ [input.id]: true });
		return process_dispatch(input, item, adapter);
	}, () => guarded(() => host?.release(), () => { if (action != 'plugin-read') fs.unlink(`${base}/.coordinator`); lock.close(); }));
};

export function execute(argv, root, options) {
	options = { ...(options ?? {}), argv: argv };
	let result, host;
	try {
		options = host_options(options);
		if (index(RESERVED, argv[0]) >= 0) result = management(argv[0], argv, root, options);
		else {
			host = create(root, options);
			const command = host.command(argv[0]);
			if (command == null) result = { ...failure('unknown_command'), detail: { command: argv[0],
				plugins: map(filter(host.inventory(null), item => item.state != 'available'), item => ({ id: item.id, reason: item.reason })) } };
			else result = host.call(command.service, command.method, argv);
		}
	} catch (error) { result = failure(error.message ?? 'plugin_execution_failed'); }
	try { host?.release(); } catch (error) { result = failure(error.message); }
	return result;
};

export function run(argv, root, options) {
	const result = execute(argv, root, options);
	if (result != null) printf('%J\n', result);
	if (result?.ok == false) exit(1);
};

export function tick(root, states, options) {
	let host, delay = 5000, lock;
	try {
		options = host_options(options);
		lock = options.adapter.network_lock(options.network_lock, true);
		if (lock != null) {
			host = create(root, { ...options, states: states });
			const scheduler = host.system.scheduler;
			if (scheduler != null) {
				const id = host.system.bindings[scheduler.service];
				states[id] = states[id] ?? {};
				const result = host.call(scheduler.service, scheduler.method, states[id]);
				if (type(result?.state) == 'object') states[id] = result.state;
				if (type(result?.delay_ms) == 'int') delay = max(100, min(result.delay_ms, 60000));
			}
		}
	} catch (error) { warn(`NetFleet scheduler: ${error.message}\n`); }
	try { guarded(() => host?.release(), () => lock?.close()); }
	catch (error) { warn(`NetFleet cleanup: ${error.message}\n`); }
	return delay;
};
