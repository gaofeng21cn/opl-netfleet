import { cursor } from "uci";
import { stat } from "fs";
import { UCI_PACKAGE, RUN_DIR } from "../adapters/runtime.uc";
import { read_yaml } from "../adapters/uci.uc";

export function get() {
	const profile = read_yaml(`${RUN_DIR}/config.yaml`, true);
	const uci = cursor();
	const listen = profile?.["external-controller"] ?? uci.get(UCI_PACKAGE, "mixin", "api_listen");
	const endpoint = type(listen) == "string" ? match(listen, /:([0-9]+)$/) : null;
	const port = endpoint == null ? null : int(endpoint[1]);
	const path = profile?.["external-ui"];
	const directory = type(path) == "string" ? (substr(path, 0, 1) == "/" ? path : `${RUN_DIR}/${path}`) : null;
	return { ok: true, result: {
		available: port > 0 && port <= 65535 && directory != null && stat(`${directory}/index.html`)?.type == "file",
		protocol: "http", port: port, path: "/ui/",
		secret: profile?.secret ?? uci.get(UCI_PACKAGE, "mixin", "api_secret") ?? ""
	} };
};
