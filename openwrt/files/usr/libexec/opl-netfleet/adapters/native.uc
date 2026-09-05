import * as fs from "fs";
import { read_json, sha256 } from "./uci.uc";

export const BASE = "/etc/opl-netfleet/native";
export const CACHE = `${BASE}/cache`;
export const CORE = `${BASE}/core`;
export const SERVICE = "opl-netfleet-core";
export const LOCK = "/var/lock/opl-netfleet-deploy.lock";
export const COMMAND = ["/usr/bin/mihomo", "-d", CORE, "-f", `${CORE}/config.json`];

export function private_file(path) {
	const info = type(path) == "string" ? fs.lstat(path) : null;
	return info?.type == "file" && info.uid == 0 && (info.mode & 077) == 0;
};

export function private_directory(path) {
	const info = fs.lstat(path);
	return info?.type == "directory" && info.uid == 0 && (info.mode & 077) == 0;
};

export function write_private(path, content) {
	const file = fs.open(path, "w", 0600);
	if (file == null) return false;
	const written = file.write(content);
	const closed = file.close();
	return written == length(content) && closed == true && fs.chmod(path, 0600) == true;
};

export function atomic_json(path, value) {
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

export function core_service() {
	const process = fs.popen('ubus call service list \'{"name":"opl-netfleet-core"}\' 2>/dev/null');
	if (process == null) return { ok: false };
	let result = null;
	try { result = json(process); } catch (error) {}
	if (process.close() != 0 || type(result) != "object") return { ok: false };
	return { ok: true, service: result[SERVICE] };
};

export function owned_service(service) {
	const instances = service?.instances;
	return type(instances) == "object" && length(keys(instances)) == 1 &&
		sprintf("%J", instances?.core?.command) == sprintf("%J", COMMAND);
};
