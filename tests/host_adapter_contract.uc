#!/usr/bin/ucode
import * as fs from 'fs';
import { create, execute, run, tick } from '../openwrt/files/usr/libexec/opl-netfleet/kernel/host.uc';
import { invoke, lifecycle } from '../openwrt/files/usr/libexec/opl-netfleet/kernel/process.uc';
import { trusted, atomic_json, shell_quote as q } from '../openwrt/files/usr/libexec/opl-netfleet/kernel/io.uc';
import { create as create_openwrt } from '../openwrt/files/usr/libexec/opl-netfleet/adapters/openwrt.uc';

let assertions = 0;
function check(value, message) { if (!value) die(message); assertions++; };
function rejects(callback, expected) {
	try { callback(); } catch (error) { check(index(error.message, expected) >= 0, `${expected}: ${error.message}`); return; }
	die(`expected ${expected}`);
};
const root = fs.realpath(fs.mkdtemp('/tmp/netfleet-host-adapter.XXXXXX'));
check(root != null, 'isolated adapter test directory');
const owner = fs.stat(root).uid;
const revision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
let locked = false, loaded = false, private_checks = 0, digest_checks = 0, package_checks = 0;
const calls = [];
function remove(path) {
	if (fs.lstat(path)?.type == 'directory') {
		for (let name in fs.lsdir(path) ?? []) remove(`${path}/${name}`);
		fs.rmdir(path);
	} else fs.unlink(path);
};
function write(path, value) {
	const text = type(value) == 'string' ? value : sprintf('%J', value);
	check(fs.writefile(path, text) == length(text) && fs.chmod(path, 0600), `write ${path}`);
};
function execution(value) { return { ok: true, output: sprintf('%J', value), status: 0, exit_status: '0' }; };
const adapter = {
	trusted_owner: owner,
	paths: { installed_root: root, default_system: `${root}/defaults.json`, override: `${root}/settings.json`,
		network_lock: `${root}/network.lock`, code_locks: `${root}/locks`, maintenance: `${root}/maintenance` },
	private_file: path => {
		private_checks++;
		return trusted(path, 'file', owner) && !(fs.lstat(path).mode & 077);
	},
	network_lock: (path, write) => {
		check(path == `${root}/network.lock` && !locked, 'adapter owns the network lock path and acquisition');
		locked = true; push(calls, write ? 'lock:write' : 'lock:read');
		return { close: () => { locked = false; push(calls, 'unlock'); } };
	},
	process_identity: () => ({ pid: 'fixture', parent: 'parent', start: 'generation' }),
	coordinator_parent: path => { check(path == `${root}/maintenance/.coordinator`, 'adapter coordinator path'); return false; },
	package_available: name => { check(locked && name == 'fixture-package', 'package query occurs under mutation admission'); package_checks++; return true; },
	inspect_digest: (directory, files) => {
		check(index(directory, `${root}/plugins/`) == 0 && length(files) == 2, 'adapter receives inspected plugin files');
		digest_checks++; return revision;
	},
	invoke_process: (entry, action, envelope, limit) => {
		check(locked && entry == `${root}/plugins/process/control`, 'process invocation uses admitted adapter');
		check(envelope.request.id == 'process' && envelope.request.api_version == 1 && envelope.request.action == action,
			'generic process protocol builds the request envelope');
		check(limit == 65536, 'generic protocol supplies response byte limit');
		push(calls, action);
		if (action == 'load') loaded = true;
		if (action == 'unload') loaded = false;
		return execution({ ok: true, result: { loaded: loaded, ready: loaded } });
	},
};
let host;
try {
	for (let directory in ['plugins', 'locks', 'maintenance', 'plugins/scheduler', 'plugins/scheduler/lib', 'plugins/process'])
		check(fs.mkdir(`${root}/${directory}`, 0700), `mkdir ${directory}`);
	write(`${root}/plugins/scheduler/manifest.json`, { schema: 'opl-netfleet-service-plugin.v1', id: 'scheduler', label: 'Scheduler',
		version: '1.0.0', api_version: 1, package: 'opl-netfleet-plugin-scheduler',
		services: { 'scheduler.tick': { version: 1, module: 'lib/main.uc', requires: {} } },
		commands: { 'scheduler-inspect': { service: 'scheduler.tick', method: 'inspect', access: 'read' } } });
	write(`${root}/plugins/scheduler/lib/main.uc`, 'return function(ctx) { return { inspect: () => ({ ok: true }), tick: state => ({ delay_ms: 321, state: { count: (state.count ?? 0) + 1 } }) }; };');
	write(`${root}/plugins/process/manifest.json`, { schema: 'opl-netfleet-plugin.v1', id: 'process', label: 'Process',
		version: '1.0.0', api_version: 1, package: 'opl-netfleet-plugin-process', dependencies: ['fixture-package'],
		backends: [], permissions: ['diagnostics'], actions: { inspect: 'read' } });
	write(`${root}/plugins/process/control`, '#!/bin/sh\nexit 99\n');
	check(fs.chmod(`${root}/plugins/process/control`, 0700), 'fixture control marked executable');
	write(adapter.paths.default_system, { schema: 'opl-netfleet-system.v1', bindings: { 'scheduler.tick': 'scheduler' },
		enabled: { scheduler: true }, scheduler: { service: 'scheduler.tick', method: 'tick' } });

	rejects(() => create(root), 'plugin_host_adapter_required');
	check(!trusted(root, 'directory'), 'generic trust checks have no implicit operating system owner');
	host = create(root, { adapter: adapter });
	check(host.call('scheduler.tick', 'tick', {}).state.count == 1, 'host resolves a service using only injected paths and owner');
	check(host.inventory()[0].revision == revision, 'host uses adapter code identity');
	host.release(); host = null;
	const states = {};
	check(tick(root, states, { adapter: adapter }) == 321 && states.scheduler.count == 1 && !locked,
		'scheduler uses injected network lock and releases it');
	check(tick(root, states, { adapter: adapter }) == 321 && states.scheduler.count == 2,
		'scheduler preserves plugin state through adapter-backed calls');
	const exclusive = fs.open(`${root}/locks/scheduler.lock`, 'ae', 0600);
	check(exclusive != null && exclusive.lock('xn'), 'simulate installed code being replaced');
	try {
		check(execute(['scheduler-inspect'], root, { adapter }).error == 'plugin_code_busy:scheduler',
			'installed service cannot enter during exclusive code replacement');
		const snapshot_adapter = { ...adapter, paths: { ...adapter.paths, installed_root: `${root}/installed` } };
		check(execute(['scheduler-inspect'], root, { adapter: snapshot_adapter }).ok == true,
			'private updater snapshot does not acquire installed code leases after option normalization');
		check(execute(['scheduler-inspect'], root, { adapter: snapshot_adapter, lock_root: `${root}/locks` }).error == 'plugin_code_busy:scheduler',
			'explicit snapshot code locks remain effective through dispatch');
		check(tick(root, {}, { adapter: snapshot_adapter }) == 321,
			'snapshot scheduler keeps default code locks separate from installed code');
	} catch (error) { exclusive.close(); die(error.message); }
	exclusive.close();

	const request = `${root}/request.json`;
	write(request, { request: { id: 'process', action: 'load', revision: revision, confirm: true } });
	run(['plugin-call', request], root, { adapter: adapter });
	check(loaded && !locked && private_checks > 0 && package_checks == 1, 'write dispatch uses injected trust, packages and process');
	check(fs.lstat(`${root}/maintenance/.coordinator`) == null, 'write dispatch removes its coordinator after completion');
	write(request, { request: { id: 'process', action: 'inspect' } });
	run(['plugin-read', request], root, { adapter: adapter });
	check(index(calls, 'lock:read') >= 0 && index(calls, 'inspect') >= 0 && !locked, 'read dispatch uses the same adapter contract');
	check(digest_checks > 0, 'adapter code inspection was exercised');

	const found = { entry: 'native-process-entry', revision: revision, manifest: { id: 'sample' } };
	function transport(result) { return { invoke_process: () => result }; };
	check(invoke(found, 'inspect', {}, transport({ ok: false, error: 'plugin_timeout' })).error == 'plugin_timeout',
		'platform timeout reaches generic protocol');
	check(invoke(found, 'inspect', {}, transport({ ok: true, output: 'invalid', status: 0, exit_status: '0' })).error == 'plugin_response_invalid',
		'generic protocol rejects malformed platform output');
	check(invoke(found, 'inspect', {}, transport({ ...execution({ ok: true, result: {} }), exit_status: '9' })).error == 'plugin_action_failed',
		'generic protocol rejects failed process exit despite valid response');
	check(invoke(found, 'get', {}, transport(execution({ ok: true, result: {} }))).error == 'plugin_status_invalid',
		'generic protocol validates lifecycle state');
	check(invoke(found, 'inspect', {}, transport({ ok: true, output: sprintf('%065537d', 0), status: 0, exit_status: '0' })).error == 'plugin_response_invalid',
		'generic protocol enforces output limit independently of platform');
	const recovery_calls = [];
	const recovery = { invoke_process: (entry, action) => {
		push(recovery_calls, action);
		return execution({ ok: true, result: { loaded: false, ready: false } });
	} };
	check(lifecycle(found, 'load', {}, recovery).error == 'plugin_load_failed_rolled_back' &&
		join(',', recovery_calls) == 'load,get,unload,get', 'generic lifecycle verifies load and rollback through injected transport');

	const openwrt = create_openwrt();
	check(openwrt.trusted_owner == 0 && openwrt.paths.installed_root == '/usr/libexec/opl-netfleet', 'OpenWrt adapter owns platform defaults');
	const source = `${root}/identity.txt`;
	write(source, 'payload\n');
	const pipe = fs.popen(`cd ${q(root)} && sha256sum identity.txt | sha256sum`);
	const expected = substr(trim(pipe.read('all')), 0, 64);
	check(pipe.close() == 0 && openwrt.inspect_digest(root, [source]) == expected, 'OpenWrt digest preserves installed plugin revisions');
	check(openwrt.inspect_digest(root, [source, `${root}/missing`]) == null, 'partial file digest failure cannot produce a plugin revision');
	check(atomic_json(`${root}/record.json`, { ok: true }), 'generic atomic JSON remains available without a platform owner');
} catch (error) { host?.release(); remove(root); die(error.message); }
remove(root);
printf('host adapter contract: %d assertions passed\n', assertions);
