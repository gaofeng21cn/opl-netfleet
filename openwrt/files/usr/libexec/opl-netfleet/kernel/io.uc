import * as fs from 'fs';

export function shell_quote(value) { return "'" + replace('' + value, /'/g, "'\\''") + "'"; };
export function read_json(path) {
	try { return json(fs.readfile(path)); } catch (error) { return null; }
};
export function trusted(path, kind, owner) {
	const info = fs.lstat(path);
	return type(owner) == 'int' && info?.type == kind && info.uid == owner && !(info.mode & 022);
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
export function mkdtemp(template) {
	if (type(fs.mkdtemp) == 'function') return fs.mkdtemp(template);
	if (type(template) != 'string') return null;
	const prefix = replace(template, /X+$/, '');
	if (prefix == template) return null;
	const count = length(template) - length(prefix);
	const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
	const rng = fs.open('/dev/urandom', 'r');
	let seq = 0;
	for (let attempt = 0; attempt < 64; attempt++) {
		let suffix = '';
		const bytes = rng ? rng.read(count) : null;
		for (let i = 0; i < count; i++) {
			const v = bytes != null && i < length(bytes) ? ord(substr(bytes, i, 1)) : ((time() * 31 + attempt * 17 + i * 13 + (++seq)) & 255);
			suffix += substr(alphabet, v % 62, 1);
		}
		const candidate = prefix + suffix;
		if (fs.mkdir(candidate, 0700)) { rng?.close(); return candidate; }
	}
	rng?.close();
	return null;
};
export function atomic_text(path, text) {
	const directory = mkdtemp(`${path}.XXXXXX`);
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
export function atomic_json(path, value) {
	return atomic_text(path, sprintf('%J\n', value));
};
