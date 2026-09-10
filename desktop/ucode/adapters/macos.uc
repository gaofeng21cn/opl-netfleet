import * as fs from 'fs';
import { rpc, process_identity } from '../bridge.uc';
import { trusted } from '../kernel/io.uc';

let locks = {};
export function create(root) {
	const state = getenv('NETFLEET_STATE_DIR');
	const identity = fs.popen('id -u');
	const owner = int(trim(identity?.read('all') ?? ''));
	if (identity == null || identity.close() != 0 || fs.stat(state)?.uid != owner || fs.lstat(state)?.type != 'directory' || (fs.stat(state).mode & 077)) die('desktop_state_unsafe');
	function private_file(path) { const info = fs.lstat(path); return trusted(path, 'file', owner) && !(info.mode & 077); }
	function network_lock(path, write) {
		if (locks[path] != null) {
			if (write && !locks[path].write) return null;
			locks[path].count++;
		} else {
			if (fs.lstat(path) != null && !private_file(path)) return null;
			const file = fs.open(path, 'ae', 0600);
			if (file == null || !file.lock(write ? 'xn' : 'sn')) { file?.close(); return null; }
			locks[path] = { file, count: 1, write };
		}
		let closed = false;
		return { close: () => {
			if (closed) return; closed = true;
			if (--locks[path].count == 0) { locks[path].file.close(); delete locks[path]; }
		} };
	}
	function inspect_digest(directory, files) {
		return rpc('code.digest', { directory, files }).digest;
	}
	return { trusted_owner: owner, paths: { installed_root: root, default_system: `${root}/system.json`,
		override: `${state}/system.json`, network_lock: `${state}/network.lock`, code_locks: `${state}/code-locks`,
		maintenance: `${state}/maintenance`, inspection_cache: `${state}/inspection` },
		private_file, network_lock, inspect_digest, process_identity,
		coordinator_parent: () => false, package_available: () => false,
		invoke_process: () => ({ ok: false, error: 'desktop_process_plugins_unsupported' }) };
}
