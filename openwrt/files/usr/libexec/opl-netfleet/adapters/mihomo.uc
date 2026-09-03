import { popen } from "fs";
import { shell_quote, proxy_authentication, api_secret } from "./uci.uc";

const RUN_DIR = "/etc/nikki/run";
const API = "http://127.0.0.1:9090";

export function test_profile(path) {
	return system(`mihomo -d ${shell_quote(RUN_DIR)} -f ${shell_quote(path)} -t >/dev/null 2>&1`) == 0;
};

export function test_runtime() {
	return system(`mihomo -d ${shell_quote(RUN_DIR)} -t >/dev/null 2>&1`) == 0;
};

function api_json(secret, path, timeout_seconds) {
	const requested = type(timeout_seconds) == "int" && timeout_seconds > 0 ? timeout_seconds : 5;
	// OpenWrt curl 8.19 rejects a one-second total budget before a local
	// controller request is dispatched ("remaining timeout too small").  Two
	// seconds remains bounded and does not add latency to successful reads.
	const timeout = requested < 2 ? 2 : requested;
	const command = `curl -fsS --connect-timeout ${timeout} --max-time ${timeout} -H ${shell_quote(`Authorization: Bearer ${secret}`)} ${shell_quote(`${API}${path}`)}`;
	const process = popen(command);
	if (!process) {
		return null;
	}
	let result = null;
	try {
		result = json(process);
	} catch (error) {
		result = null;
	}
	process.close();
	return result;
};

