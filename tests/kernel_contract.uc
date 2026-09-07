#!/usr/bin/ucode
import * as fs from 'fs';
import { create } from '../openwrt/files/usr/libexec/opl-netfleet/kernel/host.uc';
import { create as create_adapter } from '../openwrt/files/usr/libexec/opl-netfleet/adapters/openwrt.uc';

let assertions = 0;
function check(value, message) { if (!value) die(message); assertions++; };
function rejects(callback, expected) {
	try { callback(); } catch (error) { check(index(error.message, expected) >= 0, `${expected}: ${error.message}`); return; }
	die(`expected ${expected}`);
};
const root = fs.mkdtemp('/tmp/netfleet-kernel-test.XXXXXX');
const paths = [];
function directory(path) { check(fs.mkdir(path, 0700), `mkdir ${path}`); push(paths, path); };
function write(path, value) { check(fs.writefile(path, value), `write ${path}`); fs.chmod(path, 0600); if (index(paths, path) < 0) push(paths, path); };
directory(`${root}/plugins`); directory(`${root}/locks`); directory(`${root}/maintenance`);
const profile = { schema: 'opl-netfleet-system.v1', bindings: {}, enabled: {} };
function plugin(id, service, requires, source) {
	directory(`${root}/plugins/${id}`); directory(`${root}/plugins/${id}/lib`);
	const manifest = { schema: 'opl-netfleet-service-plugin.v1', id: id, label: id, version: '1.0.0', api_version: 1,
		package: `opl-netfleet-plugin-${id}`, services: { [service]: { version: 1, module: 'lib/main.uc', requires: requires } }, commands: {} };
	write(`${root}/plugins/${id}/manifest.json`, sprintf('%J', manifest));
	write(`${root}/plugins/${id}/lib/main.uc`, source);
	profile.enabled[id] = true; profile.bindings[service] = id;
};
function host(system) { return create(root, { adapter: create_adapter(), trusted_owner: fs.stat(root).uid, system: system ?? profile,
	lock_root: `${root}/locks`, maintenance_root: `${root}/maintenance` }); };
function cleanup() {
	for (let path in reverse(paths)) { if (fs.lstat(path)?.type == 'directory') fs.rmdir(path); else fs.unlink(path); }
	for (let name in fs.lsdir(`${root}/locks`) ?? []) fs.unlink(`${root}/locks/${name}`);
	fs.rmdir(`${root}/locks`); fs.rmdir(root);
};
try {
	plugin('provider', 'demo.value', {}, 'return function(ctx) { return { read: () => 1 }; };');
	plugin('consumer', 'demo.consumer', { 'demo.value': 1 }, "return function(ctx) { const dependency = ctx.use('demo.value'); return { read: () => dependency.read() + 1 }; };");
	let first = host();
	check(first.use('demo.consumer').read() == 2, 'declared dependency resolved');
	const revision = first.inventory()[0].revision;
	write(`${root}/plugins/provider/lib/main.uc`, 'return function(ctx) { return { read: () => 8 }; };');
	check(first.use('demo.consumer').read() == 2, 'in-flight context preserves old generation');
	const second = host(); check(second.use('demo.consumer').read() == 9, 'new context reads changed implementation');
	second.release(); first.release();
	rejects(() => first.use('demo.consumer'), 'plugin_context_closed');
	const incompatible = host(); rejects(() => incompatible.use('demo.value', 2), 'plugin_service_incompatible'); incompatible.release();
	const missing = host({ ...profile, bindings: { 'demo.consumer': 'consumer' } });
	rejects(() => missing.use('demo.consumer'), 'plugin_service_unbound'); missing.release();
	write(`${root}/plugins/consumer/lib/main.uc`, "return function(ctx) { return ctx.use('demo.undeclared'); };");
	const undeclared = host(); rejects(() => undeclared.use('demo.consumer'), 'plugin_dependency_undeclared'); undeclared.release();
	const path = `${root}/plugins/provider/manifest.json`, manifest = json(fs.readfile(path));
	manifest.services['demo.value'].requires['demo.consumer'] = 1; write(path, sprintf('%J', manifest));
	const cyclic = host(); rejects(() => cyclic.use('demo.value'), 'plugin_dependency_cycle'); cyclic.release();
	delete manifest.services['demo.value'].requires['demo.consumer']; write(path, sprintf('%J', manifest));
	write(`${root}/plugins/provider/lib/main.uc`, "die('inventory must not execute this factory');");
	const metadata = host(); check(length(metadata.inventory()) == 2, 'inventory is metadata only'); metadata.release();
	directory(`${root}/maintenance/provider`);
	const blocked = host(); rejects(() => blocked.use('demo.value'), 'plugin_package_maintenance'); blocked.release();
	fs.rmdir(`${root}/maintenance/provider`);
	write(`${root}/plugins/provider/lib/main.uc`, 'return function(ctx) { return { read: () => 3 }; };');
	const running = host(); running.use('demo.value');
	const exclusive = fs.open(`${root}/locks/provider.lock`, 'ae', 0600);
	check(!exclusive.lock('xn'), 'package replacement waits for in-flight call');
	running.release(); check(exclusive.lock('xn'), 'call release admits replacement');
	const busy = host(); rejects(() => busy.use('demo.value'), 'plugin_code_busy'); busy.release();
	exclusive.close();
	write(`${root}/plugins/provider/lib/main.uc`, "import { value } from './value.uc'; return function(ctx) { return { read: () => value }; };");
	write(`${root}/plugins/provider/lib/value.uc`, 'export const value = 13;');
	const before = host(); check(before.use('demo.value').read() == 13, 'private dependency loaded');
	write(`${root}/plugins/provider/lib/value.uc`, 'export const value = 21;');
	const after = host(); check(after.use('demo.value').read() == 21, 'private dependency hot replacement');
	check(before.use('demo.value').read() == 13, 'old dependency retained for in-flight context'); before.release(); after.release();
} catch (error) { cleanup(); die(error.message); }
cleanup();
printf('kernel contract: %d assertions passed\n', assertions);
