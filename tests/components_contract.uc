#!/usr/bin/ucode
import * as fs from 'fs';
import { changes, validate, backoff_seconds, plan_auto_update } from '../plugins/components/lib/packages.uc';
import { manifest, composition } from '../plugins/components/lib/retained.uc';

function test_component_packages() {
	function check(value, message) { if (!value) die(message); }
	function rejects(action, code) {
		let actual; try { action(); } catch (error) { actual = error.message; }
		check(actual == code, 'expected ' + code + ', got ' + actual);
	}
	const name = 'opl-netfleet-plugin-example';
	const request = { action: 'install', name, version: '1.1.0', before_version: null, confirm: true };
	const installed = { 'opl-netfleet': '1.0.0', libc: '1.0' }, product = ['opl-netfleet-plugin-components'];
	const output = '(1/2) Installing helper (1.0)\n(2/2) Installing ' + name + ' (1.1.0)\nOK: 2 packages';
	const result = validate(changes(output), request, installed, product);
	check(length(result.names) == 2 && result.candidates.helper == '1.0', 'missing dependencies join the exact transaction');
	const padded = changes('( 1/12) Installing helper (1.0)\n(12/12) Upgrading ' + name + ' (1.0.0 -> 1.1.0)');
	check(length(padded) == 2 && padded[0].name == 'helper' && padded[1].version == '1.1.0', 'APK aligns counters for transactions with ten or more packages');
	rejects(() => changes('( 1/12) Changing example unexpectedly'), 'package_plan_unreadable');
	rejects(() => validate(changes(output), { ...request, confirm: false }, installed, product), 'invalid_plugin_package_request');
	rejects(() => validate(changes(output), request, { ...installed, [name]: '1.0.0' }, product), 'installed_version_changed');
	rejects(() => validate(changes('(1/2) Upgrading libc (1.0 -> 2.0)\n' + output), request, installed, product), 'plugin_dependency_change_required');
	rejects(() => validate(changes(output), { ...request, name: product[0] }, installed, product), 'plugin_package_protected');
	rejects(() => changes('(1/1) Changing example unexpectedly'), 'package_plan_unreadable');
	const update = { ...request, action: 'update', before_version: '1.0.0' };
	check(validate(changes('(1/1) Upgrading ' + name + ' (1.0.0 -> 1.1.0)'), update, { [name]: '1.0.0' }, []).candidates[name] == '1.1.0', 'exact update');
	rejects(() => validate(changes('(1/1) Downgrading ' + name + ' (2.0.0 -> 1.1.0)'), { ...update, before_version: '2.0.0' }, { [name]: '2.0.0' }, []), 'candidate_changed');
	const remove = { ...request, action: 'remove', before_version: '1.1.0' };
	check(validate(changes('(1/1) Purging ' + name + ' (1.1.0)'), remove, { [name]: '1.1.0' }, []).candidates[name] == null, 'remove exact plugin');
	rejects(() => validate(changes('(1/2) Purging downstream (1.0)\n(2/2) Purging ' + name + ' (1.1.0)'), remove, { [name]: '1.1.0' }, []), 'plugin_package_required');
	const required = 'opl-netfleet-plugin-components';
	const requiredUpdate = { ...update, name: required };
	check(validate(changes('(1/1) Upgrading ' + required + ' (1.0.0 -> 1.1.0)'), requiredUpdate, { [required]: '1.0.0' }, [required]).names[0] == required, 'required plugin supports independent update');
	rejects(() => validate(changes('(1/1) Purging ' + required + ' (1.1.0)'), { ...remove, name: required }, { [required]: '1.1.0' }, [required]), 'plugin_package_protected');
	const engine = 'example-native-engine', owner = { 'example-native-engine': 'example' };
	const engineRequest = { action: 'update', name: engine, version: '2.0.0', before_version: '1.0.0', confirm: true };
	const pair = '(1/2) Upgrading ' + name + ' (1.0.0 -> 1.1.0)\n(2/2) Upgrading ' + engine + ' (1.0.0 -> 2.0.0)';
	const pairPlan = validate(changes(pair), engineRequest, { [engine]: '1.0.0', [name]: '1.0.0' }, [], owner);
	check(length(pairPlan.names) == 2 && pairPlan.candidates[name] == '1.1.0', 'APK-required control upgrade follows runtime');
	rejects(() => validate(changes(pair), engineRequest, { [engine]: '1.0.0', [name]: '1.0.0' }, [], {}), 'plugin_package_protected');
	check(validate(changes('(1/1) Upgrading ' + engine + ' (1.0.0 -> 2.0.0)'), engineRequest, { [engine]: '1.0.0', [name]: '1.1.0' }, [], owner).names[0] == engine, 'compatible installed control is not reinstalled');
	rejects(() => validate(changes('(1/2) Upgrading opl-netfleet-kernel (1 -> 2)\n' + pair), engineRequest, { [engine]: '1.0.0', [name]: '1.0.0', 'opl-netfleet-kernel': '1' }, [], owner), 'plugin_dependency_change_required');
	const compat = 'opl-netfleet-https-compat', backend = 'opl-netfleet-plugin-mihomo';
	const compatRequest = { action: 'update', name: compat, version: '0.6.10', before_version: '0.6.9', confirm: true };
	const compatOwner = { [compat]: 'https-compat' }, compatInstalled = { [compat]: '0.6.9', [backend]: '0.9.9' };
	const closure = changes('(1/2) Upgrading ' + backend + ' (0.9.9 -> 0.9.10)\n(2/2) Upgrading ' + compat + ' (0.6.9 -> 0.6.10)');
	check(validate(closure, compatRequest, compatInstalled, [backend], compatOwner, true).candidates[backend] == '0.9.10', 'native HTTPS admits its installed backend dependency in one transaction');
	const nativeRequest = { action: 'update', name: backend, version: '0.9.11', before_version: '0.9.10', confirm: true };
	const nativeInstalled = { [backend]: '0.9.10', 'opl-netfleet': '0.9.7', 'opl-netfleet-plugin-network': '0.8.4' };
	const nativeClosure = changes('(1/3) Upgrading opl-netfleet (0.9.7 -> 0.9.10)\n(2/3) Upgrading opl-netfleet-plugin-network (0.8.4 -> 0.8.5)\n(3/3) Upgrading ' + backend + ' (0.9.10 -> 0.9.11)');
	check(length(validate(nativeClosure, nativeRequest, nativeInstalled, [], {}, true).names) == 3, 'native gateway update admits its required composition metadata and editor');
	rejects(() => validate(nativeClosure, nativeRequest, nativeInstalled, [], {}, false), 'plugin_dependency_change_required');
	rejects(() => validate(closure, compatRequest, compatInstalled, [backend], compatOwner, false), 'plugin_dependency_change_required');
	rejects(() => validate(closure, { ...compatRequest, name: engine, version: '2.0.0', before_version: '1.0.0' }, { ...compatInstalled, [engine]: '1.0.0' }, [backend], owner, true), 'plugin_dependency_change_required');
	rejects(() => validate(changes('(1/2) Installing ' + backend + ' (0.9.10)\n(2/2) Upgrading ' + compat + ' (0.6.9 -> 0.6.10)'), compatRequest, { [compat]: '0.6.9' }, [], compatOwner, true), 'plugin_dependency_change_required');
	rejects(() => validate([...changes('(1/3) Upgrading mihomo-meta (1.0.0 -> 2.0.0)\n'), ...closure], compatRequest, compatInstalled, [], compatOwner, true), 'plugin_dependency_change_required');

	const luciUpdate = { action: 'update', name: 'luci-app-netfleet', version: '0.9.1', before_version: '0.9.0', confirm: true };
	check(validate(changes('(1/1) Upgrading luci-app-netfleet (0.9.0 -> 0.9.1)'), luciUpdate, { 'luci-app-netfleet': '0.9.0' }, ['opl-netfleet', 'luci-app-netfleet']).candidates['luci-app-netfleet'] == '0.9.1', 'luci-app-netfleet supports independent update');
	rejects(() => validate(changes('(1/1) Purging luci-app-netfleet (0.9.0)'), { ...luciUpdate, action: 'remove', before_version: '0.9.0' }, { 'luci-app-netfleet': '0.9.0' }, ['opl-netfleet', 'luci-app-netfleet']), 'plugin_package_protected');

	const batchItems = [
		{ name: 'opl-netfleet-plugin-a', before_version: '1.0.0', version: '1.0.1' },
		{ name: 'luci-app-netfleet', before_version: '0.9.0', version: '0.9.1' },
	];
	const batchResult = validate(
		changes('(1/2) Upgrading opl-netfleet-plugin-a (1.0.0 -> 1.0.1)\n(2/2) Upgrading luci-app-netfleet (0.9.0 -> 0.9.1)'),
		{ action: 'update', items: batchItems, confirm: true },
		{ 'opl-netfleet-plugin-a': '1.0.0', 'luci-app-netfleet': '0.9.0' },
		['opl-netfleet', 'luci-app-netfleet']
	);
	check(length(batchResult.names) == 2 && batchResult.candidates['opl-netfleet-plugin-a'] == '1.0.1' && batchResult.candidates['luci-app-netfleet'] == '0.9.1', 'batch plugin update validates unique targets');
	rejects(() => validate([], { action: 'update', items: [], confirm: true }, {}, []), 'invalid_plugin_package_request');
	rejects(() => validate([], { action: 'update', items: [batchItems[0], batchItems[0]], confirm: true }, { 'opl-netfleet-plugin-a': '1.0.0' }, []), 'invalid_plugin_package_request');
	rejects(() => validate([], { action: 'update', name: 'opl-netfleet-plugin-a', items: batchItems, confirm: true }, { 'opl-netfleet-plugin-a': '1.0.0', 'luci-app-netfleet': '0.9.0' }, []), 'invalid_plugin_package_request');
	const overLimit = [];
	for (let i = 0; i < 65; i++) push(overLimit, { name: 'opl-netfleet-plugin-p' + i, before_version: '1.0.0', version: '1.0.1' });
	rejects(() => validate([], { action: 'update', items: overLimit, confirm: true }, {}, []), 'invalid_plugin_package_request');
	rejects(() => validate([], { action: 'update', items: [{ name: 'opl-netfleet-kernel', before_version: '1.0.0', version: '1.0.1' }], confirm: true }, { 'opl-netfleet-kernel': '1.0.0' }, []), 'plugin_package_protected');
	rejects(() => validate([], { action: 'update', items: [{ name: 'mihomo-meta', before_version: '1.0.0', version: '1.0.1' }], confirm: true }, { 'mihomo-meta': '1.0.0' }, []), 'plugin_package_protected');

	check(backoff_seconds(0) == 3600 && backoff_seconds(1) == 3600 && backoff_seconds(2) == 7200 &&
		backoff_seconds(3) == 14400 && backoff_seconds(4) == 28800 && backoff_seconds(5) == 57600 && backoff_seconds(6) == 57600,
		'exponential backoff bounds must hold');

	const versions = { 'opl-netfleet-kernel': '0.9.25', 'mihomo-meta': '1.19.0-r1', 'opl-netfleet-plugin-ui': '0.8.0', 'opl-netfleet-plugin-mihomo': '0.9.0', 'luci-app-netfleet': '0.9.0' };
	const candidates = { 'opl-netfleet-kernel': '0.9.26', 'mihomo-meta': '1.19.1-r1', 'opl-netfleet-plugin-ui': '0.8.1', 'opl-netfleet-plugin-mihomo': '0.9.1', 'luci-app-netfleet': '0.9.1' };
	const inv = [{ package: 'opl-netfleet-plugin-mihomo', lifecycle: { drain: { service: 'mihomo.gateway', method: 'drain' } } }];
	const rows = [
		{ name: 'opl-netfleet-plugin-ui', installed_version: '0.8.0', available_version: '0.8.1', update_available: true },
		{ name: 'luci-app-netfleet', installed_version: '0.9.0', available_version: '0.9.1', update_available: true },
		{ name: 'opl-netfleet-plugin-mihomo', installed_version: '0.9.0', available_version: '0.9.1', update_available: true },
	];
	const simulate = items => ({ names: map(items, item => item.name) });
	const w1 = plan_auto_update(rows, versions, candidates, inv, [backend], true, null, simulate);
	check(w1.wave == 'plugins' && length(w1.items) == 2 && length(w1.deferred) == 2 && w1.deferred[0].name == 'opl-netfleet-kernel' && w1.deferred[1].name == 'mihomo-meta',
		'wave 1 groups zero-downtime plugins and defers core/kernel');
	const w2 = plan_auto_update([rows[2]], versions, candidates, inv, [backend], true, null, simulate);
	check(w2.wave == 'retained' && length(w2.items) == 1 && w2.items[0].name == 'opl-netfleet-plugin-mihomo',
		'wave 2 upgrades retained native packages when wave 1 is clear');
	const wNonNative = plan_auto_update([rows[2]], versions, candidates, inv, [backend], false, null, simulate);
	check(wNonNative.wave == null && length(wNonNative.deferred) == 2 && wNonNative.deferred[1].name == 'opl-netfleet-plugin-mihomo',
		'non-native backend defers lifecycle plugins for manual maintenance');

	const compiler = 'opl-netfleet-plugin-compilation', ui = 'opl-netfleet-plugin-product-ui';
	const before = { [compiler]: '0.7.9-r1', [backend]: '0.9.15-r1', [ui]: '0.10.22-r1' };
	const after = { [compiler]: '0.7.10-r1', [backend]: '0.9.16-r1', [ui]: '0.10.23-r1' };
	function update_plan(current, native, extra_backend_dependency) {
		const rows = map(keys(after), name => ({ name, installed_version: current[name],
			available_version: after[name], update_available: current[name] != after[name] }));
		function solve(items) {
			const names = map(items, item => item.name);
			if (index(names, compiler) >= 0 && current[backend] != after[backend]) unshift(names, backend);
			if (extra_backend_dependency && index(names, backend) >= 0 && index(names, ui) < 0) push(names, ui);
			const simulated = map(names, (name, i) => `(${i + 1}/${length(names)}) Upgrading ${name} (${current[name]} -> ${after[name]})`);
			return validate(changes(join('\n', simulated)), { action: 'update', items, confirm: true }, current, [], {}, native);
		}
		return plan_auto_update(rows, current, after, inv, [backend], native, null, solve);
	}
	const safe = update_plan(before, true);
	check(safe.wave == 'plugins' && join(',', safe.plan.names) == ui && safe.deferred[0].name == compiler,
		'compiler requiring a new Mihomo leaves an independent plugin eligible');
	const retained_after_safe = update_plan({ ...before, [ui]: after[ui] }, true);
	check(retained_after_safe.wave == 'retained' && join(',', retained_after_safe.plan.names) == backend && retained_after_safe.deferred[0].name == compiler,
		'a blocked compiler does not starve the native retained Mihomo wave');
	const compiler_after_retained = update_plan({ ...before, [ui]: after[ui], [backend]: after[backend] }, true);
	check(compiler_after_retained.wave == 'plugins' && join(',', compiler_after_retained.plan.names) == compiler && !length(compiler_after_retained.deferred),
		'compiler becomes eligible after native retained Mihomo update');
	const nikki = update_plan({ ...before, [ui]: after[ui] }, false);
	check(nikki.plan == null && length(nikki.deferred) == 2, 'non-native Mihomo dependencies remain deferred');
	const unsafe_retained = update_plan({ ...before, [ui]: after[ui] }, true, true);
	check(unsafe_retained.plan == null && length(unsafe_retained.deferred) == 2, 'retained closure excludes other service plugins');
	rejects(() => plan_auto_update(rows, versions, candidates, inv, [backend], true, null, () => die('plugin_dependencies_unavailable')),
		'plugin_dependencies_unavailable');
	print('component_packages_contract_ok\n');
}

