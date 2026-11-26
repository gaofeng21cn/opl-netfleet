

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let clone, valid_event, validate, append;



const EVENT_LIMIT = 1024;

function valid_summary_string(value) {
	return value == null || (type(value) == "string" && length(value) <= 160 &&
		index(value, "://") < 0 && !match(value, /[?&](token|key|password|secret)=|[[:cntrl:]]/i));
}

function valid_summary_path(value) {
	if (value == null) return true;
	if (type(value) != "array" || length(value) > 8) return false;
	for (let i = 0; i < length(value); i++) {
		if (!valid_summary_string(value[i]) || value[i] == null) return false;
	}
	return true;
}

function valid_runtime_summary(value) {
	if (value == null) return true;
	return type(value) == "object" &&
		valid_summary_string(value.user_mode) && valid_summary_string(value.data_path) &&
		valid_summary_string(value.selected_group) && valid_summary_string(value.leaf) &&
		(value.alive == null || type(value.alive) == "bool") &&
		valid_summary_string(value.preferred_group) && valid_summary_string(value.preferred_leaf) &&
		valid_summary_path(value.path);
}

function valid_failure_summary(value) {
	if (value == null) return true;
	if (type(value) != "object" || !valid_summary_string(value.stage) ||
		!valid_summary_string(value.selected_group) || !valid_summary_string(value.leaf) ||
		!valid_summary_string(value.data_path) || !valid_summary_string(value.probe) ||
		!valid_summary_string(value.probe_group) || !valid_summary_string(value.method) ||
		(value.expected_status != null && type(value.expected_status) != "int") ||
		(value.actual_status != null && type(value.actual_status) != "int") ||
		!valid_runtime_summary(value.runtime)) return false;
	const recovery = value.recovery;
	return recovery == null || (type(recovery) == "object" &&
		(recovery.ok == null || type(recovery.ok) == "bool") &&
		valid_summary_string(recovery.mode) && valid_summary_string(recovery.reason));
}

clone = function(value) {
	const kind = type(value);
	if (kind == "array") return map(value, clone);
	if (kind == "object") {
		const copy = {};
		for (let key, item in value) copy[key] = clone(item);
		return copy;
	}
	return value;
};

valid_event = function(event) {
	return type(event) == "object" && type(event.at) == "int" &&
		index(["enable", "select", "disable", "refresh"], event.action) >= 0 &&
		type(event.reason) == "string" &&
		(!("ok" in event) || type(event.ok) == "bool") &&
		(!("error" in event) || (type(event.error) == "string" && match(event.error, /^[a-z][a-z0-9_]*$/))) &&
		(!("failure_detail" in event) || valid_failure_summary(event.failure_detail)) &&
		(event.initiator == null || index(["luci", "cli", "deployer", "supervisor", "unknown"], event.initiator) >= 0);
};

validate = function(store) {
	if (store == null) return { ok: true, count: 0 };
	if (type(store) != "object" || store.schema_version != 1 || type(store.events) != "array" ||
		length(store.events) > EVENT_LIMIT) {
		return { ok: false, error: "invalid_event_store" };
	}
	for (let i = 0; i < length(store.events); i++) {
		if (!valid_event(store.events[i])) return { ok: false, error: "invalid_event" };
	}
	return { ok: true, count: length(store.events) };
};

append = function(store, additions) {
	const previous = store != null && validate(store).ok ? store.events : [];
	const events = [];
	for (let i = 0; i < length(previous); i++) push(events, clone(previous[i]));
	for (let i = 0; i < length(additions ?? []); i++) {
		if (valid_event(additions[i])) push(events, clone(additions[i]));
	}
	const start = length(events) > EVENT_LIMIT ? length(events) - EVENT_LIMIT : 0;
	return { schema_version: 1, events: slice(events, start) };
};

return { EVENT_LIMIT, validate, append };
};
