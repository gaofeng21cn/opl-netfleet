#!/usr/bin/ucode

import { append, validate, EVENT_LIMIT } from "../openwrt/files/usr/libexec/opl-netfleet/core/events.uc";

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

print("events_contract_ok\n");
