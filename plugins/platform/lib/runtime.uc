import { lstat, readfile } from "fs";

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let configured_backend, metadata, environment;



const CONFIG = "/etc/opl-netfleet/backend.json";

configured_backend = function() {
	const info = lstat(CONFIG);
	if (info == null) return "nikki-mihomo";
	if (info.type != "file" || info.uid != 0 || (info.mode & 077) != 0)
		die("unsafe_backend_configuration");
	let config = null;
	try { config = json(readfile(CONFIG)); } catch (error) { die("invalid_backend_configuration"); }
	if (type(config) != "object" || length(keys(config)) != 1 ||
		index(["nikki-mihomo", "native-mihomo"], config.kind) < 0)
		die("invalid_backend_configuration");
	return config.kind;
};

const KIND = configured_backend();
const UCI_PACKAGE = KIND == "native-mihomo" ? "netfleet" : "nikki";
const ROOT_DIR = KIND == "native-mihomo" ? "/etc/opl-netfleet/native" : "/etc/nikki";
const RUN_DIR = `${ROOT_DIR}/run`;
const SERVICE = KIND == "native-mihomo" ? "opl-netfleet-core" : "nikki";
const NFT_TABLE = UCI_PACKAGE;
const STATE_DIR = `/var/run/${UCI_PACKAGE}`;
const LOG_PATH = `/var/log/${UCI_PACKAGE}/core.log`;
const API = "http://127.0.0.1:9090";

metadata = function() {
	return { id: KIND, display_name: KIND == "native-mihomo" ? "NetFleet + Mihomo" : "Nikki + Mihomo" };
};

environment = function() { return { backend: KIND }; };

const SUBSCRIPTION_CONFIG_PATH = KIND == "native-mihomo" ? "/etc/config/netfleet" : null;
return { SUBSCRIPTION_CONFIG_PATH, KIND, UCI_PACKAGE, ROOT_DIR, RUN_DIR, SERVICE, NFT_TABLE, STATE_DIR, LOG_PATH, API, metadata, environment };
};
