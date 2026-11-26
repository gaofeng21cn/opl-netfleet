

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let record_events, event_initiator, decision_event, refresh_event;

const validate_events = context.use("events.model").validate;
const append_events = context.use("events.model").append;
const read_events = context.use("events.store").read_events;
const write_events = context.use("events.store").write_events;

record_events = function(additions) {
	const existing = read_events();
	const current = validate_events(existing).ok ? existing : null;
	return write_events(append_events(current, additions));
};

event_initiator = function(requested, trigger) {
	if (trigger == "scheduled") return "supervisor";
	return index(["luci", "cli", "deployer", "supervisor"], requested) >= 0 ? requested : "cli";
};

decision_event = function(action, capability, before_group, selection, result, initiator) {
	const decision = result?.decision;
	return {
		at: int(time()),
		action: action,
		capability: capability ?? null,
		from_group: before_group ?? null,
		to_group: selection?.selected_group ?? decision?.group ?? null,
		region_id: decision?.region_id ?? null,
		provider_id: decision?.provider_id ?? null,
		leaf: selection?.selected_leaf ?? null,
		delay_ms: decision?.delay_ms ?? null,
		reason: decision?.reason ?? (action == "disable" ? "native_restored" : "manual_or_initial"),
		trigger: selection?.trigger ?? null,
		initiator: event_initiator(initiator, selection?.trigger)
	};
};

refresh_event = function(result, requested) {
	return {
		at: int(time()),
		action: "refresh",
		reason: result.reason,
		initiator: event_initiator(requested, requested == "scheduled" ? "scheduled" : null),
		provider_count: result.provider_count ?? 0,
		changed_count: result.changed_count ?? 0,
		failed_count: result.failed_count ?? 0,
		reloaded: result.reloaded == true,
		ok: result.ok == true,
		subscriptions: result.subscriptions ?? []
	};
};

function bounded_string(value) {
	if (type(value) != "string" || length(value) == 0 ||
		match(value, /:\/\/|[?&](token|key|password|secret)=|[[:cntrl:]]/i)) return null;
	if (length(value) <= 160) return value;
	// UCode offsets count bytes. Back up to a character boundary before serializing.
	let end = 160;
	while ((ord(value, end) & 0xc0) == 0x80) end--;
	return substr(value, 0, end);
}

function bounded_path(value) {
	if (type(value) != "array") return null;
	const path = [];
	for (let i = 0; i < length(value) && i < 8; i++) {
		const name = bounded_string(value[i]);
		if (name == null) return null;
		push(path, name);
	}
	return path;
}

function runtime_summary(value) {
	if (type(value) != "object") return null;
	return {
		user_mode: bounded_string(value.user_mode),
		data_path: bounded_string(value.data_path),
		selected_group: bounded_string(value.selected_group),
		leaf: bounded_string(value.leaf),
		alive: type(value.alive) == "bool" ? value.alive : null,
		preferred_group: bounded_string(value.preferred_group),
		preferred_leaf: bounded_string(value.preferred_leaf),
		path: bounded_path(value.path)
	};
}

function error_code(value) {
	return type(value) == "string" && length(value) <= 160 && match(value, /^[a-z][a-z0-9_]*$/) ? value : null;
}

function http_status(value) {
	if (type(value) == "string" && match(value, /^[1-5][0-9][0-9]$/)) return int(value);
	return type(value) == "int" && value >= 100 && value <= 599 ? value : null;
}

function failure_summary(detail, recovery) {
	const activation = detail?.activation ?? detail;
	const probe = detail?.protected_probes ?? activation?.probes ?? activation;
	const runtime = runtime_summary(activation?.runtime);
	return {
		stage: error_code(activation?.error ?? detail?.automatic?.error ?? detail?.reason),
		selected_group: bounded_string(detail?.selected_group ?? activation?.choice),
		leaf: bounded_string(activation?.leaf),
		data_path: bounded_string(activation?.data_path),
		probe: type(probe?.probe) == "int" ? `${probe.probe}` : bounded_string(probe?.probe),
		probe_group: bounded_string(activation?.group),
		method: bounded_string(activation?.method),
		expected_status: http_status(probe?.expected_status),
		actual_status: probe?.actual_status == "000" ? 0 : http_status(probe?.actual_status),
		runtime: runtime,
		recovery: type(recovery) == "object" ? {
			ok: recovery.ok == true,
			mode: error_code(recovery.mode),
			reason: error_code(recovery.reason)
		} : null
	};
}

function record_enable_failure(error, detail, requested, final_recovery) {
	const failure = detail?.details ?? detail;
	const code = error_code(error) ?? "operation_failed";
	const summary = failure_summary(failure, final_recovery ?? detail?.recovery);
	const event = {
		at: int(time()),
		action: "enable",
		capability: bounded_string(failure?.capability),
		reason: code,
		initiator: index(["luci", "cli", "deployer", "supervisor"], requested) >= 0 ? requested : "unknown",
		ok: false,
		error: code,
		failure_detail: summary
	};
	try { return record_events([event]); }
	catch (error) { return false; }
}

return { record_events, event_initiator, decision_event, refresh_event, record_enable_failure };
};
