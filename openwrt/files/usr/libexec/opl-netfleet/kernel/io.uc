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
