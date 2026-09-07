#!/usr/bin/ucode
import * as fs from 'fs';
import { create, execute } from '../openwrt/files/usr/libexec/opl-netfleet/kernel/host.uc';
import { trusted } from '../openwrt/files/usr/libexec/opl-netfleet/kernel/io.uc';
import { create as create_openwrt } from '../openwrt/files/usr/libexec/opl-netfleet/adapters/openwrt.uc';

let assertions = 0;
function check(value, message) { if (!value) die(message); assertions++; };
function clone(value) { return json(sprintf('%J', value)); };
const root = fs.realpath(fs.mkdtemp('/tmp/netfleet-composition.XXXXXX'));
check(root != null, 'private composition fixture created');
const owner = fs.stat(root).uid, states = {}, held_hosts = [];
let lock_count = 0, unlock_count = 0, lease;
function remove(path) {
	if (fs.lstat(path)?.type == 'directory') {
		for (let name in fs.lsdir(path) ?? []) remove(`${path}/${name}`);
		fs.rmdir(path);
	} else fs.unlink(path);
};
function directory(path) { check(fs.mkdir(path, 0700), `mkdir ${path}`); };
function write(path, value) {
	const text = type(value) == 'string' ? value : sprintf('%J', value);
	check(fs.writefile(path, text) == length(text) && fs.chmod(path, 0600), `write ${path}`);
};
function read(path) { return json(fs.readfile(path)); };
function copy(source, target) {
	if (fs.lstat(source)?.type == 'directory') {
		directory(target);
		for (let name in fs.lsdir(source)) copy(`${source}/${name}`, `${target}/${name}`);
	} else write(target, fs.readfile(source));
};
const adapter = {
	...create_openwrt(), trusted_owner: owner,
	paths: { installed_root: root, default_system: `${root}/defaults.json`, override: `${root}/overrides.json`,
		network_lock: `${root}/network.lock`, code_locks: `${root}/locks`, maintenance: `${root}/maintenance` },
	private_file: path => trusted(path, 'file', owner) && !(fs.lstat(path).mode & 077),
	network_lock: (path, writing) => {
		check(path == `${root}/network.lock`, 'all instances use the same mutation lock');
		const file = fs.open(path, 'ae', 0600);
		if (file == null || !file.lock(writing ? 'xn' : 'sn')) { file?.close(); return null; }
		lock_count++;
		return { close: () => { file.close(); unlock_count++; } };
	},
	process_identity: () => ({ pid: 'composition', parent: 'fixture', start: 'one' }),
	coordinator_parent: () => false,
};
const options = { adapter, states, lock_root: `${root}/locks` };
const profile = { schema: 'opl-netfleet-system.v1', bindings: {}, enabled: {},
	config: { echo: { label: 'base', inherited: 'shared' }, 'workspace-note': { data_path: `${root}/state/note.json` } },
	instances: {
		alpha: { config: { echo: { label: 'alpha' }, 'workspace-note': { data_path: `${root}/state/alpha-note.json` } }, enabled: { resource: true } },
		beta: { config: { echo: { label: 'beta' }, 'workspace-note': { data_path: `${root}/state/beta-note.json` } }, enabled: { resource: true } },
	} };