function test_component_retained() {
	function check(value, message) { if (!value) die(message); }
	const before = { id: 'mihomo', version: '0.9.10', api_version: 1,
		services: { gateway: { version: 1, module: 'gateway.uc', requires: { storage: 1 } } },
		lifecycle: { drain: { service: 'gateway', method: 'drain' } } };
	const after = { ...before, version: '0.9.11', services: {
		...before.services, profile: { version: 1, module: 'profile.uc', requires: {} },
		gateway: { ...before.services.gateway, requires: { storage: 1, profile: 1 } } } };
	check(manifest(before, after), 'additive services preserve the existing runtime contract');
	check(!manifest(before, { ...after, lifecycle: {} }), 'runtime resources cannot change');
	check(!manifest(before, { ...after, services: {} }), 'existing services cannot disappear');
	check(!manifest(before, { ...after, services: { gateway: { version: 2, module: 'gateway.uc' } } }), 'service ABI cannot change');
	check(!manifest(before, { ...after, services: { gateway: { ...before.services.gateway, requires: {} } } }), 'existing dependencies cannot disappear');
	const defaults = { schema: 'opl-netfleet-system.v1', bindings: { gateway: 'mihomo' }, enabled: { mihomo: true, 'https-compat': false }, product_packages: ['mihomo'], scheduler: { service: 'scheduler', method: 'tick' } };
	check(composition(defaults, { ...defaults, bindings: { ...defaults.bindings, profile: 'mihomo' } }), 'new bindings can enter the reviewed cohort');
	check(!composition(defaults, { ...defaults, enabled: { mihomo: true, 'https-compat': true } }), 'plugin defaults cannot change');
	check(!composition(defaults, { ...defaults, bindings: { gateway: 'other' } }), 'existing owners cannot change');
	check(!composition(defaults, { ...defaults, product_packages: ['mihomo', 'other'] }), 'package composition cannot change');
	print('component_retained_contract_ok\n');
}

