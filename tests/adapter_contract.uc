#!/usr/bin/ucode
import { use, release as release_services } from "./services.uc";

const measure = use("mihomo.latency").measure;
const controller_timeout_seconds = use("mihomo.latency").controller_timeout_seconds;
const complete_from_fresh_history = use("mihomo.latency").complete_from_fresh_history;
const url_path_segment = use("mihomo.controller").url_path_segment;
const project_connections = use("mihomo.controller").project_connections;
const read_json = use("platform.storage").read_json;
const read_yaml = use("platform.storage").read_yaml;
const write_json_atomic = use("platform.storage").write_json_atomic;
import { writefile, unlink } from "fs";

if (url_path_segment("常规 出口") != "%E5%B8%B8%E8%A7%84%20%E5%87%BA%E5%8F%A3" ||
	url_path_segment("a-z_1.2") != "a-z_1.2") {
	print("controller_path_encoding_failed\n");
	exit(1);
}

const projected_connections = project_connections({ connections: [{
	id: "private-id",
	metadata: {
		host: "example.com",
		sourceIP: "192.0.2.10",
		destinationIP: "198.51.100.20",
		destinationPort: "443",
		network: "tcp",
		process: "private-process"
	},
	rule: "RuleSet",
	rulePayload: "youtube-domain",
	chains: ["YouTube", "海外加速"],
	upload: 1234
}] }, 50);
const projected_connection = projected_connections.connections[0];
if (projected_connections.count != 1 || projected_connection.destination != "example.com" ||
	projected_connection.destination_port != "443" || projected_connection.network != "tcp" ||
	projected_connection.rule != "RuleSet" || projected_connection.rule_payload != "youtube-domain" ||
	length(projected_connection.chains) != 2 || projected_connection.id != null ||
	projected_connection.sourceIP != null || projected_connection.process != null ||
	projected_connection.upload != null) {
	print("connections_projection_failed\n");
	exit(1);
}

const limited_connections = project_connections({ connections: [
	{ metadata: { destinationIP: "198.51.100.1" }, chains: [] },
	{ metadata: { destinationIP: "198.51.100.2" }, chains: [] }
] }, 1);
if (limited_connections.count != 1 || limited_connections.truncated != true) {
	print("connections_limit_failed\n");
	exit(1);
}

const latency = measure(null, "fixture", {
	latency: {
		method: "mihomo_delay",
		url: "https://www.gstatic.com/generate_204",
		timeout_ms: 2000,
		expected_status: 204
	}
});
if (controller_timeout_seconds(2000) != 5 || controller_timeout_seconds(1) != 4 ||
	controller_timeout_seconds(60000) != 30) {
	print("latency_controller_timeout_failed\n");
	exit(1);
}
if (latency.status != "unavailable" || latency.method != "mihomo_delay" ||
	latency.reason != "invalid_input") {
	print("latency_adapter_failed\n");
	exit(1);
}

const speed_url = 'https://www.gstatic.com/generate_204';
function group_health(time, delay, alive) {
	return { alive: !alive, now: 'leaf', all: ['leaf'], history: [{time: 'unrelated', delay: 1}],
		extra: { [speed_url]: { alive, history: [{ time, delay }] } } };
}
const completed = complete_from_fresh_history({
	results: { current: { status: "ok", delay_ms: 10 } }
}, {
	proxies: {
		fresh: group_health('before', 80, true),
		stale: group_health('same', 20, true)
	}
}, {
	proxies: {
		current: group_health('after', 10, true),
		fresh: group_health('after', 30, true),
		startup: group_health('startup', 25, true),
		stale: group_health('same', 20, true),
		failed: group_health('after', 0, false)
	}
}, ["current", "fresh", "startup", "stale", "failed"], {
	latency: { url: "https://www.gstatic.com/generate_204", expected_status: 204 }
});
if (completed.results.current?.delay_ms != 10 || completed.results.fresh?.delay_ms != 30 ||
	completed.results.startup?.delay_ms != 25 ||
	completed.results.stale != null || completed.results.failed != null) {
	print("fresh_group_history_completion_failed\n");
	exit(1);
}

const rejected = complete_from_fresh_history({ results: { bad: { status: 'ok', delay_ms: 12 }, missing: { status: 'ok', delay_ms: 10 } } },
	{ proxies: {} }, { proxies: { bad: group_health('after', 12, false), missing: { alive: true, now: 'leaf', all: ['leaf'] } } },
	['bad', 'missing'], { latency: { url: speed_url, expected_status: 204 } });
if (length(keys(rejected.results))) die('delay_response_bypassed_url_health');

const atomic_path = "/tmp/opl-netfleet-atomic-contract.json";
if (!write_json_atomic(atomic_path, { schema: 1, value: "current" }) ||
	read_json(atomic_path)?.value != "current") {
	print("atomic_json_write_failed\n");
	exit(1);
}
system(`rm -f ${atomic_path}`);

const read_path = "/tmp/opl-netfleet-read-contract.yaml";
writefile(read_path, '{"proxies":[],"mode":"rule","enabled":false}');
if (read_json(read_path)?.mode != "rule" || read_yaml(read_path, true)?.enabled !== false ||
	read_json("/tmp") != null || read_yaml("/tmp/opl-netfleet-missing-read-contract", true) != null) {
	print("native_json_read_failed\n"); exit(1);
}
writefile(read_path, "mode: rule\nproxies: []\nenabled: false\n");
if (read_json(read_path) != null || read_yaml(read_path, true)?.mode != "rule") {
	print("yaml_read_fallback_failed\n"); exit(1);
}
writefile(read_path, "broken: [");
if (read_yaml(read_path, true) != null) { print("malformed_yaml_accepted\n"); exit(1); }
unlink(read_path);

print("adapter_contract_ok\n");

release_services();