function install(id, service, source, extra) {
	directory(`${root}/plugins/${id}`); directory(`${root}/plugins/${id}/lib`);
	const manifest = { schema: 'opl-netfleet-service-plugin.v1', id, label: id, version: '1.0.0', api_version: 1,
		package: `opl-netfleet-plugin-${id}`, services: { [service]: { version: 1, module: 'lib/main.uc', requires: {} } }, commands: {}, ...extra };
	write(`${root}/plugins/${id}/manifest.json`, manifest);
	write(`${root}/plugins/${id}/lib/main.uc`, source);
	profile.enabled[id] = true;
	if (profile.bindings[service] == null) profile.bindings[service] = id;
	return manifest;
};
function listing() {
	const result = execute(['plugins-list'], root, options);
	check(result.ok, `inventory succeeds: ${result.error ?? ''}`);
	return result.result;
};
function row(id, instance) {
	const entries = filter(listing().plugins, entry => entry.id == id);
	const matches = filter(entries, entry => entry.instance == (instance ?? 'default'));
	check(length(matches) == 1, `plugin instance found: ${id}: ${sprintf('%J', entries)}`);
	return matches[0];
};
function request(input, command, extra) {
	const path = `${root}/request.json`;
	write(path, { request: input });
	const result = execute([command ?? 'plugin-read', path], root, { ...options, ...(extra ?? {}) });
	check(lock_count == unlock_count && fs.lstat(`${root}/maintenance/.coordinator`) == null, 'completed request releases mutation admission');
	return result;
};
function change(id, action, params, instance) {
	return request({ id, action, params, instance, revision: row(id, instance).revision, confirm: true }, 'plugin-call');
};
function package_action(action, id) {
	const result = execute([`plugin-package-${action}`, id], root, options);
	check(lock_count == unlock_count && fs.lstat(`${root}/maintenance/.coordinator`) == null, 'package transaction releases mutation admission');
	return result;
};
function resource_state(instance) { return read(`${root}/state/resource-${instance}.json`); };

