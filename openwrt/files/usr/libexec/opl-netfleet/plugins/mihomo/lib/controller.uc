import { popen } from "fs";

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let test_profile, test_runtime, api_json, url_path_segment, proxies, controller_ready, controller_version, proxy_providers, test_group_path, nonempty_string, valid_port, project_connections, connections, select, unfix, proxy_port, probe, protected_probes, direct_probes;

const RUN_DIR = context.use("platform.runtime").RUN_DIR;
const API = context.use("platform.runtime").API;
const shell_quote = context.use("platform.process").shell_quote;
const proxy_authentication = context.use("platform.credentials").proxy_authentication;
const api_secret = context.use("platform.credentials").api_secret;

test_profile = function(path) {
	return system(`mihomo -d ${shell_quote(RUN_DIR)} -f ${shell_quote(path)} -t >/dev/null 2>&1`) == 0;
};

test_runtime = function() {
	return system(`mihomo -d ${shell_quote(RUN_DIR)} -t >/dev/null 2>&1`) == 0;
};

api_json = function(secret, path, timeout_seconds) {
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
		// A trailing newline after an exact 1024-byte JSON chunk is rejected
		// by ucode stream parsing. Parse the complete controller response.
		result = json(process.read("all"));
	} catch (error) {
		result = null;
	}
	process.close();
	return result;
};

url_path_segment = function(value) {
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

proxies = function(secret, timeout_seconds) {
	return api_json(secret, "/proxies", timeout_seconds);
};

controller_ready = function(secret, timeout_seconds) {
	const version = api_json(secret, "/version", timeout_seconds);
	return type(version) == "object" && type(version.version) == "string" &&
		length(version.version) > 0;
};

controller_version = function(secret, timeout_seconds) {
	if (!secret) return null;
	const value = api_json(secret, "/version", timeout_seconds)?.version;
	return type(value) == "string" && length(value) <= 128 ? value : null;
};

proxy_providers = function(secret, timeout_seconds) {
	return api_json(secret, "/providers/proxies", timeout_seconds);
};

test_group_path = function(secret, group, checks) {
	const latency = checks?.latency;
	if (!secret || type(group) != "string" || !length(group) || type(latency?.url) != "string" ||
		type(latency.timeout_ms) != "int" || latency.timeout_ms < 100 || latency.timeout_ms > 30000 ||
		type(latency.expected_status) != "int") return false;
	const path = `/proxies/${url_path_segment(group)}/delay?url=${url_path_segment(latency.url)}` +
		`&timeout=${latency.timeout_ms}&expected=${latency.expected_status}`;
	const state_path = `/proxies/${url_path_segment(group)}`;
	const snapshot = api_json(secret, state_path, 2);
	if (type(snapshot) != "object") return false;
	const before = snapshot.extra?.[latency.url]?.history;
	const previous_time = type(before) == "array" && length(before) ? before[length(before) - 1]?.time : null;
	const result = api_json(secret, path, int((latency.timeout_ms + 999) / 1000) + 3);
	// URLTest can return a delay despite an unexpected HTTP status, or 503
	// for a successful sub-millisecond test rounded to zero. Consult URL health.
	const health = api_json(secret, state_path, 2)?.extra?.[latency.url];
	if (health?.alive != true) return false;
	if (type(result?.delay) == "int" && result.delay >= 0) return true;
	const history = health?.history;
	const latest = type(history) == "array" && length(history) ? history[length(history) - 1] : null;
	return type(latest?.time) == "string" && latest.time != previous_time && latest.delay == 0;
};

nonempty_string = function(value) {
	return type(value) == "string" && length(value) > 0 ? value : null;
};

valid_port = function(value) {
	if (type(value) == "int") {
		return value > 0 && value < 65536 ? `${value}` : null;
	}
	if (type(value) == "string" && match(value, /^[0-9]+$/)) {
		const parsed = int(value);
		return parsed > 0 && parsed < 65536 ? `${parsed}` : null;
	}
	return null;
};

project_connections = function(payload, requested_limit) {
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

connections = function(secret, timeout_seconds) {
	const payload = api_json(secret, "/connections", timeout_seconds);
	return payload == null ? null : project_connections(payload, 50);
};

select = function(secret, group, choice) {
	const body = sprintf("%J", { name: choice });
	const endpoint = `${API}/proxies/${url_path_segment(group)}`;
	const command = `curl -fsS --connect-timeout 3 --max-time 5 -X PUT -H ${shell_quote(`Authorization: Bearer ${secret}`)} -H 'Content-Type: application/json' --data ${shell_quote(body)} ${shell_quote(endpoint)}`;
	return system(command) == 0;
};

unfix = function(secret, group, detail) {
	if (type(secret) != "string" || length(secret) == 0 ||
		type(group) != "string" || length(group) == 0) {
		if (detail != null) detail.error = "invalid_candidate_reset_request";
		return false;
	}
	const endpoint = `${API}/proxies/${url_path_segment(group)}`;
	// DELETE clears URLTest's cached choice and is idempotent. Retain only
	// bounded diagnostic fields, never response bodies, credentials or commands.
	const command = `curl -q -sS --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' -X DELETE -H ${shell_quote(`Authorization: Bearer ${secret}`)} ${shell_quote(endpoint)} 2>/dev/null`;
	for (let attempt = 1; attempt <= 2; attempt++) {
		const child = popen(command);
		const status = child == null ? 0 : int(trim(child.read("all")));
		const transport = child == null ? -1 : child.close();
		const ok = transport == 0 && status >= 200 && status < 300;
		if (detail != null) {
			detail.group = group; detail.http_status = status;
			detail.transport_code = transport; detail.attempts = attempt;
			detail.error = ok ? null : transport != 0 ? "candidate_reset_transport_failed" : "candidate_reset_http_failed";
		}
		if (ok) return true;
		if (index([7, 28, 52, 56], transport) < 0 &&
			!(transport == 0 && index([502, 503, 504], status) >= 0)) return false;
	}
	return false;
};

proxy_port = function(secret) {
	// Read the effective listener through Mihomo's JSON controller API.  Parsing
	// the generated YAML here would make the protection path depend on the
	// device's yq implementation; a missing controller value fails closed for
	// this probe and never changes the data plane.
	const config = api_json(secret, "/configs", 2);
	return valid_port(config?.["mixed-port"]) ?? valid_port(config?.port);
};

probe = function(policy, entry, through_proxy, limit_seconds) {
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

protected_probes = function(policy, limit_seconds) {
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
direct_probes = function(policy, limit_seconds) {
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

return { test_profile, test_runtime, url_path_segment, proxies, controller_ready, controller_version, proxy_providers, test_group_path, project_connections, connections, select, unfix, protected_probes, direct_probes };
};