function test_components_recovery(source) {
	const start = index(source, "restore_services = function(");
	const end = index(source, "rollback = function(", start);
	if (start < 0 || end < 0) die("recovery implementation unavailable");
	const implementation = substr(source, start, end - start);
	const harness = `
let now = 0, sets = 0, starts = 0, chosen = "old", broken = false, changed = false, running = {};
let restore_services;
const SERVICE = "test-core", MAIN = "test-main", KIND = "native-mihomo";
const paths = { COMPAT_STATE_PATH: "/unused/compat-state.json" };
function time() { return now; }
function system(command) { now++; return 0; }
function run_command(command, work) { starts++; return true; }
function service_running(name) { return running[name] == true; }
function same_inputs(before) { return !changed; }
function api_secret() { return "test"; }
function controller_version(secret, timeout) { return now >= 1 ? "test" : null; }
function proxies(secret, timeout) { return {proxies: now >= 3 ? {group: {all: ["old", "desired"], now: chosen}} : {}}; }
function select(secret, name, choice) { sets++; chosen = choice; return true; }
function q(value) { return value; }
let manager_tick=2, admitted=true, engine_birth='same';
function read_json(path){return {last_tick:manager_tick,rule_recovery:{rule:{admitted}}};}
function process_birth(pid){return engine_birth;}
function parsed(command) { if(index(command,'compatibility-get')>=0)return {ok:true,result:{requested:true,intercepting:true,leases:1}};return {result: {active: true, runtime: {controller_available: true, lan_runtime: {dns_ready: now >= 5, transparent_proxy_ready: now >= 5}}}}; }
function probe_ok() { return !broken && now >= 7; }
function check(value, message) { if (!value) die(message); }
`;
	const cases = `
const before = {core: true, supervisor: true, active: true, selections: {group: "desired"}};
check(restore_services(before, "/unused"), "eventually ready runtime must recover");
check(now == 7 && sets == 1 && starts == 2, "wait for providers, gateway and probe without restarting repeatedly");
now = 7; sets = 0; starts = 0; running = {"test-core": true, "opl-netfleet": true};
check(restore_services(before, "/unused") && sets == 0 && starts == 0, "already restored runtime must not be restarted or selections rewritten");
running = {"test-core": true};
check(restore_services(before, "/unused") && starts == 1, "only the missing supervisor must be started");
running = {"opl-netfleet": true}; starts = 0;
check(restore_services(before, "/unused") && starts == 1, "only the missing core must be started");
now = 7; broken = true;
check(!restore_services(before, "/unused") && now == 52, "persistent probe failure must time out");
now = 7; broken = false; changed = true;
check(!restore_services(before, "/unused") && now == 7, "changed private configuration must fail immediately");
changed=false;running={"test-core":true,"opl-netfleet":true};
native_identity=()=>({pid:1});
const retained={...before,runtime_retained:true,retained_core:{pid:1},retained_engine:{pid:2,birth:'same'},retained_compat:{requested:true,intercepting:true,last_tick:1}};
check(restore_services(retained,'/unused'),'fresh actual manager admission is accepted');
manager_tick=1;check(!restore_services(retained,'/unused'),'old lease alone cannot prove a replacement manager renewed it');
manager_tick=2;admitted=false;check(!restore_services(retained,'/unused'),'pending DNS cannot pass retained-runtime acceptance');
admitted=true;engine_birth='changed';check(!restore_services(retained,'/unused'),'replacement engine identity must fail');
`;
	loadstring(harness + implementation + cases)();
	const recovery_start = index(source, "function restore_runtime_tree(");
	const tree_end = index(source, "rollback = function(", recovery_start);
	const tree_restore = substr(source, recovery_start, tree_end - recovery_start);
	loadstring(`
const digest = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const archive = '/tx/new/plugin.apk', baseline = {'/code/old': 'old'};
const before = {runtime_paths:['/code'], runtime_inputs:baseline};
let files, sealed = true;
function q(x) { return x; }
function run_command(cmd, work) { return true; }
function input_identity(paths) { return {...files}; }
function read_json(path) { return {next:[archive], inputs:{[archive]:'signed'}}; }
function sha256(path) { return sealed ? 'signed' : 'changed'; }
function parsed(cmd) { return {paths:[{name:'code', files:[{name:'new',hash:digest}]}]}; }
const fs = {lstat: path => ({type:'file'}), unlink: path => {delete files[path]; return true;}};
` + tree_restore + `
files = {...baseline, '/code/new':digest, '/code/foreign':digest};
assert(!restore_runtime_tree(before,'/tx') && length(keys(files)) == 3);
delete files['/code/foreign']; files['/code/new']='changed';
assert(!restore_runtime_tree(before,'/tx') && exists(files,'/code/new'));
files['/code/new']=digest; sealed=false;
assert(!restore_runtime_tree(before,'/tx') && exists(files,'/code/new'));
sealed=true;
assert(restore_runtime_tree(before,'/tx') && length(keys(files)) == 1);
assert(restore_runtime_tree(before,'/tx'));
`)();
	const recovery_end = index(source, "upgrade = function(", recovery_start);
	const recovery = substr(source, recovery_start, recovery_end - recovery_start);
	loadstring(`
let rollback, stops = 0, starts = 0, scoped_drains = 0, commands = [], world_calls = 0, saved;
let package_ok = false, world_ok = true, identity_ok = true, runtime_ok = true, input_ok = true, bytes_ok = true;
const UPGRADE_STATE = "/unused", fs = {unlink: path => true};
function q(value) { return value; }
function stop_services(work) { stops++; return true; }
function drain_scoped(work) { scoped_drains++; return true; }
function archive_arguments(paths) { return join(" ", paths); }
function run_command(command, work) { push(commands, command); return index(command, "apk --") < 0 || package_ok; }
function restore_world(names, before, work) { world_calls++; if (!world_ok) die("world unavailable"); return true; }
function installed() { return {package: identity_ok ? "old" : "new"}; }
function input_identity(paths) { return {code: bytes_ok ? "old" : "partial"}; }
function same_inputs(before) { return input_ok; }
function restore_services(before, work) { starts++; return runtime_ok; }
function verify_runtime(before, work) { return restore_services(before, work); }
function resume_resources(work) { return true; }
function atomic_json(path, value) { saved = value; return true; }
function check(value, message) { if (!value) die(message); }
` + recovery + `
const before = {world: {}, runtime_paths: ["code"], runtime_inputs: {code: "old"}};
check(rollback(before, "/unused", ["package"], {package: "old"}, ["old.apk"], true) == "rollback_install_failed",
    "nonzero package result remains an error");
check(starts == 1 && world_calls == 1 && saved.runtime_restored,
    "package errors must not skip world or runtime restoration");
check(index(commands[1], "runtime.tar") >= 0 && index(commands[2], "apk --") >= 0,
    "known-good runtime hooks must be restored before invoking rollback APK hooks");
package_ok = true; world_ok = false;
rollback(before, "/unused", ["package"], {package: "old"}, ["old.apk"], true);
check(starts == 2 && saved.runtime_restored, "world exceptions must not skip runtime restoration");
world_ok = true; identity_ok = false;
let previous_stops = stops;
rollback(before, "/unused", ["package"], {package: "old"}, ["old.apk"], true);
check(starts == 2 && stops == previous_stops + 2 && !saved.runtime_restored,
    "wrong package identity must stay stopped and still run final cleanup");
identity_ok = true; runtime_ok = false;
previous_stops = stops;
rollback(before, "/unused", ["package"], {package: "old"}, ["old.apk"], true);
check(stops == previous_stops + 2 && !saved.runtime_restored, "failed restart must clean again");
runtime_ok = true;
bytes_ok = false;
let previous_starts = starts;
commands = [];
rollback(before, "/unused", ["package"], {package: "old"}, ["old.apk"], true);
check(starts == previous_starts && !saved.runtime_restored, "version equality must not hide partially restored runtime files");
check(!length(filter(commands, command => index(command,"apk --") >= 0)), "unverified hook bytes must not execute rollback APK");
bytes_ok = true;
check(rollback(before, "/unused", ["package"], {package: "old"}, ["old.apk"], true) == null,
    "verified successful rollback remains successful");
bytes_ok = true; identity_ok = true; runtime_ok = false; const stops_before = stops;
rollback({...before,scoped:true}, "/unused", ["package"], {package:"old"}, ["old.apk"], true);
check(stops==stops_before && scoped_drains>=2, "plugin recovery failure must never stop the whole network");
`)();
	print("components_recovery_contract_ok\n");

	const verify_start = index(source, 'function verify_runtime(');
	const verify_end = index(source, 'function drain_scoped(', verify_start);
	loadstring(`
let held=true, ready_at=2, raises=false, now=0, checks=0;
function time(){return now;}function system(){now++;return 0;}
function network_leave(){held=false;}function network_enter(){held=true;}
function parsed(){die('a one-shot HTTPS controller must not run');}
function restore_services(before){if(before.runtime_retained&&held)die('retained verification cannot block renewal');checks++;if(raises)die('verification_failure');return now>=ready_at;}
function check(v,m){if(!v)die(m);}
` + substr(source, verify_start, verify_end - verify_start) + `
const before={runtime_retained:true,retained_engine:{pid:2}};
check(verify_runtime(before,'work')&&held&&now==2,'wait for the actual manager without blocking its renewal');
ready_at=30;now=0;check(verify_runtime(before,'work')&&held&&now==30,'expired admission must allow the actual manager recovery hold');
ready_at=100;now=0;check(!verify_runtime(before,'work')&&held&&now==45,'failed manager readiness must be bounded');
raises=true;try{verify_runtime(before,'work');}catch(e){}
check(held,'verification exceptions must reacquire the mutation lock');
raises=false;ready_at=0;const previous=now;
check(verify_runtime({},'work')&&held&&now==previous,'ordinary stopped-runtime recovery keeps its existing lock');
`)();

	const world_start = index(source, "restore_world = function(");
	const world_end = index(source, "feed = function(", world_start);
	loadstring(`
let restore_world, actual, commands = [], succeeds = true;
function q(value) { return value; }
function run_command(command, work) { push(commands, command); return succeeds; }
function package_world() { return actual; }
function check(value, message) { if (!value) die(message); }
` + substr(source, world_start, world_end - world_start) + `
const before = {a: "a", b: "b>=2", c: "c><Q1old", unrelated: "unrelated@stable"};
actual = {a: "a", b: "b>=2", c: "c", unrelated: "unrelated@stable"};
check(restore_world(["a", "b", "c", "dep"], before, "/unused"), "successful update normalizes archive pins but preserves administrator constraints");
check(index(commands[0], "a b>=2 c") >= 0 && index(commands[1], "del dep") >= 0, "restore exact roots and remove accidental dependency roots");
actual.c = "c><Q1old";
check(restore_world(["c"], before, "/unused", true), "rollback restores the original checksum pin");
actual.b = "b><Q1new";
check(!restore_world(["b"], before, "/unused"), "an unrestored version constraint must fail");
actual = {a: "a", b: "b>=2", c: "c", unrelated: "changed"};
check(!restore_world(["a", "b", "c"], before, "/unused"), "unrelated world roots cannot change silently");
succeeds = false;
check(!restore_world(["a"], before, "/unused"), "unsatisfied constraints require transaction rollback");
succeeds = true;
const pinned = {core: "core=1.0", other: "other=2.0"};
actual = {core: "core=1.1", other: "other=2.0"};
check(restore_world(["core"], pinned, "/unused", false, ["core"], {core:"1.1"}), "explicit upgrade moves only its exact version pin");
actual.core = "core=1.0";
check(restore_world(["core"], pinned, "/unused", true, ["core"], {core:"1.1"}), "rollback restores the original exact version pin");
check(restore_world(["core"], pinned, "/unused", false, [], {core:"1.1"}), "retained component pin is not rewritten");
`)();

	const reconcile_start = index(source, "recovery_world = function(");
	loadstring(`
let recovery_world;
const fs = {readfile: path => "C:Q1current\\nP:ui\\nV:1.0-r1\\n\\n"};
function fail(reason) { die(reason); }
` + substr(source, reconcile_start, world_start - reconcile_start) + `
const before = {ui: "ui><Q1stale", other: "other><Q1keep"};
const repaired = recovery_world(["ui"], before);
if (repaired.ui != "ui" || repaired.other != before.other || before.ui != "ui><Q1stale") die("stale pin must be repaired only in the selected recovery intent");
if (recovery_world(["ui"], {ui: "ui><Q1current"}).ui != "ui><Q1current") die("matching pin must be preserved for rollback");
`)();
}

