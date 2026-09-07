import * as fs from 'fs';

export function shell_quote(value) { return "'" + replace('' + value, /'/g, "'\\''") + "'"; };
export function read_json(path) {
	try { return json(fs.readfile(path)); } catch (error) { return null; }
};
export function trusted(path, kind, owner) {
	const info = fs.lstat(path);
	return info?.type == kind && info.uid == (owner ?? 0) && !(info.mode & 022);
};
export function private_file(path) {
	const info = fs.lstat(path);
	return info?.type == 'file' && info.uid == 0 && !(info.mode & 077);
};
export function write_private(path, content) {
	const file = fs.open(path, 'w', 0600);
	if (file == null) return false;
	const ok = file.write(content) == length(content) && file.flush();
	file.close();
	return ok && fs.chmod(path, 0600);
};
export function mkdir_private(path, owner) {
	if (fs.lstat(path) == null && !fs.mkdir(path, 0700)) return false;
	return trusted(path, 'directory', owner);
};
export function atomic_json(path, value) {
	const text = sprintf('%J\n', value);
	const directory = fs.mkdtemp(`${path}.XXXXXX`);
	if (directory == null) return false;
	const name = `${directory}/value.json`;
	const temporary = fs.open(name, 'wxe', 0600);
	if (temporary == null) { fs.rmdir(directory); return false; }
	const written = temporary.write(text) == length(text) && temporary.flush();
	const closed = temporary.close();
	const ok = written && closed && fs.readfile(name) == text && fs.rename(name, path);
	fs.unlink(name);
	fs.rmdir(directory);
	return ok == true;
};
export function sha256(path) {
	const pipe = fs.popen(`sha256sum ${shell_quote(path)} 2>/dev/null`);
	if (pipe == null) return null;
	const output = trim(pipe.read('all') ?? '');
	const status = pipe.close();
	return status == 0 && match(output, /^[a-f0-9]{64} /) ? substr(output, 0, 64) : null;
};

// Package hooks may descend from a component updater already holding flock.
// Verify the actual ancestor descriptor and lock; environment flags grant nothing.
function ancestor_holds(path) {
	const target = fs.stat(path);
	let status = fs.readfile('/proc/self/status') ?? '';
	const visited = {};
	for (let count = 0; count < 64; count++) {
		const parent = match(status, /\nPPid:\s*(\d+)/)?.[1];
		if (parent == null || parent == '0' || visited[parent]) return false;
		visited[parent] = true;
		const base = `/proc/${parent}`;
		if (fs.stat(base)?.uid != 0) return false;
		for (let fd in fs.lsdir(`${base}/fdinfo`) ?? []) {
			const info = fs.stat(`${base}/fd/${fd}`);
			if (info?.inode != target?.inode || info?.dev?.major != target?.dev?.major || info?.dev?.minor != target?.dev?.minor) continue;
			if (match(fs.readfile(`${base}/fdinfo/${fd}`) ?? '', /lock:.*FLOCK\s+ADVISORY\s+WRITE\s/)) return true;
		}
		status = fs.readfile(`${base}/status`) ?? '';
	}
	return false;
};
export function network_lock(path, write) {
	if (fs.lstat(path) != null && !trusted(path, 'file')) return null;
	const file = fs.open(path, 'ae', 0600);
	if (file == null) return null;
	if (file.lock(write ? 'xn' : 'sn')) return { close: () => file.close() };
	file.close();
	return ancestor_holds(path) ? { close: () => true } : null;
};
export function process_identity(pid) {
	const path = pid == null ? '/proc/self' : `/proc/${pid}`;
	const status = fs.readfile(`${path}/status`) ?? '';
	const stat = fs.readfile(`${path}/stat`) ?? '';
	const fields = split(replace(stat, /^.*\) /, ''), ' ');
	return { pid: match(status, /(^|\n)Pid:\s*(\d+)/)?.[2], parent: match(status, /\nPPid:\s*(\d+)/)?.[1], start: fields[19] };
};
export function coordinator_parent(path) {
	if (!private_file(path)) return false;
	const coordinator = read_json(path);
	if (coordinator?.pid == null || coordinator?.start == null) return false;
	let current = process_identity();
	for (let count = 0; count < 64 && current.parent != null && current.parent != '0'; count++) {
		current = process_identity(current.parent);
		if (current.pid == coordinator.pid && current.start == coordinator.start && fs.stat(`/proc/${current.pid}`)?.uid == 0) return true;
	}
	return false;
};
