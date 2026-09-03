import { popen } from "fs";
import { shell_quote } from "./uci.uc";
import { url_path_segment } from "./mihomo.uc";

const API = "http://127.0.0.1:9090";

export function controller_timeout_seconds(timeout_ms) {
	let seconds = int((timeout_ms + 999) / 1000) + 3;
	if (seconds < 4) {
		seconds = 4;
	} else if (seconds > 30) {
		seconds = 30;
	}
	return seconds;
};

export function measure_providers(secret, sources, checks) {
	if (type(secret) != "string" || length(secret) == 0 || type(sources) != "array" ||
		length(sources) == 0 || type(checks?.provider_healthcheck_timeout_ms) != "int") {
		return false;
	}
	const provider_timeout = checks.provider_healthcheck_timeout_ms;
	let max_time = int((provider_timeout + 999) / 1000);
	if (max_time < 1) {
		max_time = 1;
	} else if (max_time > 30) {
		max_time = 30;
	}
	const jobs = [];
	for (let i = 0; i < length(sources); i++) {
		const source = sources[i];
		if (type(source) != "string" || length(source) == 0) {
			return false;
		}
		const endpoint = `${API}/providers/proxies/${source}/healthcheck`;
		push(jobs, `curl -fsS --connect-timeout 2 --max-time ${max_time} -H ${shell_quote(`Authorization: Bearer ${secret}`)} ${shell_quote(endpoint)} >/dev/null 2>&1 & pids="$pids $!";`);
	}
	// Trigger providers concurrently, but retain their real completion status.
	// A failed provider does not cancel the other measurements.
	const command = `pids=""; failed=0; ${join(" ", jobs)} ` +
		`for pid in $pids; do wait "$pid" || failed=1; done; exit "$failed"`;
	return system(`sh -c ${shell_quote(command)}`) == 0;
};

export function measure(secret, group, checks) {
	const latency = checks?.latency ?? {};
	const url = latency.url;
	const timeout_ms = latency.timeout_ms;
	const expected_status = latency.expected_status;
	if (latency.method != "mihomo_delay" || type(secret) != "string" || length(secret) == 0 ||
		type(group) != "string" || length(group) == 0 || type(url) != "string" ||
		type(timeout_ms) != "int" || type(expected_status) != "int") {
		return { method: "mihomo_delay", status: "unavailable", reason: "invalid_input", results: {} };
	}

	const max_time = controller_timeout_seconds(timeout_ms);
	const command = `curl -fsS --connect-timeout 2 --max-time ${max_time} ` +
		`-H ${shell_quote(`Authorization: Bearer ${secret}`)} --get ` +
		`--data-urlencode ${shell_quote(`url=${url}`)} ` +
		`--data-urlencode ${shell_quote(`timeout=${timeout_ms}`)} ` +
		`--data-urlencode ${shell_quote(`expected=${expected_status}`)} ` +
		shell_quote(`${API}/group/${url_path_segment(group)}/delay`);
	const process = popen(command);
	if (!process) {
		return { method: "mihomo_delay", status: "unavailable", reason: "controller_unavailable", results: {} };
	}
	let result = null;
	try {
		result = json(process);
	} catch (error) {
		result = null;
	}
	process.close();
	if (type(result) != "object") {
		return { method: "mihomo_delay", status: "unavailable", reason: "delay_test_failed", results: {} };
	}
	const measured = {};
	const names = keys(result);
	for (let i = 0; i < length(names); i++) {
		const name = names[i];
		const delay = result[name];
		if (type(delay) == "int" && delay > 0) {
			measured[name] = {
				method: "mihomo_delay",
				status: "ok",
				delay_ms: delay,
				target: url,
				expected_status: expected_status
			};
		}
	}
	return {
		method: "mihomo_delay",
		status: length(keys(measured)) > 0 ? "ok" : "unavailable",
		target: url,
		expected_status: expected_status,
		results: measured
	};
};

function latest_history(group) {
	const history = group?.history;
	if (type(history) != "array" || length(history) == 0) {
		return null;
	}
	return history[length(history) - 1];
};

export function complete_from_fresh_history(round, before, after, groups, checks) {
	const latency = checks?.latency ?? {};
	const results = {};
	const existing = round?.results ?? {};
	const comparable = type(before?.proxies) == "object" && type(after?.proxies) == "object";
	const existing_names = keys(existing);
	for (let i = 0; i < length(existing_names); i++) {
		results[existing_names[i]] = existing[existing_names[i]];
	}

	for (let i = 0; i < length(groups ?? []); i++) {
		const name = groups[i];
		if (!comparable || type(name) != "string" || results[name] != null) {
			continue;
		}
		const previous = latest_history(before?.proxies?.[name]);
		const current_group = after?.proxies?.[name];
		const current = latest_history(current_group);
		if (current_group?.alive != true || type(current_group?.now) != "string" ||
			type(current_group?.all) != "array" || index(current_group.all, current_group.now) < 0 ||
			type(current?.time) != "string" || current.time == previous?.time ||
			type(current?.delay) != "int" || current.delay <= 0) {
			continue;
		}
		results[name] = {
			method: "mihomo_delay",
			status: "ok",
			delay_ms: current.delay,
			target: latency.url,
			expected_status: latency.expected_status
		};
	}

	return {
		method: "mihomo_delay",
		status: length(keys(results)) > 0 ? "ok" : "unavailable",
		target: latency.url,
		expected_status: latency.expected_status,
		results: results
	};
};
