import { request as http_request, request_all as http_request_all } from "./http.uc";

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let controller_timeout_seconds, measure_providers, measure, latest_history, complete_from_fresh_history;

const url_path_segment = context.use("mihomo.controller").url_path_segment;
const API = context.use("platform.runtime").API;

controller_timeout_seconds = function(timeout_ms) {
	let seconds = int((timeout_ms + 999) / 1000) + 3;
	if (seconds < 4) {
		seconds = 4;
	} else if (seconds > 30) {
		seconds = 30;
	}
	return seconds;
};

measure_providers = function(secret, sources, checks) {
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
	const specs = [];
	const timeout_ms = max_time * 1000;
	for (let i = 0; i < length(sources); i++) {
		const source = sources[i];
		if (type(source) != "string" || length(source) == 0) {
			return false;
		}
		push(specs, {
			target: API,
			method: "GET",
			path: `/providers/proxies/${url_path_segment(source)}/healthcheck`,
			headers: { Authorization: `Bearer ${secret}` },
			connect_timeout_ms: 2000,
			timeout_ms,
			discard_body: true
		});
	}
	// Trigger providers concurrently, but retain their real completion status.
	// A failed provider does not cancel the other measurements.
	const responses = http_request_all(specs, timeout_ms);
	for (let i = 0; i < length(responses); i++) {
		const response = responses[i];
		if (!response?.ok || response.status < 200 || response.status >= 300) return false;
	}
	return true;
};

measure = function(secret, group, checks) {
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
	const path = `/group/${url_path_segment(group)}/delay?url=${url_path_segment(url)}` +
		`&timeout=${timeout_ms}&expected=${expected_status}`;
	const response = http_request(API, {
		method: "GET",
		path,
		headers: { Authorization: `Bearer ${secret}` },
		connect_timeout_ms: 2000,
		timeout_ms: max_time * 1000
	});
	let result = null;
	if (response?.ok && response.status >= 200 && response.status < 300 && type(response.body) == "string") {
		try {
			result = json(response.body);
		} catch (error) {
			result = null;
		}
	}
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

latest_history = function(group) {
	const history = group?.history;
	if (type(history) != "array" || length(history) == 0) {
		return null;
	}
	return history[length(history) - 1];
};

complete_from_fresh_history = function(round, before, after, groups, checks) {
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
		if (!comparable || type(name) != "string") {
			delete results[name];
			continue;
		}
		const previous = latest_history(before?.proxies?.[name]?.extra?.[latency.url]);
		const current_group = after?.proxies?.[name];
		const health = current_group?.extra?.[latency.url];
		const current = latest_history(health);
		if (health?.alive != true || type(current_group?.now) != "string" ||
			type(current_group?.all) != "array" || index(current_group.all, current_group.now) < 0 ||
			type(current?.time) != "string" || current.time == previous?.time ||
			type(current?.delay) != "int" || current.delay <= 0) {
			delete results[name];
			continue;
		}
		if (results[name] != null) continue;
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

return { controller_timeout_seconds, measure_providers, measure, complete_from_fresh_history };
};
