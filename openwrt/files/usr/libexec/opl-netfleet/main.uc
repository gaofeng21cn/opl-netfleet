#!/usr/bin/ucode

import * as fs from 'fs';

const root = sourcepath(0, true);
let lease;
if (root == '/usr/libexec/opl-netfleet') {
	const directory = '/var/lock/opl-netfleet-code';
	if (fs.lstat(directory) == null) fs.mkdir(directory, 0700);
	const info = fs.lstat(directory), path = `${directory}/.kernel.lock`, file = fs.lstat(path);
	if (info?.type != 'directory' || info.uid != 0 || (info.mode & 022) ||
		(file != null && (file.type != 'file' || file.uid != 0 || (file.mode & 022)))) die('plugin_kernel_lock_unsafe');
	lease = fs.open(path, 'ae', 0600);
	if (lease == null || !lease.lock('sn') || fs.lstat('/var/run/opl-netfleet-plugin-maintenance/.kernel') != null) {
		lease?.close(); printf('%J\n', { ok: false, error: 'plugin_kernel_maintenance' }); exit(1);
	}
}
// Load the replaceable kernel only after pinning its complete file generation.
try { loadstring(sprintf('import { run } from %J; return run;', `${root}/kernel/host.uc`))()(ARGV, root); }
catch (error) { lease?.close(); printf('%J\n', { ok: false, error: error.message }); exit(1); }
lease?.close();
