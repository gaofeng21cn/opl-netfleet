import { lstat, readfile } from "fs";

const CONFIG = "/etc/opl-netfleet/backend.json";

function configured_backend() {
	const info = lstat(CONFIG);
	if (info == null) return "nikki-mihomo";
	if (info.type != "file" || info.uid != 0 || (info.mode & 077) != 0)
		throw "unsafe_backend_configuration";
	let config = null;
	try { config = json(readfile(CONFIG)); } catch (error) { throw "invalid_backend_configuration"; }
	if (type(config) != "object" || length(keys(config)) != 1 ||
		index(["nikki-mihomo", "native-mihomo"], config.kind) < 0)
		throw "invalid_backend_configuration";
	return config.kind;
};

export const KIND = configured_backend();
export const UCI_PACKAGE = KIND == "native-mihomo" ? "netfleet" : "nikki";
export const ROOT_DIR = KIND == "native-mihomo" ? "/etc/opl-netfleet/native" : "/etc/nikki";
export const RUN_DIR = `${ROOT_DIR}/run`;
export const SERVICE = KIND == "native-mihomo" ? "opl-netfleet-core" : "nikki";
export const NFT_TABLE = UCI_PACKAGE;
export const STATE_DIR = `/var/run/${UCI_PACKAGE}`;
export const LOG_PATH = `/var/log/${UCI_PACKAGE}/core.log`;
export const API = "http://127.0.0.1:9090";

export function metadata() {
	return { id: KIND, display_name: KIND == "native-mihomo" ? "NetFleet + Mihomo" : "Nikki + Mihomo" };
};
