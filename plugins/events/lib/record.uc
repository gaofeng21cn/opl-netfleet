

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

return { record_events, event_initiator, decision_event, refresh_event };
};
