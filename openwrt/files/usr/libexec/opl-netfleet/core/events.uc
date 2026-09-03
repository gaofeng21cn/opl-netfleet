export const EVENT_LIMIT = 128;

function clone(value) {
	return json(sprintf("%J", value));
};

function valid_event(event) {
	return type(event) == "object" && type(event.at) == "int" &&
		index(["enable", "select", "disable", "refresh"], event.action) >= 0 &&
		type(event.reason) == "string" &&
		(event.initiator == null || index(["luci", "cli", "deployer", "supervisor", "unknown"], event.initiator) >= 0);
};

export function validate(store) {
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

export function append(store, additions) {
	const previous = store != null && validate(store).ok ? store.events : [];
	const events = [];
	for (let i = 0; i < length(previous); i++) push(events, clone(previous[i]));
	for (let i = 0; i < length(additions ?? []); i++) {
		if (valid_event(additions[i])) push(events, clone(additions[i]));
	}
	const start = length(events) > EVENT_LIMIT ? length(events) - EVENT_LIMIT : 0;
	return { schema_version: 1, events: slice(events, start) };
};
