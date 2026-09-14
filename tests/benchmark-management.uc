/* SPDX-License-Identifier: Apache-2.0 */
import * as fs from 'fs';

// Run this same fixture against either source tree. No production services,
// traffic or credentials are used; timings are dispatch/conversion costs.
const source = fs.realpath(ARGV[0]);
if (source == null) die('provide runtime source directory');
const kernel = loadstring(sprintf('import { execute } from %J; import { create } from %J; return {execute, adapter: create()};',
	`${source}/kernel/host.uc`, `${source}/adapters/openwrt.uc`))();
const root = fs.mkdtemp('/tmp/netfleet-management-benchmark.XXXXXX');
function remove(path) {
	if (fs.lstat(path)?.type == 'directory') { for (let name in fs.lsdir(path)) remove(`${path}/${name}`); fs.rmdir(path); }
	else fs.unlink(path);
}
function ms() { const t = clock(); return t[0] * 1000 + t[1] / 1000000.0; }
function statistics(samples) { sort(samples, (a,b) => a-b); return { p50_ms: samples[int(length(samples)/2)], p95_ms: samples[length(samples)-1] }; }
const results = [];
try {
	fs.mkdir(`${root}/plugins`, 0700); fs.mkdir(`${root}/locks`, 0700); fs.mkdir(`${root}/maintenance`, 0700);
	const system = { schema: 'opl-netfleet-system.v1', bindings: {}, enabled: {} };
	for (let size in [1, 16, 64]) {
		for (let n = 0; n < size; n++) {
			const id = `sample-${n}`, directory = `${root}/plugins/${id}`;
			if (fs.lstat(directory) != null) continue;
			fs.mkdir(directory, 0700); fs.mkdir(`${directory}/lib`, 0700);
			fs.writefile(`${directory}/manifest.json`, sprintf('%J', {
				schema: 'opl-netfleet-service-plugin.v1', id, label: id, version: '1.0.0', api_version: 1,
				package: `opl-netfleet-plugin-${id}`, commands: n == 0 ? { status: { service: 'sample.value', method: 'get', access: 'read' } } : {},
				services: { [`sample.value${n == 0 ? '' : n}`]: { version: 1, module: 'lib/main.uc', requires: {} } }
			}));
			fs.writefile(`${directory}/lib/main.uc`, 'return ctx => ({get: () => ({ok: true, result: 42})});');
			for (let f = 0; f < 8; f++) fs.writefile(`${directory}/resource-${f}.txt`, sprintf('%08192d', f));
			system.enabled[id] = true;
			system.bindings[`sample.value${n == 0 ? '' : n}`] = id;
		}
		const options = { adapter: kernel.adapter, trusted_owner: fs.stat(root).uid, system,
			code_locks: true, lock_root: `${root}/locks`, maintenance_root: `${root}/maintenance` };
		const samples = [];
		for (let round = 0; round < 9; round++) {
			const started = ms(), result = kernel.execute(['status'], root, options);
			if (result?.result != 42) die(sprintf('%J', result));
			if (round) push(samples, ms()-started);
		}
		push(results, { scenario: 'command', installed_plugins: size, samples: length(samples), ...statistics(samples) });
	}
	const factory = loadfile(`${source}/plugins/platform-storage/lib/storage.uc`)();
	const storage = factory({ state: {}, use: () => ({ shell_quote: value => "'" + replace(value, "'", "'\\''") + "'" }) });
	const document = `${root}/input.yaml`;
	fs.writefile(document, 'proxies:\n' + join('', map([1,2,3,4,5,6,7,8], n => `  - name: node${n}\n    type: direct\n`)));
	const samples = [];
	for (let round = 0; round < 21; round++) {
		const started = ms(), value = storage.read_yaml(document);
		if (length(value.proxies) != 8) die('yaml_projection_changed');
		value.proxies[0].name = 'caller-local';
		if (round) push(samples, ms()-started);
	}
	push(results, { scenario: 'unchanged_yaml', samples: length(samples), ...statistics(samples) });
} catch (error) { remove(root); die(error.message); }
remove(root);
printf('%J\n', { schema: 'opl-netfleet-management-benchmark.v1', results });