function test_components_update_control(source) {
	function extract(begin, end) {
		const start = index(source, begin), stop = index(source, end, start);
		if (start < 0 || stop < 0) die('implementation missing');
		return substr(source, start, stop - start);
	}
	const ownership = extract('function package_owners(', 'function package_paths(');
	loadstring(`
const COMPATIBILITY_PACKAGE='opl-netfleet-https-compat';
const paths={COMPAT_EXTENSION_PATH:'/unused/extension.json'};
function compatibility_package(){return COMPATIBILITY_PACKAGE;}
let rows=[{id:'https-compat',kind:'plugin',package:'opl-netfleet-plugin-https-compat'}];
let info={type:'file',uid:0,mode:420,size:80}, descriptor={id:'https-compat',api_version:1};
const context={inventory:()=>rows}, fs={lstat:()=>info};
function read_json(){return descriptor;}
function check(value,message){if(!value)die(message);}
` + ownership + `
const versions={'opl-netfleet-plugin-https-compat':'0.9.6','opl-netfleet-https-compat':'0.6.3'};
check(package_owners(versions)[COMPATIBILITY_PACKAGE]=='https-compat','service inventory resolves separate native engine');
check(package_owners({})[COMPATIBILITY_PACKAGE]==null,'absent runtime is not managed');
descriptor.id='foreign';check(package_owners(versions)[COMPATIBILITY_PACKAGE]==null,'foreign descriptor is not admitted');descriptor.id='https-compat';
info.mode=438;check(package_owners(versions)[COMPATIBILITY_PACKAGE]==null,'writable descriptor is not admitted');info.mode=420;
info.type='link';check(package_owners(versions)[COMPATIBILITY_PACKAGE]==null,'symlink descriptor is not admitted');info.type='file';
rows=[];check(package_owners(versions)[COMPATIBILITY_PACKAGE]==null,'runtime without control owner is not managed');
`)();

	const controls = extract('function cancel_update(', 'function lifecycle(');
	loadstring(`
const ROOT='/private'; let id='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', request={id,action:'update'}, state={}, running=true, locked=false, marker=false, unsafe=false, closes=0;
const REQUEST='request';
function check(value,message){if(!value)die(message);}
function fail(code){die(code);}
function error_code(error){return trim(split(error.message ?? error,'\\n')[0]);}
function private_file(path){return path=='request'||path=='/private/'+id+'/cancel.json' ? path=='request'||marker : !unsafe;}
function private_directory(path){return true;}
function read_json(path){return path=='request'?request:state;}
function update_process(){return {running};}
function atomic_json(path,value){marker=true;return true;}
const fs={lstat:()=>({}),open:()=>({lock:()=>!locked,close:()=>{closes++;}})};
function rejects(action,code){let seen;try{action();}catch(error){seen=error_code(error);}check(seen==code,'expected '+code+', got '+seen);}
` + controls + `
rejects(()=>cancel_update('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),'update_operation_changed');
check(!marker,'stale identity must not cancel');
locked=true;rejects(()=>cancel_update(id),'update_transition_busy');check(!marker,'transition owns cancellation decision');locked=false;
state={write_started:true};rejects(()=>cancel_update(id),'update_cancel_unavailable');check(!marker,'cannot cancel package replacement');
state={phase:'complete'};rejects(()=>cancel_update(id),'update_cancel_unavailable');
state={};running=false;rejects(()=>cancel_update(id),'update_cancel_unavailable');running=true;
unsafe=true;rejects(()=>cancel_update(id),'unsafe_update_directory');unsafe=false;
check(cancel_update(id).requested && marker,'current operation accepts cancellation');
rejects(()=>cancellation('/private/'+id),'update_cancelled');
check(closes>=4,'control lock released on failures and success');
`)();

	const preparation = extract('function resume_resources(', 'get = function(');
	loadstring(`
let state={drained:[]}, calls=[], failure='healthy_connections_still_draining', cancelled=false;
function package_owners(){return {'example-native-engine':'example'};}
const context={inventory:()=>[]}, operation={update:()=>true};
function check(value,message){if(!value)die(message);}
function read_json(path){return state;}
function journal(work,next){state=next;}
function cancellation(work){if(cancelled)die('update_cancelled');}
function fail(code){die(code);}
function lifecycle(action,id){push(calls,action+':'+id);return {ok:action=='resume'||id!='mihomo',error:failure};}
function system(command){return 0;}
` + preparation + `
let reason;try{prepare_resources('/work',['opl-netfleet-plugin-events','mihomo-meta'],{'opl-netfleet-plugin-events':'1','mihomo-meta':'1'},{'opl-netfleet-plugin-events':'2','mihomo-meta':'2'});}catch(e){reason=e.message;}
check(reason=='update_deferred','healthy connections defer update');
check(state.phase=='draining'&&length(state.drained)==2,'save every attempted owner before calling drain');
check(resume_resources('/work'),'restore resources after deferred update');
check(join(',',calls)=='drain:events,drain:mihomo,resume:mihomo,resume:events','restore in reverse order');
calls=[];state={drained:[]};prepare_resources('/work',['example-native-engine'],{'example-native-engine':'1'},{'example-native-engine':'2'});check(join(',',calls)=='drain:example','runtime ownership comes from inventory');
calls=[];cancelled=true;try{prepare_resources('/work',['mihomo-meta'],{'mihomo-meta':'1'},{'mihomo-meta':'2'});}catch(e){}
check(!length(calls),'cancel before preparing any resource');
`)();

	const stopping = extract('stop_services = function(', 'restore_services = function(');
	loadstring(`
let stop_services, clean=true, running=false, reads=0;
const KIND='native-mihomo', SERVICE='opl-netfleet-core';
const gateway={status:()=>{reads++;return {ok:true,result:{clean}};}};
function run_command(){return true;}function service_running(){return running;}
function system(){return 0;}
function parsed(){die('installed gateway command must not be used during maintenance');}
` + stopping + `
if(!stop_services('/work')||reads!=1)die('retained gateway confirms drained cleanup');
clean=false;if(stop_services('/work'))die('unclean gateway must reject update');
running=true;if(stop_services('/work'))die('running services must reject update');
`)();

	const getter = extract('get = function(', 'local_stage = function(');
	loadstring(`
let get;const CACHE='cache',PACKAGES=['opl-netfleet','luci-app-netfleet','mihomo-meta'],KIND='native-mihomo',DEPENDENCIES=[];
let versions={'opl-netfleet':'1','luci-app-netfleet':'1','opl-netfleet-plugin-ui':'2'}, candidates={'opl-netfleet':'1','luci-app-netfleet':'1','opl-netfleet-plugin-ui':'3'};
function installed(){return versions;}function feed(){return 'feed';}function private_file(){return true;}
function read_json(){return {feed:'feed',versions:candidates};}function newer(next,current){return next!=null&&current!=null&&int(next)>int(current);}
function product_packages(){return ['opl-netfleet','luci-app-netfleet','opl-netfleet-plugin-ui'];}function version_valid(value){return value!=null;}
function controller_version(){return null;}function api_secret(){return null;}function capture(){return null;}function dashboard_resource(){return {};}
const context={inventory:()=>[]};function check(value,message){if(!value)die(message);}
function plugin_packages(){return [];}
` + getter + `
let result=get();check(result.components[0].update_available && result.components[0].available_version=='1','same aggregate version must expose plugin update');
check(join(',',result.product.updates)=='opl-netfleet-plugin-ui','report actual changed packages');
versions['opl-netfleet-plugin-ui']='4';result=get();check(!result.components[0].update_available,'never offer a downgrade');
delete versions['opl-netfleet-plugin-ui'];result=get();check(join(',',result.product.missing)=='opl-netfleet-plugin-ui','missing package is separate from an update');
`)();
	print('components_update_control_contract_ok\n');

	const index_refresh = extract('refresh_index = function(', 'function archive_repository(');
	loadstring(`
let refresh_index, now=1000, refreshes=0, saved;
const CACHE='cache';
let cached={feed:'feed',checked_at:999,error:null}, values={product:'2'};
function time(){return now;}function private_file(){return true;}function read_json(){return cached;}
function available(){return values;}function apk_download(){refreshes++;return true;}
function plugin_catalog(){return {};}function atomic_json(p,v){saved=v;return true;}function fail(e){die(e);}
const operation={update:()=>true};
function check(v,m){if(!v)die(m);}
` + index_refresh + `
check(refresh_index({action:'update',feed:'feed'},'/work').product=='2' && refreshes==0,'recent signed index reused');
refresh_index({action:'check',feed:'feed'},'/work');check(refreshes==1,'explicit check refreshes');
now=1301;refresh_index({action:'update',feed:'feed'},'/work');check(refreshes==2,'expired cache refreshes');
now=900;refresh_index({action:'update',feed:'feed'},'/work');check(refreshes==3,'clock rollback never extends cache');
now=1000;refresh_index({action:'update',feed:'other'},'/work');check(refreshes==4,'feed change refreshes');
`)();
	const dependency_plan = extract('function product_plan(', 'upgrade = function(');
	loadstring(`
let rows=[], command;
const package_model={changes:()=>rows};
function capture(value){command=value;return 'plan';}function q(v){return v;}
function fail(e){die(e);}function version_valid(v){return v!=null;}
function check(v,m){if(!v)die(m);}
` + dependency_plan + `
let versions={product:'1',lib:'1'}, candidates={product:'2'};
rows=[{action:'Installing',name:'new-dependency',version:'1'},{action:'Upgrading',name:'product',version:'2'}];
let names=product_plan(['product'],versions,candidates);
check(join(',',names)=='product,new-dependency' && candidates['new-dependency']=='1','include missing dependency in exact transaction');
check(index(command,'product=2')>=0,'solve exact selected product version');
for(let row in [{action:'Upgrading',name:'lib',version:'2'},{action:'Purging',name:'lib',version:'1'}]){
 rows=[row];let reason;try{product_plan(['product'],versions,{product:'2'});}catch(e){reason=e.message;}
 check(reason=='product_dependency_change_required','never mutate unrelated installed libraries');
}
`)();
	const selection = extract('upgrade = function(', '\tconst space = capture(`df -Pk');
	loadstring(`
let upgrade,state;
const PACKAGES=['opl-netfleet','luci-app-netfleet','mihomo-meta'],COMPATIBILITY_PACKAGE='opl-netfleet-https-compat',UPGRADE_STATE='marker';
function compatibility_package(){return COMPATIBILITY_PACKAGE;}
let versions={'opl-netfleet':'1','luci-app-netfleet':'1','opl-netfleet-kernel':'1','opl-netfleet-plugin-dashboard':'1'};
function product_packages(){return keys(versions);}function installed(){return versions;}function newer(a,b){return a!=null&&b!=null&&int(a)>int(b);}
function version_valid(v){return v!=null;}function fail(e){die(e);}function journal(w,v){state=v;}
const fs={lstat:()=>null};function check(v,m){if(!v)die(m);}
` + selection + `return names;};
let names=upgrade({component:'netfleet',version:'1'},'/work',{...versions,'opl-netfleet-plugin-dashboard':'2'});
check(length(names)==1&&names[0]=='opl-netfleet-plugin-dashboard','product update only replaces changed plugin');
upgrade({component:'netfleet',version:'1'},'/work',versions);check(state.no_change&&state.phase=='complete','unchanged composition completes without work');
`)();
	print('components_update_efficiency_ok\n');

	const backup_paths = extract('\tbefore.runtime_paths = filter(', '\tbefore.runtime_inputs = input_identity');
	loadstring(`
const before={scoped:true}, SERVICE='core', fs={lstat:()=>({})};
const names=['opl-netfleet-plugin-dashboard'],versions={};function package_paths(){return ['/usr/libexec/opl-netfleet/plugins/dashboard','/www/plugin-file'];}
let request={component:'plugins'};
` + backup_paths + `
if(!length(before.runtime_paths))die('batch plugin updates must retain rollback runtime');
request={component:'plugins',plugin:{name:'opl-netfleet-plugin-dashboard'}};
` + backup_paths + `
if(length(before.runtime_paths)!=2 || before.runtime_paths[0]!='/usr/libexec/opl-netfleet/plugins/dashboard')die('single plugin retains its own runtime');
`)();

	const scoped_stop = extract('function drain_scoped(', 'rollback = function(');
	loadstring(`
const fs={}, calls=[];
function read_json(){return {drained:['configuration']};}
function lifecycle(action,id,entry){push(calls,{action,id,entry});return {ok:entry=='/private/code/main.uc'};}
` + extract('drain_resource = function(', 'function prepare_resources(') + scoped_stop + `
if(!drain_scoped('/private') || calls[0].entry!='/private/code/main.uc')die('scoped crash recovery must use retained entry even if installed main is damaged');
`)();
}

