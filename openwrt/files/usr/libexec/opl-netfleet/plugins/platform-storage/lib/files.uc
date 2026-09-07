import * as fs from "fs";

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let private_file, private_directory, write_private, atomic_json, core_service;

const read_json = context.use("platform.storage").read_json;
const sha256 = context.use("platform.storage").sha256;

const BASE = "/etc/opl-netfleet/native";
const SERVICE = "opl-netfleet-core";

private_file = function(path) {
	const info = type(path) == "string" ? fs.lstat(path) : null;
	return info?.type == "file" && info.uid == 0 && (info.mode & 077) == 0;
};

private_directory = function(path) {
	const info = fs.lstat(path);
	return info?.type == "directory" && info.uid == 0 && (info.mode & 077) == 0;
};

write_private = function(path, content) {
	const file = fs.open(path, "w", 0600);
	if (file == null) return false;
	const written = file.write(content);
	const closed = file.close();
	return written == length(content) && closed == true && fs.chmod(path, 0600) == true;
};

atomic_json = function(path, value) {
	const temporary = `${path}.tmp`;
	if (fs.lstat(temporary) != null && !private_file(temporary)) return false;
	const content = sprintf("%J", value);
	if (!write_private(temporary, content) || read_json(temporary) == null) {
		fs.unlink(temporary);
		return false;
	}
	const digest = sha256(temporary);
	if (digest == null || !fs.rename(temporary, path)) {
		fs.unlink(temporary);
		return false;
	}
	return sha256(path) == digest;
};

core_service = function() {
	const process = fs.popen('ubus call service list \'{"name":"opl-netfleet-core"}\' 2>/dev/null');
	if (process == null) return { ok: false };
	let result = null;
	try { result = json(process); } catch (error) {}
	if (process.close() != 0 || type(result) != "object") return { ok: false };
	return { ok: true, service: result[SERVICE] };
};

return { BASE, SERVICE, private_file, private_directory, write_private, atomic_json, core_service };
};
