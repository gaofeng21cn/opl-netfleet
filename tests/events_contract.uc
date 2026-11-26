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
		validate({ schema_version: 1, events: [{ at: 1, action: "disable", reason: "x", initiator: "guess" }] }).ok ||
		!validate({ schema_version: 1, events: [{ at: 1, action: "enable", reason: "preferred_path_unavailable", ok: false,
			error: "preferred_path_unavailable", failure_detail: { stage: "preferred_path_unavailable", runtime: { path: ["OUTBOUND", "DIRECT"] } } }] }).ok ||
		validate({ schema_version: 1, events: [{ at: 1, action: "enable", reason: "preferred_path_unavailable", ok: false,
			error: "preferred_path_unavailable", failure_detail: { runtime: { path: ["https://private.invalid/?token=secret"] } } }] }).ok ||
		!validate({ schema_version: 1, events: [{ at: 1, action: "enable", reason: "legacy_event" }] }).ok) {
		print("events_contract_failed\n");
		exit(1);
	}
}

function test_failure_event_recording() {
	const plugins_root = replace(sourcepath(), /[^/]+$/, "../plugins");
	const model = loadfile(`${plugins_root}/events/lib/model.uc`)()({});
	const factory = loadfile(`${plugins_root}/events/lib/record.uc`)();
	let store = { schema_version: 1, events: [] };
	const record = factory({ use: name => name == "events.model" ? model : {
		read_events: () => store,
		write_events: value => { store = value; return true; }
	} });
	const written = record.record_enable_failure("preferred_path_unavailable", {
		capability: "standard",
		selected_group: "candidate-jp",
		activation: {
			error: "preferred_path_unavailable",
			probe: "path",
			group: "AUTO-PREFERRED",
			method: "HEAD",
			expected_status: 204,
			choice: "candidate-jp",
			leaf: "JP-Tokyo-02",
			data_path: "unknown",
			probe_url: "https://probe.invalid/?token=private",
			runtime: {
				user_mode: "automatic",
				data_path: "unknown",
				selected_group: "DIRECT",
				leaf: "DIRECT",
				alive: true,
				preferred_group: "candidate-jp",
				preferred_leaf: "JP-Tokyo-02",
				path: ["OUTBOUND", "AUTO-PREFERRED", "DIRECT"],
				private_config: "do not persist"
			}
		},
		recovery: { ok: true, mode: "native_profile", reason: "preferred_path_unavailable", profile: "/private/profile.json" }
	}, "luci");
	const event = store.events[0];
	const serialized = sprintf("%J", event);
	if (!written || event == null || event.ok != false || event.error != "preferred_path_unavailable" ||
		event.initiator != "luci" || event.failure_detail?.probe != "path" ||
		event.failure_detail?.runtime?.path[1] != "AUTO-PREFERRED" ||
		event.failure_detail?.recovery?.ok != true ||
		index(serialized, "https://") >= 0 || index(serialized, "token=private") >= 0 ||
		index(serialized, "do not persist") >= 0 || index(serialized, "/private/profile.json") >= 0) {
		print("failure_event_recording_failed\n");
		exit(1);
	}
	assert(record.record_enable_failure("rollback_failed", {
		details: { activation: { error: "protected_probe_failed", probes: {
			probe: "guard", expected_status: "204", actual_status: "503"
		} } },
		recovery: { ok: false, reason: "cleanup_failed" }
	}, "supervisor"));
	const rollback = store.events[1];
	assert(rollback.initiator == "supervisor" && rollback.failure_detail.stage == "protected_probe_failed" &&
		rollback.failure_detail.expected_status == 204 && rollback.failure_detail.actual_status == 503 &&
		rollback.failure_detail.recovery.ok == false, "retain the nested failure and rollback outcome");
	const long_name = join("", map([0,1,2,3,4,5,6,7,8], _ => "东京首尔新加坡"));
	assert(record.record_enable_failure("protected_probe_failed", {
		activation: { choice: long_name, leaf: "?token=private", probes: { probe: "guard", actual_status: "000" } }
	}, null));
	const no_response = store.events[2];
	assert(no_response.initiator == "unknown" && no_response.failure_detail.actual_status == 0 &&
		no_response.failure_detail.selected_group == substr(long_name, 0, 159) && no_response.failure_detail.leaf == null,
		"preserve UTF-8 and a missing HTTP response without retaining credentials");
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
	test_failure_event_recording();
	test_events_read();
} catch (error) {
	release_services();
	die(error.message);
}
release_services();
print("events_contract_ok\n");
