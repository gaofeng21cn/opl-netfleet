#!/usr/bin/ucode

import * as fs from 'fs';

const invoked = sourcepath(0, true);
let root = invoked;
let lease;
if (invoked == '/usr/libexec/opl-netfleet') {
	const directory = '/var/lock/opl-netfleet-code';
	if (fs.lstat(directory) == null) fs.mkdir(directory, 0700);
	const info = fs.lstat(directory), path = `${directory}/.kernel.lock`, file = fs.lstat(path);
	if (info?.type != 'directory' || info.uid != 0 || (info.mode & 022) ||
		(file != null && (file.type != 'file' || file.uid != 0 || (file.mode & 022)))) die('plugin_kernel_lock_unsafe');
	lease = fs.open(path, 'ae', 0600);
	if (lease == null || !lease.lock('sn') || fs.lstat('/var/run/opl-netfleet-plugin-maintenance/.kernel') != null) {
		lease?.close(); printf('%J\n', { ok: false, error: 'plugin_kernel_maintenance' }); exit(1);
	}
	const bundle = '/usr/share/opl-netfleet/current/runtime';
	if (fs.lstat(`${bundle}/kernel/host.uc`) != null) {
		const target = fs.realpath(bundle);
		const dir_stat = target != null ? fs.stat(target) : null;
		const host_stat = target != null ? fs.lstat(`${target}/kernel/host.uc`) : null;
		if (dir_stat?.type != 'directory' || dir_stat.uid != 0 || (dir_stat.mode & 022) ||
			host_stat?.type != 'file' || host_stat.uid != 0 || (host_stat.mode & 022)) {
			lease?.close(); printf('%J\n', { ok: false, error: 'plugin_kernel_unsafe' }); exit(1);
		}
		root = target;
	}
}
// Load the replaceable kernel only after pinning its complete file generation.
try {
	loadstring(sprintf('import { run } from %J; import { create } from %J; return (argv, root) => run(argv, root, { adapter: create(root) });',
		`${root}/kernel/host.uc`, `${root}/adapters/openwrt.uc`))()(ARGV, root);
}
catch (error) { lease?.close(); printf('%J\n', { ok: false, error: error.message }); exit(1); }
lease?.close();
