#!/usr/bin/ucode

import {
	enabled_sections, quota_config, cache_accepted, evaluate_entry, summarize,
	public_results, unavailable_results, project
} from "../openwrt/files/usr/libexec/opl-netfleet/core/subscription.uc";

const policy = {
	providers: {
		zeta: { section: "zeta", enabled: false, quota: { available_field: "available" } },
		beta: { section: "beta", enabled: true, quota: { available_field: "available" } },
		alpha: { section: "alpha", enabled: true, quota: { used_field: "used" } },
		alpha_alias: { section: "alpha", enabled: true }
	}
};

if (join(",", enabled_sections(policy)) != "alpha,beta" ||
	quota_config(policy, "alpha")?.used_field != "used" ||
	quota_config(policy, "beta")?.available_field != "available" ||
	quota_config(policy, "zeta") != null) {
	print("enabled_sections_failed\n");
	exit(1);
}

if (cache_accepted({ proxies: [{ name: "node-a" }] }) != true ||
	cache_accepted({ proxies: [] }) != false ||
	cache_accepted({}) != false ||
	cache_accepted(null) != false ||
	cache_accepted("") != false ||
	cache_accepted([]) != false) {
	print("cache_accepted_failed\n");
	exit(1);
}

const previous = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const next = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const valid = { proxies: [{ name: "node-a" }] };
const success = evaluate_entry({
	section: "alpha",
	updated: true,
	previous_digest: previous,
	digest: next,
	parsed: valid
});
const unchanged = evaluate_entry({
	section: "alpha",
	updated: true,
	previous_digest: previous,
	digest: previous,
	parsed: valid
});
const download_failed = evaluate_entry({
	section: "beta",
	updated: false,
	previous_digest: previous,
	digest: previous,
	parsed: valid
});
const malformed = evaluate_entry({
	section: "beta",
	updated: true,
	previous_digest: previous,
	digest: next,
	parsed: null
});
const empty = evaluate_entry({
	section: "beta",
	updated: true,
	previous_digest: previous,
	digest: next,
	parsed: { proxies: [] }
});

if (success.result != "updated" || success.restore != false || success.changed != true ||
	unchanged.result != "unchanged" || unchanged.restore != false || unchanged.changed != false ||
	download_failed.result != "failed" || download_failed.restore != true ||
	download_failed.digest != previous ||
	malformed.result != "failed" || malformed.restore != true || malformed.digest != previous ||
	empty.result != "failed" || empty.restore != true || empty.digest != previous) {
	print("evaluate_entry_failed\n");
	exit(1);
}

const mixed = summarize([success, download_failed]);
const all_unchanged = summarize([unchanged]);
const all_failed = summarize([malformed, empty]);
if (mixed.changed_count != 1 || mixed.failed_count != 1 || mixed.ok != false ||
	mixed.cache_reason != "partially_updated" || mixed.active_reason != "partially_updated" ||
	all_unchanged.cache_reason != "unchanged" || all_unchanged.ok != true ||
	all_failed.changed_count != 0 || all_failed.failed_count != 2 ||
	all_failed.cache_reason != "update_failed") {
	print("summarize_failed\n");
	exit(1);
}

const retained = public_results([success, download_failed]);
if (length(retained) != 2 || retained[0].section != "alpha" || retained[0].result != "updated" ||
	retained[0].digest != next || retained[1].section != "beta" || retained[1].result != "failed" ||
	retained[1].digest != previous || retained[0].parsed != null || retained[0].url != null) {
	print("public_results_failed\n");
	exit(1);
}

const facts = [
	{
		section: "alpha",
		ref: "subscription:alpha",
		display_name: "Alpha",
		present: true,
		digest: previous,
		valid: true,
		quota: { state: "available", remaining_bytes: 1024, expires_at: "2026-12-31" },
		url: "https://secret.invalid/token",
		token: "secret-token",
		parsed: valid
	},
	{
		section: "beta",
		ref: "subscription:beta",
		display_name: "Beta",
		present: true,
		digest: previous,
		valid: true,
		quota: { state: "unknown" }
	}
];
const projected = project({
	subscription_refresh_enabled: true,
	subscription_refresh_interval_seconds: 43200
}, facts, [{
	at: 1700000000,
	action: "refresh",
	reason: "partially_updated",
	ok: false,
	changed_count: 1,
	failed_count: 1,
	reloaded: false,
	initiator: "luci",
	subscriptions: [
		{ section: "alpha", result: "updated", digest: next },
		{ section: "beta", result: "failed", digest: previous }
	]
}]);
const encoded = sprintf("%J", projected);
if (projected.provider_count != 2 || projected.last_result != "partially_updated" ||
	projected.subscriptions[0].section != "alpha" ||
	projected.subscriptions[0].ref != "subscription:alpha" ||
	projected.subscriptions[0].display_name != "Alpha" ||
	projected.subscriptions[0].cache.present != true ||
	projected.subscriptions[0].cache.digest != previous ||
	projected.subscriptions[0].cache.valid != true ||
	projected.subscriptions[0].quota.remaining_bytes != 1024 ||
	projected.subscriptions[0].quota.expires_at != "2026-12-31" ||
	projected.subscriptions[0].last_refresh.result != "updated" ||
	projected.subscriptions[0].last_refresh.ok != true ||
	projected.subscriptions[1].last_refresh.result != "failed" ||
	projected.subscriptions[1].last_refresh.ok != false ||
	projected.subscriptions[0].url != null || projected.subscriptions[0].token != null ||
	projected.subscriptions[0].parsed != null ||
	index(encoded, "secret.invalid") >= 0 || index(encoded, "secret-token") >= 0 ||
	index(encoded, "node-a") >= 0) {
	print("metadata_projection_failed\n");
	exit(1);
}

const unavailable = project({
	subscription_refresh_enabled: true,
	subscription_refresh_interval_seconds: 43200
}, facts, [{
	at: 1700000100,
	action: "refresh",
	reason: "upstream_unavailable",
	ok: false,
	changed_count: 0,
	failed_count: 2,
	reloaded: false,
	initiator: "supervisor",
	subscriptions: unavailable_results(["alpha", "beta"])
}]);
if (unavailable.last_result != "upstream_unavailable" ||
	unavailable.subscriptions[0].last_refresh.result != "failed" ||
	unavailable.subscriptions[1].cache.present != true) {
	print("unavailable_projection_failed\n");
	exit(1);
}

print("subscription_contract_ok\n");
