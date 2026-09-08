import * as fs from 'fs';
import { shell_quote as q, read_json, trusted, write_private } from '../kernel/io.uc';

const OWNER = 0;
const PATHS = {
	installed_root: '/usr/libexec/opl-netfleet',
	default_system: '/usr/share/opl-netfleet/system.json',
	override: '/etc/opl-netfleet/system.json',
	network_lock: '/var/lock/opl-netfleet-deploy.lock',
	code_locks: '/var/lock/opl-netfleet-code',
	maintenance: '/var/run/opl-netfleet-plugin-maintenance',
	inspection_cache: '/tmp/opl-netfleet-plugin-inspection',
};

function failure(error) { return { ok: false, error: error }; };
function private_file(path) {
	const info = fs.lstat(path);
	return trusted(path, 'file', OWNER) && !(info.mode & 077);
};

// Inherited mutation authority requires an ancestor's actual descriptor and lock.
function ancestor_holds(path) {
	const target = fs.stat(path);
	let status = fs.readfile('/proc/self/status') ?? '';
	const visited = {};
	for (let count = 0; count < 64; count++) {
		const parent = match(status, /\nPPid:\s*(\d+)/)?.[1];
		if (parent == null || parent == '0' || visited[parent]) return false;
		visited[parent] = true;
		const base = `/proc/${parent}`;
		if (fs.stat(base)?.uid != OWNER) return false;
		for (let fd in fs.lsdir(`${base}/fdinfo`) ?? []) {
			const info = fs.stat(`${base}/fd/${fd}`);
			if (info?.inode != target?.inode || info?.dev?.major != target?.dev?.major || info?.dev?.minor != target?.dev?.minor) continue;
			if (match(fs.readfile(`${base}/fdinfo/${fd}`) ?? '', /lock:.*FLOCK\s+ADVISORY\s+WRITE\s/)) return true;
		}
		status = fs.readfile(`${base}/status`) ?? '';
	}
	return false;
};
function network_lock(path, write) {
	if (fs.lstat(path) != null && !trusted(path, 'file', OWNER)) return null;
	const file = fs.open(path, 'ae', 0600);
	if (file == null) return null;
	if (file.lock(write ? 'xn' : 'sn')) return { close: () => file.close() };
	file.close();
	return ancestor_holds(path) ? { close: () => true } : null;
};
function process_identity(pid) {
	const path = pid == null ? '/proc/self' : `/proc/${pid}`;
	const status = fs.readfile(`${path}/status`) ?? '';
	const stat = fs.readfile(`${path}/stat`) ?? '';
	const fields = split(replace(stat, /^.*\) /, ''), ' ');
	return { pid: match(status, /(^|\n)Pid:\s*(\d+)/)?.[2], parent: match(status, /\nPPid:\s*(\d+)/)?.[1], start: fields[19] };
};
function coordinator_parent(path) {
	if (!private_file(path)) return false;
	const coordinator = read_json(path);
	if (coordinator?.pid == null || coordinator?.start == null) return false;
	let current = process_identity();
	for (let count = 0; count < 64 && current.parent != null && current.parent != '0'; count++) {
		current = process_identity(current.parent);
		if (current.pid == coordinator.pid && current.start == coordinator.start && fs.stat(`/proc/${current.pid}`)?.uid == OWNER) return true;
	}
	return false;
};
function package_available(name) {
	return system(`apk --no-network info -e ${q(name)} >/dev/null 2>&1 || opkg status ${q(name)} 2>/dev/null | grep -q '^Status: .* installed$'`) == 0;
};
function inspect_digest(directory, files) {
	const pipe = fs.popen(`cd ${q(directory)} && sha256sum ${join(' ', map(files, path => q(substr(path, length(directory) + 1))))} 2>/dev/null`);
	if (pipe == null) return null;
	const identities = pipe.read('all'), status = pipe.close();
	if (status != 0 || type(identities) != 'string' || length(identities) == 0) return null;
	const digest_pipe = fs.popen(`printf '%s' ${q(identities)} | sha256sum`);
	if (digest_pipe == null) return null;
	const output = trim(digest_pipe.read('all') ?? ''), digest_status = digest_pipe.close();
	return digest_status == 0 && match(output, /^[a-f0-9]{64} /) ? substr(output, 0, 64) : null;
};
function invoke_process(entry, action, envelope, limit) {
	const work = fs.mkdtemp('/tmp/opl-netfleet-plugin.XXXXXX');
	if (work == null) return failure('plugin_request_unavailable');
	const request = `${work}/request.json`, status_path = `${work}/exit`;
	let result;
	try {
		if (!fs.chmod(work, 0700) || !write_private(request, sprintf('%J', envelope)))
			result = failure('plugin_request_unavailable');
		else {
			// Bound stdout without restricting files owned by the plugin.
			const command = `{ ${q(entry)} ${q(action)} ${q(request)} 2>/dev/null; printf '%s' "$?" >${q(status_path)}; } | head -c ${limit + 1}`;
			const pipe = fs.popen(`timeout -k 2 30 sh -c ${q(command)} 2>/dev/null`);
			if (pipe == null) result = failure('plugin_no_response');
			else {
				const output = pipe.read('all'), status = pipe.close();
				result = status == 124 || status == 137 ? failure('plugin_timeout') :
					{ ok: true, output: output, status: status, exit_status: trim(fs.readfile(status_path) ?? '') };
			}
		}
	} catch (error) { result = failure('plugin_execution_failed'); }
	fs.unlink(request); fs.unlink(status_path); fs.rmdir(work);
	return result;
};

export function create(root) {
	const adjacent = `${root ?? PATHS.installed_root}/../../share/opl-netfleet/system.json`;
	return { paths: { ...PATHS, default_system: fs.lstat(adjacent) != null ? adjacent : PATHS.default_system }, trusted_owner: OWNER,
		private_file: private_file, network_lock: network_lock, process_identity: process_identity,
		coordinator_parent: coordinator_parent, package_available: package_available,
		inspect_digest: inspect_digest, invoke_process: invoke_process };
};