export function url_path_segment(value) {
	let result = "";
	const text = `${value}`;
	for (let i = 0; i < length(text); i++) {
		const byte = ord(substr(text, i, 1));
		const unreserved = (byte >= 48 && byte <= 57) ||
			(byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
			byte == 45 || byte == 46 || byte == 95 || byte == 126;
		result += unreserved ? chr(byte) : sprintf("%%%02X", byte);
	}
	return result;
};

export function proxies(secret, timeout_seconds) {
	return api_json(secret, "/proxies", timeout_seconds);
};

export function controller_ready(secret, timeout_seconds) {
	const version = api_json(secret, "/version", timeout_seconds);
	return type(version) == "object" && type(version.version) == "string" &&
		length(version.version) > 0;
};

export function proxy_providers(secret, timeout_seconds) {
	return api_json(secret, "/providers/proxies", timeout_seconds);
};

function nonempty_string(value) {
	return type(value) == "string" && length(value) > 0 ? value : null;
};

function valid_port(value) {
	if (type(value) == "int") {
		return value > 0 && value < 65536 ? `${value}` : null;
	}
	if (type(value) == "string" && match(value, /^[0-9]+$/)) {
		const parsed = int(value);
		return parsed > 0 && parsed < 65536 ? `${parsed}` : null;
	}
	return null;
};

export function project_connections(payload, requested_limit) {
	const source = type(payload?.connections) == "array" ? payload.connections : [];
	const limit = type(requested_limit) == "int" && requested_limit > 0 && requested_limit <= 50 ? requested_limit : 50;
	const result = [];
	let scanned = 0;
	for (let i = 0; i < length(source) && length(result) < limit; i++) {
		scanned++;
		const entry = source[i];
		const metadata = entry?.metadata;
		const host = nonempty_string(metadata?.host);
		const destination = host ?? nonempty_string(metadata?.destinationIP);
		if (destination == null) continue;
		const chains = [];
		if (type(entry?.chains) == "array") {
			for (let j = 0; j < length(entry.chains); j++) {
				const chain = nonempty_string(entry.chains[j]);
				if (chain != null) push(chains, chain);
			}
		}
		push(result, {
			destination: destination,
			destination_port: valid_port(metadata?.destinationPort),
			network: nonempty_string(metadata?.network),
			rule: nonempty_string(entry?.rule),
			rule_payload: nonempty_string(entry?.rulePayload),
			chains: chains
		});
	}
	return {
		connections: result,
		count: length(result),
		truncated: scanned < length(source),
		read_at: int(time())
	};
};

export function connections(secret, timeout_seconds) {
	const payload = api_json(secret, "/connections", timeout_seconds);
	return payload == null ? null : project_connections(payload, 50);
};

export function select(secret, group, choice) {
	const body = sprintf("%J", { name: choice });
	const endpoint = `${API}/proxies/${url_path_segment(group)}`;
	const command = `curl -fsS --connect-timeout 3 --max-time 5 -X PUT -H ${shell_quote(`Authorization: Bearer ${secret}`)} -H 'Content-Type: application/json' --data ${shell_quote(body)} ${shell_quote(endpoint)}`;
	return system(command) == 0;
};

export function unfix(secret, group) {
	if (type(secret) != "string" || length(secret) == 0 ||
		type(group) != "string" || length(group) == 0) {
		return false;
	}
	const endpoint = `${API}/proxies/${url_path_segment(group)}`;
	const command = `curl -fsS --connect-timeout 2 --max-time 5 -X DELETE -H ${shell_quote(`Authorization: Bearer ${secret}`)} ${shell_quote(endpoint)}`;
	return system(command) == 0;
};

function proxy_port(secret) {
	// Read the effective listener through Mihomo's JSON controller API.  Parsing
	// the generated YAML here would make the protection path depend on the
	// device's yq implementation; a missing controller value fails closed for
	// this probe and never changes the data plane.
	const config = api_json(secret, "/configs", 2);
	return valid_port(config?.["mixed-port"]) ?? valid_port(config?.port);
};

function probe(policy, entry, through_proxy, limit_seconds) {
	let command = "curl -4 -L -sS";
	if (through_proxy) {
		const port = proxy_port(api_secret());
		if (port == null) {
			return null;
		}
		const auth = proxy_authentication();
		const auth_arg = auth == null ? "" : `--proxy-user ${shell_quote(`${auth.username}:${auth.password}`)}`;
		command += ` --noproxy '' --proxy ${shell_quote(`http://127.0.0.1:${port}`)} ${auth_arg}`;
	} else {
		// This path is used only after Nikki's official stop/cleanup.  It must
		// bypass both explicit proxy environment variables and local proxying.
		command += " --noproxy '*' --proxy ''";
	}
	const max_time = type(limit_seconds) == "int" && limit_seconds > 0 ? limit_seconds : 8;
	const connect_time = max_time < 3 ? max_time : 3;
	command += ` --connect-timeout ${connect_time} --max-time ${max_time} -o /dev/null -w '%{http_code}' ${shell_quote(entry.url)}`;
	const process = popen(command);
	if (!process) {
		return null;
	}
	const status = process.read("line");
	process.close();
	return status ? trim(status) : null;
};

export function protected_probes(policy, limit_seconds) {
	const probes = policy?.fail_open?.probes;
	if (type(probes) != "array" || length(probes) == 0) {
		return { ok: false, error: "protected_probes_missing" };
	}
	for (let i = 0; i < length(probes); i++) {
		const entry = probes[i];
		const status = probe(policy, entry, true, limit_seconds);
		const expected = `${entry?.expected_status ?? ""}`;
		if (status != expected) {
			return {
				ok: false,
				error: "protected_probe_failed",
				probe: entry?.id ?? i,
				expected_status: expected,
				actual_status: status
			};
		}
	}
	return { ok: true, count: length(probes) };
};

// Direct probes are deliberately separate from protected proxy probes.  They
// are a readback of emergency passthrough after Nikki cleanup, never an input
// to selection or a reason to rewrite DNS/nft state.
export function direct_probes(policy, limit_seconds) {
	const probes = policy?.fail_open?.probes;
	if (type(probes) != "array" || length(probes) == 0) {
		return { ok: false, error: "protected_probes_missing" };
	}
	for (let i = 0; i < length(probes); i++) {
		const entry = probes[i];
		const status = probe(policy, entry, false, limit_seconds);
		const expected = `${entry?.expected_status ?? ""}`;
		if (status != expected) {
			return {
				ok: false,
				error: "direct_probe_failed",
				probe: entry?.id ?? i,
				expected_status: expected,
				actual_status: status
			};
		}
	}
	return { ok: true, count: length(probes) };
};
