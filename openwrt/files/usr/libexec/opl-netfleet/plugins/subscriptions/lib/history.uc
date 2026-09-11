import * as fs from "fs";

export function create_history(context) {
	const path = context.use("platform.paths").SUBSCRIPTION_HISTORY_PATH;
	const read_json = context.use("platform.storage").read_json;
	const atomic_json = context.use("platform.files").atomic_json;
	const read_events = context.use("events.store").read_events;
	const validate_events = context.use("events.model").validate;
	const update = context.use("models.subscription").history_update;
	function read() {
		if (fs.lstat(path) != null) {
			const state = read_json(path);
			if (state?.schema_version != 1 || type(state.subscriptions) != "object")
				die("subscription_history_unreadable");
			return state;
		}
		let state = null;
		const legacy = read_events();
		if (validate_events(legacy).ok)
			for (let event in legacy?.events ?? []) state = update(state, event, false);
		return state;
	};
	function record(event, full) {
		return atomic_json(path, update(read(), event, full));
	};
	return { read, record };
};
