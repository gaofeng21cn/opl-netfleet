import * as fs from 'fs';
const rpc = global.__netfleetDesktopOwner.rpc;
return function(context) {
	const storage = context.use('platform.storage');
	const state = getenv('NETFLEET_STATE_DIR'), owner = fs.stat(state).uid;
	function private_file(path) { const info = fs.lstat(path); return info?.type == 'file' && info.uid == owner && !(info.mode & 077); }
	function private_directory(path) { const info = fs.lstat(path); return info?.type == 'directory' && info.uid == owner && !(info.mode & 077); }
	function write_private(path, content) {
		if (fs.lstat(path) != null && !private_file(path)) return false;
		const file = fs.open(path, 'w', 0600);
		if (file == null) return false;
		const written = file.write(content); return file.close() && written == length(content) && fs.chmod(path, 0600);
	}
	function atomic_json(path, value) {
		const temporary = `${path}.tmp`;
		if (!write_private(temporary, sprintf('%J', value)) || storage.read_json(temporary) == null) { fs.unlink(temporary); return false; }
		return fs.rename(temporary, path);
	}
	return { BASE: `${state}/backend`, SERVICE: 'opl-netfleet-desktop', private_file, private_directory, write_private, atomic_json,
		core_service: () => ({ ok: true, service: rpc('core.status').running ? { running: true } : null }) };
};
