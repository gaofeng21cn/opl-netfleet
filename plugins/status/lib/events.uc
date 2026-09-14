

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let event_display_names, events_action, command_events;

const validate_events = context.use("events.model").validate;
const ok = context.use("events.output").ok;
const read_events = context.use("events.store").read_events;
const core_netfleet_lines = context.use("events.store").core_netfleet_lines;
const MANIFEST_PATH = context.use("mihomo.backend").MANIFEST_PATH;
const expected_runtime_groups = context.use("models.activation").expected_runtime_groups;
const load_policy = context.use("platform.documents").load_policy;
const read_json = context.use("platform.storage").read_json;
const provider_display_names = context.use("subscriptions.facts").provider_display_names;

event_display_names = function(policy) {
	const capabilities = {};
	const capability_names = keys(policy?.capabilities ?? {});
	for (let i = 0; i < length(capability_names); i++) {
		const name = capability_names[i];
		const display = policy.capabilities[name]?.display_name;
		if (type(display) == "string" && length(display) > 0) {
			capabilities[name] = display;
		}
	}
	const regions = {};
	const region_names = keys(policy?.regions ?? {});
	for (let i = 0; i < length(region_names); i++) {
		const name = region_names[i];
		const region = policy.regions[name] ?? {};
		const display = region.display_name;
		if (type(display) == "string" && length(display) > 0) {
			regions[name] = region.flag == null ? display : `${region.flag} ${display}`;
		}
	}
	return {
		capabilities: capabilities,
		providers: provider_display_names(policy ?? {}),
		regions: regions
	};
};

events_action = function() {
	const store = read_events();
	const validation = validate_events(store);
	const manifest = read_json(MANIFEST_PATH);
	const policy = load_policy();
	ok("events", {
		events: validation.ok ? store?.events ?? [] : [],
		store_valid: validation.ok,
		store_error: validation.ok ? null : validation.error,
		display_names: event_display_names(policy),
		core_lines: core_netfleet_lines(expected_runtime_groups(manifest)),
		core_lines_persistent: false
	});
};

command_events = function(argv) {
	events_action();
};

return { event_display_names, events_action, command_events };
};