try {
	for (let name in ['plugins', 'locks', 'maintenance', 'state']) directory(`${root}/${name}`);
	const echo_source = "return function(ctx) {\n" +
		" const state = ctx.state; state.cleanups = state.cleanups ?? [];\n" +
		" ctx.effect(() => { push(state.cleanups, 'service'); });\n" +
		" const child = ctx.scope(); child.effect(() => { push(state.cleanups, 'child'); });\n" +
		" ctx.on('seen', () => { state.events = (state.events ?? 0) + 1; });\n" +
		" if (ctx.config.fail_factory) die('fixture_factory_failed');\n" +
		" function inspect(params) { state.count = (state.count ?? 0) + (params.step ?? 1); ctx.emit('seen', params); return { ok: true, result: { params, config: ctx.config, instance: ctx.instance, count: state.count } }; };\n" +
		" function update(params) { state.writes = (state.writes ?? 0) + 1; return inspect(params); };\n" +
		" return { inspect, update, fail: () => { die('fixture_action_failed'); } };\n};\n";
	install('echo', 'echo.control', echo_source, { actions: {
		inspect: { service: 'echo.control', method: 'inspect', access: 'read' },
		update: { service: 'echo.control', method: 'update', access: 'write' },
		fail: { service: 'echo.control', method: 'fail', access: 'read' },
	} });
	install('other', 'echo.control', echo_source, {});
	const example = fs.realpath(`${sourcepath(0, true)}/../examples/plugins/workspace-note`);
	check(example != null, 'external example source exists');
	copy(example, `${root}/plugins/workspace-note`);
	profile.enabled['workspace-note'] = true;
	profile.bindings['workspace-note.document'] = 'workspace-note';
	directory(`${root}/plugins/ui-panel`); directory(`${root}/plugins/ui-panel/resources`);
	write(`${root}/plugins/ui-panel/manifest.json`, { schema: 'opl-netfleet-service-plugin.v1', id: 'ui-panel', label: 'Panel',
		version: '1.0.0', api_version: 1, package: 'opl-netfleet-plugin-ui-panel', services: {}, commands: {},
		ui: [{ id: 'panel', title: 'Panel', module: 'resources/page.js' },
			{ id: 'host', title: 'Host', module: 'resources/page.js', scope: 'host' }] });
	write(`${root}/plugins/ui-panel/resources/page.js`, 'export function mount(context) {}\n');
	profile.enabled['ui-panel'] = false;
	const resource_source = "import * as fs from 'fs';\nreturn function(ctx) {\n" +
		" const path = ctx.root + '/state/' + ctx.id + '-' + ctx.instance + '.json';\n" +
		" function state() { return fs.lstat(path) == null ? { running: true, drains: 0, resumes: 0 } : json(fs.readfile(path)); };\n" +
		" function save(value) { if (!fs.writefile(path, sprintf('%J', value))) die('fixture_write_failed'); };\n" +
		" function drain(previous) { const current = state(); previous = previous ?? { running: current.running, instance: ctx.instance }; current.running = false; current.drains++; save(current); return { ok: true, result: previous }; };\n" +
		" function resume(previous) { if (previous.instance != ctx.instance) die('fixture_instance_handoff_mismatch'); const current = state(); current.running = previous.running; current.resumes++; save(current); return { ok: true, result: current }; };\n" +
		" return { drain, resume, inspect: () => ({ ok: true, result: state() }) };\n};\n";
	install('resource', 'resource.control', resource_source, { lifecycle: { scope: 'instance',
		drain: { service: 'resource.control', method: 'drain' }, resume: { service: 'resource.control', method: 'resume' } } });
	profile.enabled.resource = false;
	install('global-resource', 'global-resource.control', resource_source, { lifecycle: {
		drain: { service: 'global-resource.control', method: 'drain' }, resume: { service: 'global-resource.control', method: 'resume' } } });
	install('global-consumer', 'global-consumer.control', "return function(ctx) { return { inspect: () => ctx.use('global-resource.control').inspect() }; };", {
		services: { 'global-consumer.control': { version: 1, module: 'lib/main.uc', requires: { 'global-resource.control': 1 } } },
		actions: { inspect: { service: 'global-consumer.control', method: 'inspect', access: 'read' } } });
	profile.enabled['global-consumer'] = false;
	install('shared-provider', 'shared-provider.value', 'return function(ctx) { return { inspect: () => ({ ok: true, result: { instance: ctx.instance } }) }; };', {
		actions: { inspect: { service: 'shared-provider.value', method: 'inspect', access: 'read' } } });
	install('shared-consumer', 'shared-consumer.control', "return function(ctx) { return { inspect: () => ctx.use('shared-provider.value').inspect() }; };", {
		services: { 'shared-consumer.control': { version: 1, module: 'lib/main.uc', requires: { 'shared-provider.value': 1 } } },
		actions: { inspect: { service: 'shared-consumer.control', method: 'inspect', access: 'read' } } });
	profile.enabled['shared-consumer'] = false;
	profile.instances.blue = { enabled: { 'shared-consumer': true } };
	write(adapter.paths.default_system, profile);

	let result = request({ id: 'echo', action: 'inspect', params: { step: 2, text: 'payload' } });
	check(result.ok && result.result.params.text == 'payload' && result.result.count == 2 && result.result.config.label == 'base', 'declared read action receives parameters and injected configuration');
	check(join(',', states.echo.cleanups) == 'child,service' && states.echo.events == 1, 'successful action releases factory child scope and event resources');
	result = request({ id: 'echo', action: 'update', params: { step: 50 } });
	check(result.error == 'plugin_action_not_allowed' && states.echo.writes == null && states.echo.count == 2, 'read admission cannot invoke a write action');
	result = request({ id: 'echo', action: 'update', confirm: true, revision: sprintf('%064d', 0) }, 'plugin-call');
	check(result.error == 'plugin_confirmation_or_revision_required' && states.echo.writes == null, 'stale revision is rejected before executing a write');
	result = change('echo', 'update', { step: 3 });
	check(result.ok && result.result.count == 5 && states.echo.writes == 1, 'confirmed action executes with current code revision');
	const disabled = clone(profile); disabled.enabled.echo = false;
	result = request({ id: 'echo', action: 'inspect' }, null, { system: disabled });
	check(result.error == 'plugin_disabled:echo' && states.echo.count == 5, 'disabled plugin cannot execute declared actions');
	const rebound = clone(profile); rebound.bindings['echo.control'] = 'other';
	result = request({ id: 'echo', action: 'inspect' }, null, { system: rebound });
	check(result.error == 'plugin_action_provider_mismatch' && states.other == null, 'plugin action cannot invoke a different selected provider');
	result = request({ id: 'echo', action: 'inspect', instance: 'alpha', params: { step: 7 } });
	check(result.ok && result.result.instance == 'alpha' && result.result.count == 7 && result.result.config.label == 'alpha' && result.result.config.inherited == 'shared', 'named instance overlays plugin config while inheriting unspecified fields');
	result = request({ id: 'echo', action: 'inspect', instance: 'beta' });
	check(result.ok && result.result.count == 1 && result.result.config.label == 'beta' && states.echo.count == 5, 'named instances have independent state');
	result = request({ id: 'echo', action: 'inspect', instance: 'alpha' });
	check(result.ok && result.result.count == 8 && states.__instances.beta.echo.count == 1, 'repeat invocation retains only its selected instance state');
	check(request({ id: 'echo', action: 'inspect', instance: 'unknown' }).error == 'plugin_instance_unknown', 'requests cannot create an undeclared instance');
	const failed_factory = clone(profile); failed_factory.config.echo.fail_factory = true;
	let cleanup_count = length(states.echo.cleanups);
	check(request({ id: 'echo', action: 'inspect' }, null, { system: failed_factory }).error == 'fixture_factory_failed' &&
		length(states.echo.cleanups) == cleanup_count + 2, 'failed factory releases already registered resources');
	cleanup_count = length(states.echo.cleanups);
	check(request({ id: 'echo', action: 'fail' }).error == 'fixture_action_failed' && length(states.echo.cleanups) == cleanup_count + 2,
		'failed business action still disposes its complete service scope');

	let page = row('ui-panel');
	check(page.state == 'unavailable' && page.reason == 'plugin_disabled', 'installed UI-only plugin is discovered before loading');
	check(change('ui-panel', 'load').ok, 'UI-only plugin loads through the existing plugin lifecycle');
	page = row('ui-panel');
	check(page.state == 'available' && page.ui[0].module == 'resources/page.js' && !length(page.services), 'loaded UI contribution is projected without a backend service');
	check(length(page.ui) == 2 && length(row('ui-panel', 'alpha').ui) == 1 && row('ui-panel', 'alpha').ui[0].id == 'panel',
		'host UI contributions are excluded from named instances while instance pages remain');
	const old_page_revision = page.revision;
	write(`${root}/plugins/ui-panel/resources/page.js`, 'export function mount(context) { return () => {}; }\n');
	check(row('ui-panel').revision != old_page_revision, 'UI module replacement produces a new inventory revision');

	const note = row('workspace-note');
	result = request({ id: note.id, action: note.configuration.read });
	check(result.ok && result.result.generation == 0, 'external example configuration read reaches its service action');
	result = change(note.id, note.configuration.write, { title: 'Saved note', text: 'configuration body', generation: 0 });
	check(result.ok && result.result.generation == 1 && read(`${root}/state/note.json`).text == 'configuration body', 'external configuration action persists and reads back its own document');
	const saved_note = fs.readfile(`${root}/state/note.json`);
	result = change(note.id, note.configuration.write, { title: 'Stale note', text: 'stale', generation: 0 });
	check(result.error == 'configuration_conflict' && fs.readfile(`${root}/state/note.json`) == saved_note, 'plugin rejects stale configuration without changing persisted data');
	result = change(note.id, note.configuration.write, { title: 'Alpha note', text: 'private instance', generation: 0 }, 'alpha');
	check(result.ok && read(`${root}/state/alpha-note.json`).text == 'private instance', 'same external plugin persists a named instance configuration');
	result = request({ id: note.id, action: note.configuration.read, instance: 'beta' });
	check(result.ok && result.result.generation == 0 && fs.readfile(`${root}/state/note.json`) == saved_note, 'another instance and default document remain independent');
	check(!length(filter(fs.lsdir(`${root}/state`), name => index(name, '.json.') >= 0)), 'configuration save leaves no transaction directories');

	const host_resource_profile = clone(profile); host_resource_profile.enabled['global-consumer'] = true;
	check(request({ id: 'global-consumer', action: 'inspect' }, null, { system: host_resource_profile }).ok, 'host-scoped resource remains usable in the default instance');
	check(request({ id: 'global-consumer', action: 'inspect', instance: 'alpha' }, null, { system: host_resource_profile }).error == 'plugin_resource_scope_required:global-resource',
		'named dependency graph rejects a resource without instance lifecycle ownership');
	write(`${root}/state/resource-alpha.json`, { running: true, drains: 0, resumes: 0 });
	write(`${root}/state/resource-beta.json`, { running: false, drains: 0, resumes: 0 });
	const alpha = create(root, { ...options, instance: 'alpha' }), beta = create(root, { ...options, instance: 'beta' });
	push(held_hosts, alpha, beta);
	alpha.use('resource.control'); beta.use('resource.control');
	lease = fs.open(`${root}/locks/resource.lock`, 'ae', 0600);
	check(lease != null && !lease.lock('xn'), 'both instances hold shared leases for the same package');
	result = package_action('drain', 'resource');
	check(result.error == 'plugin_calls_draining' && !resource_state('alpha').running && !resource_state('beta').running,
		'package drain stops named resources but replacement waits for in-flight instances');
	check(resource_state('alpha').drains == 1 && resource_state('beta').drains == 1 && fs.lstat(`${root}/state/resource-default.json`) == null,
		'only enabled named resource owners are drained');
	alpha.release();
	check(!lease.lock('xn'), 'releasing one instance does not admit package replacement while another is live');
	check(package_action('drain', 'resource').error == 'plugin_calls_draining' && resource_state('alpha').drains == 1 && resource_state('beta').drains == 1,
		'drain retry preserves each resource handoff without duplicate drain');
	beta.release();
	check(lease.lock('xn'), 'final instance release admits the shared package replacement');
	lease.close(); lease = null;
	check(package_action('drain', 'resource').ok, 'package drain succeeds after every instance releases its code');
	check(package_action('resume', 'resource').ok, 'package resume returns each named owner its saved state');
	check(resource_state('alpha').running && !resource_state('beta').running && resource_state('alpha').resumes == 1 && resource_state('beta').resumes == 1,
		'named resources resume independently without exchanging their state');
	check(fs.lstat(`${root}/maintenance/resource`) == null && !length(fs.lsdir(`${root}/maintenance/.resources`)),
		'completed package transaction removes shared markers and instance handoffs');

	check(change('shared-provider', 'unload').error == 'plugin_required_by:shared-consumer',
		'default unload cannot disable an inherited provider used by a named instance');
	result = request({ id: 'shared-consumer', action: 'inspect', instance: 'blue' });
	check(result.ok && result.result.instance == 'blue', 'rejected unload preserves the named consumer');
	profile.instances.blue.enabled['shared-provider'] = true;
	write(adapter.paths.default_system, profile);
	check(change('shared-provider', 'unload').ok, 'explicit named enablement permits disabling the default provider');
	check(request({ id: 'shared-provider', action: 'inspect' }).error == 'plugin_disabled:shared-provider', 'successful unload disables the default instance');
	result = request({ id: 'shared-consumer', action: 'inspect', instance: 'blue' });
	check(result.ok && result.result.instance == 'blue', 'default unload preserves an explicitly enabled named provider and its consumer');
} catch (error) {
	for (let host in held_hosts) try { host.release(); } catch (cleanup_error) {}
	lease?.close(); remove(root); die(`${error.message}\n${error.stacktrace?.[0]?.context ?? ''}`);
}
remove(root);
printf('composition contract: %d assertions passed\n', assertions);
