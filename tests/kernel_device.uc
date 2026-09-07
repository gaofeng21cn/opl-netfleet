#!/usr/bin/ucode
import * as fs from 'fs';

let assertions = 0;
function check(value, message) { if (!value) die(message); assertions++; };
function q(value) { return "'" + replace('' + value, /'/g, "'\\''") + "'"; };
check(fs.stat('/proc/self')?.uid == 0, 'kernel device tests require Linux root');
const source = fs.realpath(`${sourcepath(0, true)}/../openwrt/files/usr/libexec/opl-netfleet/kernel/host.uc`) ??
	'/usr/libexec/opl-netfleet/kernel/host.uc';
check(fs.stat(source)?.type == 'file', 'kernel host source exists');
const root = fs.mkdtemp('/tmp/netfleet-kernel-device.XXXXXX');
check(root != null, 'private test root created');
let lease, network;
function directory(path) { check(fs.mkdir(path, 0700), `mkdir ${path}`); };
function write(path, value) {
	const text = type(value) == 'string' ? value : sprintf('%J', value);
	check(fs.writefile(path, text) == length(text) && fs.chmod(path, 0600), `write ${path}`);
};
function read(path) { try { return json(fs.readfile(path)); } catch (error) { return null; } };
function remove(path) {
	if (fs.lstat(path)?.type == 'directory') {
		for (let name in fs.lsdir(path) ?? []) remove(`${path}/${name}`);
		fs.rmdir(path);
	} else fs.unlink(path);
};
for (let name in ['plugins', 'locks', 'maintenance', 'state']) directory(`${root}/${name}`);
const profile = { schema: 'opl-netfleet-system.v1', bindings: {}, enabled: {} };
const runner = `${root}/runner.uc`, override = `${root}/override.json`;
write(runner, sprintf('import { run } from %J;\n', source) +
	"import * as fs from 'fs';\n" + sprintf('const root = %J;\n', root) +
	"let profile = json(fs.readfile(root + '/profile.json'));\n" +
	"const settings = fs.lstat(root + '/options.json') == null ? {} : json(fs.readfile(root + '/options.json'));\n" +
	"const override = settings.override_path ?? root + '/override.json';\n" +
	"const overlay = fs.lstat(override) == null ? null : json(fs.readfile(override));\n" +
	"if (overlay != null) profile = { ...profile, ...overlay, bindings: { ...profile.bindings, ...overlay.bindings }, enabled: { ...profile.enabled, ...overlay.enabled } };\n" +
	"run(ARGV, root, { system: profile, override_path: override, lock_root: root + '/locks', maintenance_root: root + '/maintenance', network_lock: root + '/network.lock' });\n");

function plugin(id, requires, resource, enabled, service) {
	service = service ?? `${id}.control`;
	directory(`${root}/plugins/${id}`); directory(`${root}/plugins/${id}/lib`);
	const manifest = { schema: 'opl-netfleet-service-plugin.v1', id: id, label: id, version: '1.0.0', api_version: 1,
		package: `opl-netfleet-plugin-${id}`, services: { [service]: { version: 1, module: 'lib/main.uc', requires: requires } }, commands: {} };
	if (resource) manifest.lifecycle = { drain: { service: service, method: 'drain' }, resume: { service: service, method: 'resume' } };
	write(`${root}/plugins/${id}/manifest.json`, manifest);
	let code = "import * as fs from 'fs';\nreturn function(context) {\n";
	for (let dependency in keys(requires)) code += sprintf('context.use(%J);\n', dependency);
	code += "const path = context.root + '/state/' + context.id;\n" +
		"function read() { return json(fs.readfile(path + '.json')); };\n" +
		"function save(value) { fs.writefile(path + '.json', sprintf('%J', value)); };\n" +
		"function log(action) { const file = fs.open(context.root + '/events', 'a'); file.write(action + ':' + context.id + '\\n'); file.close(); };\n" +
		"function drain(saved) {\n" +
		" const state = read(); const previous = fs.lstat(path + '.intent') == null ? (saved ?? { running: state.running }) : json(fs.readfile(path + '.intent'));\n" +
		" fs.writefile(path + '.intent', sprintf('%J', previous)); state.running = false; state.drains++; save(state); log('drain');\n" +
		" if (fs.lstat(path + '.fail-drain') != null) return { ok: false, error: 'fixture_drain_failed' };\n" +
		" return { ok: true, result: previous };\n};\n" +
		"function resume(saved) {\n" +
		" const state = read(); const previous = saved ?? (fs.lstat(path + '.intent') == null ? { running: state.running } : json(fs.readfile(path + '.intent')));\n" +
		" state.running = previous.running; state.resumes++; save(state); log('resume');\n" +
		" if (fs.lstat(path + '.throw-resume') != null) die('fixture_resume_threw');\n" +
		" if (fs.lstat(path + '.fail-resume') != null) return { ok: false, error: 'fixture_resume_failed' };\n" +
		" fs.unlink(path + '.intent'); return { ok: true, result: state };\n};\n" +
		"return { read: () => read(), drain: drain, resume: resume };\n};\n";
	write(`${root}/plugins/${id}/lib/main.uc`, code);
	write(`${root}/state/${id}.json`, { running: resource, drains: 0, resumes: 0 });
	profile.enabled[id] = enabled;
	if (enabled) profile.bindings[service] = id;
	write(`${root}/profile.json`, profile);
};
function invoke(argv) {
	const pipe = fs.popen(`ucode ${q(runner)} ${join(' ', map(argv, q))} 2>${q(`${root}/stderr`)}`);
	check(pipe != null, 'start isolated host process');
	const output = pipe.read('all'), status = pipe.close();
	let response;
	try { response = json(output); } catch (error) { die(`host output invalid: ${output}; ${fs.readfile(`${root}/stderr`)}`); }
	check(type(response.ok) == 'bool' && status == (response.ok ? 0 : 1), 'host response agrees with process exit');
	return response;
};
function revision(id) {
	const listing = invoke(['plugins-list']);
	check(listing.ok, 'inventory succeeds');
	const item = filter(listing.result.plugins, entry => entry.id == id)[0];
	check(type(item?.revision) == 'string', `revision for ${id}`);
	return item.revision;
};
function call(id, action) {
	const request = `${root}/request.json`;
	write(request, { request: { id: id, action: action, revision: revision(id), confirm: true } });
	return invoke([action == 'get' ? 'plugin-read' : 'plugin-call', request]);
};
function package_call(action, id) { return invoke([`plugin-package-${action}`, id]); };
function state(id) { return read(`${root}/state/${id}.json`); };
function fault(id, name, enabled) {
	const path = `${root}/state/${id}.${name}`;
	if (enabled) write(path, '1'); else fs.unlink(path);
};
function events() { return split(trim(fs.readfile(`${root}/events`) ?? ''), '\n'); };
function ordered(expected, message) { check(sprintf('%J', events()) == sprintf('%J', expected), `${message}: ${sprintf('%J', events())}`); };

try {
	write(`${root}/profile.json`, profile);
	directory(`${root}/plugins/independent`);
	const independent = { schema: 'opl-netfleet-plugin.v1', id: 'independent', label: 'Independent process',
		version: '1.0.0', api_version: 1, package: 'opl-netfleet-plugin-independent',
		dependencies: [], backends: [], permissions: ['diagnostics'], actions: {} };
	write(`${root}/plugins/independent/manifest.json`, independent);
	write(`${root}/plugins/independent/control`, '#!/usr/bin/env ucode\n' +
		"import * as fs from 'fs';\n" + sprintf('const state = %J;\n', `${root}/state/process-loaded`) +
		"if (ARGV[0] == 'load') fs.writefile(state, '1');\n" +
		"if (ARGV[0] == 'unload') fs.unlink(state);\n" +
		"printf('%J\\n', {ok:true,result:{loaded:fs.lstat(state)!=null,ready:fs.lstat(state)!=null}});\n");
	check(fs.chmod(`${root}/plugins/independent/control`, 0700), 'process control is executable');
	check(call('independent', 'load').result.ready == true, 'kernel-only process loads without a backend service');
	check(call('independent', 'reload').result.ready == true, 'kernel-only process reloads');
	check(call('independent', 'unload').result.loaded == false, 'kernel-only process unloads');
	independent.backends = ['custom-backend'];
	write(`${root}/plugins/independent/manifest.json`, independent);
	check(call('independent', 'load').error == 'plugin_backend_unsupported', 'backend-bound process still requires its environment');
	check(call('independent', 'get').ok && call('independent', 'unload').ok, 'backend absence preserves inspection and exit');
	remove(`${root}/plugins/independent`);

	plugin('scratch', {}, false, false);
	check(call('scratch', 'get').result.loaded == false, 'new service starts disabled');
	check(call('scratch', 'load').result.ready == true, 'public load establishes a service binding');
	check(read(override).bindings['scratch.control'] == 'scratch', 'load persists explicit binding');
	check(call('scratch', 'reload').result.loaded == true, 'public reload succeeds');
	check(call('scratch', 'unload').result.loaded == false, 'public unload disables service');
	check(call('scratch', 'get').result.loaded == false, 'disabled state survives a new process');
	check(call('scratch', 'load').ok, 'disabled service can load again');
	plugin('impostor', {}, false, false, 'scratch.control');
	check(call('impostor', 'load').error == 'plugin_binding_conflict:scratch.control', 'load cannot steal an existing service binding');

	lease = fs.open(`${root}/locks/scratch.lock`, 'ae', 0600);
	check(lease != null && lease.lock('sn'), 'separate process holds real shared code lease');
	let result = call('scratch', 'reload');
	check(result.error == 'plugin_calls_draining' && result.rollback?.ok == true, 'busy public reload rolls back its maintenance state');
	check(fs.lstat(`${root}/maintenance/scratch`) == null, 'busy reload does not strand a marker');
	check(call('scratch', 'get').result.ready, 'existing code remains callable after busy reload');
	lease.close(); lease = null;
	check(call('scratch', 'reload').ok, 'public reload succeeds after lease release');
	network = fs.open(`${root}/network.lock`, 'ae', 0600);
	check(network != null && network.lock('xn'), 'parent updater holds real exclusive network lock');
	check(call('scratch', 'reload').ok, 'verified ancestor lock admits its own child operation');
	network.close(); network = null;

	plugin('p-one', {}, false, true);
	plugin('p-two', {}, false, true);
	plugin('z-base', { 'p-one.control': 1, 'p-two.control': 1 }, true, true);
	plugin('a-dependent', { 'z-base.control': 1 }, true, true);
	check(index(['plugin_required_by:z-base', 'plugin_required_by:a-dependent'], call('p-one', 'unload').error) >= 0,
		'public unload rejects enabled reverse dependencies');
	write(`${root}/events`, '');
	check(package_call('drain', 'p-one').ok, 'first package drain succeeds');
	ordered(['drain:a-dependent', 'drain:z-base'], 'resource consumers drain before providers despite their names');
	check(!state('z-base').running && !state('a-dependent').running, 'both resource owners stop');
	check(package_call('drain', 'p-two').ok && package_call('drain', 'p-one').ok, 'overlapping and repeated package drains succeed');
	ordered(['drain:a-dependent', 'drain:z-base'], 'shared resources drain once across package blockers');
	check(package_call('resume', 'p-one').ok, 'first blocker can complete');
	check(!state('z-base').running && !state('a-dependent').running, 'remaining blocker keeps shared resources stopped');
	check(package_call('resume', 'p-two').ok, 'last blocker restores shared owners');
	ordered(['drain:a-dependent', 'drain:z-base', 'resume:z-base', 'resume:a-dependent'], 'providers resume before consumers');
	check(state('z-base').running && state('a-dependent').running, 'shared owners return to saved state');

	const original_override = fs.readfile(override);
	write(`${root}/options.json`, { override_path: `${root}/absent/override.json` });
	result = call('p-one', 'reload');
	check(result.error == 'plugin_system_write_failed' && result.rollback?.ok, 'configuration write failure restores drained resources');
	check(state('z-base').running && state('a-dependent').running && fs.lstat(`${root}/maintenance/p-one`) == null,
		'failed configuration write leaves original owners available');
	check(fs.readfile(override) == original_override, 'configuration failure preserves original private settings');
	fs.unlink(`${root}/options.json`);

	fault('a-dependent', 'fail-drain', true);
	result = call('p-one', 'reload');
	check(result.error == 'fixture_drain_failed' && result.rollback?.ok, 'public lifecycle compensates a partially failed drain');
	check(state('a-dependent').running && fs.lstat(`${root}/maintenance/p-one`) == null, 'failed public drain restores owner and admission');
	fault('a-dependent', 'fail-drain', false);
	check(call('p-one', 'reload').ok, 'public operation remains retryable after drain failure');

	check(package_call('drain', 'p-one').ok, 'prepare exception during resume');
	fault('z-base', 'throw-resume', true);
	check(package_call('resume', 'p-one').error == 'fixture_resume_threw', 'resume factory exception is reported');
	check(read(`${root}/maintenance/p-one/state.json`)?.drained != null, 'resume exception preserves durable owner record');
	check(read(`${root}/maintenance/p-one/replacing`)?.phase == 'resume_failed', 'resume exception leaves explicit retry phase');
	fault('z-base', 'throw-resume', false);
	check(package_call('resume', 'p-one').ok, 'resume can retry after exception');
	check(state('z-base').running && state('a-dependent').running, 'exception retry restores every owner');

	check(package_call('drain', 'p-one').ok, 'prepare unsuccessful resume with partially restarted owner');
	fault('z-base', 'fail-resume', true);
	check(package_call('resume', 'p-one').error == 'fixture_resume_failed', 'partial resume fails explicitly');
	check(state('z-base').running, 'fixture models a resource started before resume failure');
	const drains_before = state('z-base').drains;
	lease = fs.open(`${root}/locks/p-one.lock`, 'ae', 0600);
	check(lease != null && lease.lock('sn'), 'hold generation while retrying failed resume');
	check(package_call('drain', 'p-one').error == 'plugin_calls_draining', 'resume_failed cannot bypass the exclusive generation check');
	check(!state('z-base').running && state('z-base').drains > drains_before, 'failed resume is drained again before replacement');
	lease.close(); lease = null;
	fault('z-base', 'fail-resume', false);
	check(package_call('drain', 'p-one').ok && package_call('resume', 'p-one').ok, 'replacement retry completes after generation release');
	check(state('z-base').running && state('a-dependent').running, 'replacement retry retains original resource intent');
	check(fs.lstat(`${root}/maintenance/p-one`) == null && length(fs.lsdir(`${root}/maintenance/.resources`) ?? []) == 0,
		'completed lifecycle removes all owned handoff records');
} catch (error) {
	lease?.close(); network?.close();
	warn(`kernel device failure; isolated artifacts retained at ${root}\n`);
	die(error.message);
}
remove(root);
printf('kernel device: %d assertions passed\n', assertions);
