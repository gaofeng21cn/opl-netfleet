#!/usr/bin/ucode
import { use, release as release_services } from "./services.uc";

function test_events_model() {
	const append = use("events.model").append;
	const validate = use("events.model").validate;
	const EVENT_LIMIT = use("events.model").EVENT_LIMIT;

	const additions = [];
	for (let i = 0; i < EVENT_LIMIT + 10; i++) {
		push(additions, {
			at: i,
			action: "select",
			capability: "standard",
			from_group: "old",
			to_group: "new",
			region_id: "region",
			provider_id: "provider",
			leaf: "leaf",
			delay_ms: 10,
			reason: "fastest_eligible",
			initiator: "supervisor"
		});
	}
	const store = append(null, additions);
	const refreshed = append(store, [{
		at: EVENT_LIMIT + 10,
		action: "refresh",
		reason: "unchanged",
		initiator: "supervisor",
		provider_count: 2,
		changed_count: 0,
		failed_count: 0,
		reloaded: false,
		ok: true
	}]);
	if (!validate(store).ok || length(store.events) != EVENT_LIMIT || store.events[0].at != 10 ||
		!validate(refreshed).ok || refreshed.events[length(refreshed.events) - 1].action != "refresh" ||
		validate({ schema_version: 1, events: [{ at: 1, action: "unknown", reason: "x" }] }).ok ||
		validate({ schema_version: 1, events: [{ at: 1, action: "disable", reason: "x", initiator: "guess" }] }).ok) {
		print("events_contract_failed\n");
		exit(1);
	}
}

function test_events_read() {
	const factory = loadfile(replace(sourcepath(), /[^/]+$/, "../plugins/status/lib/events.uc"))();
	let logs = 0, manifests = 0, output;
	const services = {
		"events.model": { validate: () => ({ ok: true }) },
		"events.output": { ok: (name, result) => { output = result; } },
		"events.store": { read_events: () => ({ events: [{ action: "select" }] }), core_netfleet_lines: () => { logs++; return ["temporary log"]; } },
		"mihomo.backend": { MANIFEST_PATH: "manifest" },
		"models.activation": { expected_runtime_groups: () => [] },
		"platform.documents": { load_policy: () => ({}) },
		"platform.storage": { read_json: () => { manifests++; return {}; } },
		"subscriptions.facts": { provider_display_names: () => ({}) }
	};
	const api = factory({ use: name => services[name] });
	api.command_events(["events"]);
	assert(logs == 0 && manifests == 0 && length(output.core_lines) == 0 && length(output.events) == 1, "normal event read must not inspect logs or runtime manifest");
	api.command_events(["events", "logs"]);
	assert(logs == 1 && manifests == 1 && output.core_lines[0] == "temporary log" && output.core_lines_persistent == false, "explicit diagnostic read retains temporary core logs");
}

try {
	test_events_model();
	test_events_read();
} catch (error) {
	release_services();
	die(error.message);
}
release_services();
print("events_contract_ok\n");
