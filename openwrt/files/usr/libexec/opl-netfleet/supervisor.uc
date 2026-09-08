#!/usr/bin/ucode

import * as fs from 'fs';

const root = sourcepath(0, true), states = {};
while (true) {
	let lease, delay = 5000;
	try {
		let ready = true;
		if (root == '/usr/libexec/opl-netfleet') {
			const directory = '/var/lock/opl-netfleet-code';
			if (fs.lstat(directory) == null) fs.mkdir(directory, 0700);
			const info = fs.lstat(directory), path = `${directory}/.kernel.lock`, file = fs.lstat(path);
			if (info?.type != 'directory' || info.uid != 0 || (info.mode & 022) ||
				(file != null && (file.type != 'file' || file.uid != 0 || (file.mode & 022)))) die('plugin_kernel_lock_unsafe');
			lease = fs.open(path, 'ae', 0600);
			ready = lease != null && lease.lock('sn') && fs.lstat('/var/run/opl-netfleet-plugin-maintenance/.kernel') == null;
		}
		if (ready) delay = loadstring(sprintf('import { tick } from %J; import { create } from %J; return (root, states) => tick(root, states, { adapter: create(root) });',
			`${root}/kernel/host.uc`, `${root}/adapters/openwrt.uc`))()(root, states);
	} catch (error) { warn(`NetFleet supervisor: ${error.message}\n`); }
	lease?.close();
	// Reclaim cycles from hot-loaded factories and closed scopes after each tick.
	// Only the explicitly retained scheduler state survives between iterations.
	gc();
	sleep(delay);
}