function test_bundle_engine() {
	function check(value, message) { if (!value) die(message); }
	const bundle = loadstring("import * as b from '" + replace(sourcepath(), /[^/]+$/, '../plugins/components/lib/bundle.uc') + "'; return b;")();
	check(bundle.semver_cmp('0.9.32', '0.9.33') < 0, 'semver compares patch bump');
	check(bundle.semver_cmp('0.9.33', '0.9.33') == 0, 'semver equality');
	const root = fs.mkdtemp('/tmp/nf-bundle-contract.XXXXXX');
	check(root != null, 'mkdtemp creates contract sandbox');
	let err = null;
	try {
		fs.mkdir(root + '/releases', 0755);
		fs.mkdir(root + '/releases/0.9.32', 0755);
		fs.mkdir(root + '/releases/0.9.32/share', 0755);
		fs.mkdir(root + '/etc', 0700);
		fs.writefile(root + '/shell.json', '{"shell_version":"0.9.32"}');
		fs.writefile(root + '/releases/0.9.32/share/build.json', '{"version":"0.9.32","source_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}');
		fs.writefile(root + '/etc/release-feed.json', '{"url":"https://example.invalid/releases"}');
		fs.chmod(root + '/etc/release-feed.json', 0600);
		fs.symlink('releases/0.9.32', root + '/current');
		const paths = {
			SHELL_META_PATH: root + '/shell.json',
			BUNDLE_CURRENT: root + '/current',
			BUNDLE_PREVIOUS: root + '/previous',
			BUNDLE_RELEASES: root + '/releases',
			BUNDLE_ROOT: root,
			BUNDLE_KEY_PATH: root + '/key.pub',
			RELEASE_FEED_PATH: root + '/etc/release-feed.json'
		};
		check(bundle.enabled(paths), 'bundle enabled detects shell meta and current symlink');
		const mkdtemp = template => fs.mkdtemp(template);
		const ctx = {
			paths,
			ROOT: root + '/tx',
			KIND: 'native-mihomo',
			PACKAGES: ['opl-netfleet', 'luci-app-netfleet', 'mihomo-meta'],
			DEPENDENCIES: ['ucode', 'usign'],
			adapter: { package_available: () => false },
			private_file: p => fs.lstat(p)?.type == 'file',
			read_json: p => { try { return json(fs.readfile(p)); } catch (e) { return null; } },
			atomic_json: (p, v) => fs.writefile(p, sprintf('%J', v)),
			opkg_feed: () => null,
			opkg_arch: () => 'aarch64_generic',
			package_manager: () => 'apk',
			installed: () => ({ 'opl-netfleet': '0.9.32', 'luci-app-netfleet': '0.9.32', usign: '2024', ucode: '2025' }),
			controller_version: () => null,
			api_secret: () => null,
			capture: cmd => cmd == 'command -v usign' ? '/usr/bin/usign' : 'aarch64',
			run_command: () => false,
			mkdtemp,
			q: s => "'" + replace(`${s}`, "'", "'\\''") + "'",
			fail: c => die(c),
			dashboard_resource: () => ({}),
			inventory: () => [],
			product_packages: () => ['opl-netfleet', 'luci-app-netfleet'],
			auto_update_summary: () => null
		};
		check(bundle.feed_config(ctx)?.url == 'https://example.invalid/releases', 'feed_config reads release-feed.json');
		const st = bundle.get_state(ctx);
		check(st.delivery_mode == 'release-bundle' && st.bundle_version == '0.9.32' && !st.rollback_available, 'get_state projects release-bundle mode');
		let check_err = null;
		fs.mkdir(ctx.ROOT, 0700);
		try { bundle.check(ctx, ctx.ROOT); } catch (e) { check_err = e.message; }
		check(check_err == 'feed_check_failed', 'bundle.check uses mkdtemp and fails cleanly when feed download fails, got: ' + check_err);
		const bundle_src = fs.readfile(replace(sourcepath(), /[^/]+$/, '../plugins/components/lib/bundle.uc'));
		check(match(bundle_src, /\/[^\n\/;()]*\\x00/) == null, 'bundle.uc must not embed NUL escapes inside POSIX regex literals');
		fs.mkdir(root + '/badtar', 0755);
		fs.writefile(root + '/badtar/ok.txt', 'ok');
		const ok_tar = root + '/ok.tar.gz';
		system('tar -czf ' + "'" + ok_tar + "'" + ' -C ' + "'" + root + '/badtar' + "'" + ' .');
		const tar_size = fs.lstat(ok_tar).size;
		const tx2 = root + '/tx2';
		fs.mkdir(tx2, 0700);
		fs.mkdir(tx2 + '/w', 0700);
		const manifest_obj = {
			schema: 'opl-netfleet-release-bundle.v1',
			version: '0.9.33',
			min_shell_version: '0.9.32',
			archive: 'opl-netfleet-bundle-0.9.33.tar.gz',
			archive_sha256: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
			archive_size: tar_size,
			source_commit: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
			source_tree: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
			files: { 'missing.txt': { size: 2, sha256: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd', mode: '0644' } }
		};
		const ctx2 = {
			...ctx,
			ROOT: tx2,
			operation: { update: () => true, finish: () => true },
			cancellation: () => true,
			read_json: p => match(p, /shell\.json$/) ? { shell_version: '0.9.32' } : match(p, /build\.json$/) ? { version: '0.9.32', source_commit: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } : match(p, /release-manifest\.json$/) ? manifest_obj : { url: 'https://example.invalid/releases' },
			run_command: cmd => {
				if (index(cmd, 'curl ') == 0) {
					const m = match(cmd, /--output '([^']+)'/);
					if (m != null) {
						if (index(cmd, 'bundle-0.9.33.tar.gz') >= 0) return system('cp ' + "'" + ok_tar + "'" + ' ' + "'" + m[1] + "'") == 0;
						return fs.writefile(m[1], '{}');
					}
				}
				if (index(cmd, 'usign ') == 0) return true;
				return system(cmd) == 0;
			},
			capture: cmd => match(cmd, /^df /) ? '100000' : 'aarch64',
			sha256: () => 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
		};
		fs.writefile(paths.BUNDLE_KEY_PATH, 'untrusted comment: test\nRWQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==\n');
		fs.chmod(paths.BUNDLE_KEY_PATH, 0644);
		let sig_err = null;
		try { bundle.apply(ctx2, { id: '11111111111111111111111111111111', feed: 'https://example.invalid/releases', version: '0.9.33' }, tx2 + '/w'); } catch (e) { sig_err = e.message; }
		check(sig_err == 'bundle_signature_invalid' || sig_err == 'bundle_stage_invalid', 'bundle.apply returns deterministic error code, got: ' + sig_err);
		check(match('a/b/c.uc', /[\r\t]/) == null && index('a/b/c.uc', '\x00') < 0, 'clean archive path passes regex/NUL guard');
		check(index('a\x00b', '\x00') >= 0 && match('a\tb', /[\r\t]/) != null, 'control/NUL chars rejected');
	} catch (e) {
		err = e;
	}
	system('rm -rf ' + "'" + root + "'");
	if (err != null) die(err);
	print('bundle_engine_contract_ok\n');
}

const control_path = ARGV[0] ?? replace(sourcepath(), /[^/]+$/, '../plugins/components/lib/control.uc');
const control_source = fs.readfile(control_path);
if (control_source == null) die('components implementation unreadable');
test_component_packages();
test_component_retained();
test_components_recovery(control_source);
test_components_update_control(control_source);
test_bundle_engine();
