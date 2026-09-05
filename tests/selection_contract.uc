#!/usr/bin/ucode

import { choose_automatic, provider_group_current_leaf, provider_group_leaf, provider_round_summary } from "../openwrt/files/usr/libexec/opl-netfleet/core/selector.uc";

const policy = {
	capabilities: {
		standard: { enabled: true, mode: "automatic" },
		"ai-compatible": { enabled: true, mode: "automatic", excluded_regions: ["hong_kong"] }
	},
	regions: {
		current: { mode: "automatic" },
		near: { mode: "automatic" },
		fast: { mode: "automatic" },
		hong_kong: { mode: "automatic" }
	},
	selection: { region_switch_margin_ms: 150 }
};

function candidate(id, provider, region, rtt, remaining, role, leaf_verified, capability) {
	return {
		capability: capability ?? "standard",
		candidate_id: id,
		leaf_verified: leaf_verified ?? true,
		provider_id: provider,
		region_id: region,
		role: role,
		group: `group-${region}-${provider}`,
		available: true,
		latency: { status: "ok", delay_ms: rtt },
		quota: remaining == null ? { state: "unknown" } :
			remaining == 0 ? { state: "exhausted" } : { state: "available", remaining_bytes: remaining }
	};
};

const proxy_state = {
	"control-node": { type: "Direct", alive: true },
	"alpha-korea": { alive: true, now: "shared-node", all: ["shared-node"] },
	"alpha-dead": { alive: true, now: "dead-node", all: ["dead-node"] },
	"alpha-control": { alive: true, now: "control-node", all: ["control-node"] },
	"alpha-direct-name": { alive: true, now: "DIRECT", all: ["DIRECT"] }
};
const provider_state = {
	"SOURCE-ALPHA": { proxies: [
		{ name: "shared-node", type: "Hysteria2", alive: true },
		{ name: "dead-node", type: "Vless", alive: false },
		{ name: "control-node", type: "direct", alive: true },
		{ name: "DIRECT", type: "Hysteria2", alive: true }
	] },
	"SOURCE-BETA": { proxies: [
		{ name: "shared-node", type: "Hysteria2", alive: false }
	] }
};
if (provider_group_leaf(proxy_state, provider_state, "SOURCE-ALPHA", "alpha-korea") != "shared-node" ||
	provider_group_leaf(proxy_state, provider_state, "SOURCE-BETA", "alpha-korea") != null ||
	provider_group_leaf(proxy_state, provider_state, "SOURCE-ALPHA", "alpha-dead") != null ||
	provider_group_leaf(proxy_state, provider_state, "SOURCE-ALPHA", "alpha-control") != null ||
	provider_group_leaf(proxy_state, provider_state, "SOURCE-ALPHA", "alpha-direct-name") != "DIRECT" ||
	provider_group_current_leaf(proxy_state, provider_state, "SOURCE-ALPHA", "alpha-dead") != "dead-node" ||
	provider_group_current_leaf(proxy_state, provider_state, "SOURCE-BETA", "alpha-dead") != null ||
	provider_group_current_leaf(proxy_state, provider_state, "SOURCE-ALPHA", "alpha-control") != null) {
	print("manifest_bound_provider_leaf_failed\n");
	exit(1);
}

const summary_entry = {
	providers: {
		alpha: { source_name: "SOURCE-ALPHA" },
		missing: { source_name: "SOURCE-MISSING" }
	},
	candidate_groups: [
		{ name: "alpha-korea", provider: "alpha", region: "korea" },
		{ name: "alpha-control", provider: "alpha", region: "control" },
		{ name: "alpha-direct-name", provider: "alpha", region: "named" }
	]
};
const summary_providers = {
	"SOURCE-ALPHA": { proxies: [
		{ name: "shared-node", type: "Hysteria2", alive: true, server: "203.0.113.9" },
		{ name: "dead-node", type: "Vless", alive: false, server: "203.0.113.10" },
		{ name: "control-node", type: "direct", alive: true },
		{ name: "DIRECT", type: "Hysteria2", alive: true }
	] }
};
function source_by_id(summary, provider_id) {
	const sources = summary?.sources ?? [];
	for (let i = 0; i < length(sources); i++) {
		if (sources[i]?.provider_id == provider_id) {
			return sources[i];
		}
	}
	return null;
};

const unavailable = provider_round_summary(summary_entry, proxy_state, null);
const missing_source = provider_round_summary(summary_entry, proxy_state, {});
const empty_source = provider_round_summary(summary_entry, proxy_state, { "SOURCE-ALPHA": { proxies: [] } });
const dead_source = provider_round_summary(summary_entry, proxy_state, {
	"SOURCE-ALPHA": { proxies: [{ name: "dead-node", type: "Vless", alive: false }] }
});
const mixed = provider_round_summary(summary_entry, proxy_state, summary_providers);
const encoded = sprintf("%J", mixed);
const mixed_alpha = source_by_id(mixed, "alpha");
const mixed_missing = source_by_id(mixed, "missing");
if (unavailable?.reason != "provider_state_unavailable" ||
	source_by_id(missing_source, "alpha")?.reason != "source_not_loaded" ||
	source_by_id(missing_source, "missing")?.reason != "source_not_loaded" ||
	source_by_id(empty_source, "alpha")?.reason != "zero_nodes" ||
	source_by_id(empty_source, "alpha")?.node_count != 0 ||
	source_by_id(dead_source, "alpha")?.reason != "zero_alive_nodes" ||
	source_by_id(dead_source, "alpha")?.node_count != 1 ||
	source_by_id(dead_source, "alpha")?.alive_count != 0 ||
	mixed_alpha?.reason != "ready" || mixed_alpha?.node_count != 3 ||
	mixed_alpha?.alive_count != 2 || mixed_missing?.reason != "source_not_loaded" ||
	mixed?.groups?.[0]?.reason != "ready" || mixed?.groups?.[1]?.reason != "control_fallback" ||
	mixed?.groups?.[2]?.reason != "ready" ||
	index(encoded, "shared-node") >= 0 || index(encoded, "dead-node") >= 0 ||
	index(encoded, "control-node") >= 0 || index(encoded, "203.0.113") >= 0 ||
	index(encoded, "SOURCE-ALPHA") >= 0 || index(encoded, "Bearer") >= 0) {
	print("provider_round_summary_leaked_or_miscounted\n");
	exit(1);
}

let result = choose_automatic([
	candidate("near-node", "p1", "near", 100, 10, "primary"),
	candidate("current-node", "p2", "current", 200, 10, "primary")
], policy, "standard", "current");
if (!result.ok || result.region_id != "current") {
	print("margin_hold_failed\n");
	exit(1);
}

result = choose_automatic([
	candidate("fast-node", "p1", "fast", 40, 10, "primary"),
	candidate("current-node", "p2", "current", 200, 10, "primary")
], policy, "standard", "current");
if (!result.ok || result.region_id != "fast") {
	print("margin_switch_failed\n");
	exit(1);
}

const capability_margin = json(sprintf("%J", policy));
capability_margin.capabilities.standard.region_switch_margin_ms = 200;
result = choose_automatic([
	candidate("fast-node", "p1", "fast", 40, 10, "primary"),
	candidate("current-node", "p2", "current", 200, 10, "primary")
], capability_margin, "standard", "current");
if (!result.ok || result.region_id != "current") {
	print("capability_margin_override_failed\n");
	exit(1);
}

const omitted_margin = json(sprintf("%J", policy));
omitted_margin.selection = {};
result = choose_automatic([
	candidate("fast-node", "p1", "fast", 40, 10, "primary"),
	candidate("current-node", "p2", "current", 189, 10, "primary")
], omitted_margin, "standard", "current");
if (!result.ok || result.region_id != "current") {
	print("default_margin_keep_failed\n");
	exit(1);
}
result = choose_automatic([
	candidate("fast-node", "p1", "fast", 40, 10, "primary"),
	candidate("current-node", "p2", "current", 200, 10, "primary")
], omitted_margin, "standard", "current");
if (!result.ok || result.region_id != "fast") {
	print("default_margin_switch_failed\n");
	exit(1);
}

result = choose_automatic([
	candidate("exhausted", "p1", "fast", 1, 0, "primary"),
	candidate("usable", "p2", "current", 100, 1, "primary")
], policy, "standard", "current");
if (!result.ok || result.candidate_id != "usable") {
	print("quota_filter_failed\n");
	exit(1);
}

result = choose_automatic([
	candidate("low-quota", "p1", "current", 100, 1, "primary"),
	candidate("high-quota", "p2", "current", 100, 100, "primary")
], policy, "standard", "current");
if (!result.ok || result.candidate_id != "high-quota") {
	print("quota_tie_break_failed\n");
	exit(1);
}

result = choose_automatic([
	candidate("COMPATIBLE", "p1", "fast", 1, 100, "primary", false),
	candidate("real-node", "p2", "current", 100, 1, "primary")
], policy, "standard", "current");
if (!result.ok || result.candidate_id != "real-node") {
	print("placeholder_candidate_filter_failed\n");
	exit(1);
}

result = choose_automatic([
	candidate("DIRECT", "p1", "fast", 1, 100, "primary", true),
	candidate("slower-node", "p2", "current", 200, 1, "primary")
], policy, "standard", null);
if (!result.ok || result.candidate_id != "DIRECT") {
	print("verified_leaf_name_was_treated_as_identity\n");
	exit(1);
}

result = choose_automatic([
	candidate("dead-primary", "p1", "fast", 1, 0, "primary"),
	candidate("reserve-node", "p2", "current", 120, null, "reserve")
], policy, "standard", "current");
if (!result.ok || result.candidate_id != "reserve-node" || result.layer != "reserve") {
	print("reserve_fallback_failed\n");
	exit(1);
}

result = choose_automatic([
	candidate("ai-hk", "p1", "hong_kong", 20, 10, "primary", true, "ai-compatible"),
	candidate("ai-near", "p2", "near", 80, 10, "primary", true, "ai-compatible")
], policy, "ai-compatible", null, "hong_kong");
if (!result.ok || result.region_id != "near" || result.reason != "fastest_eligible") {
	print("ai_excluded_preferred_region_failed\n");
	exit(1);
}

result = choose_automatic([
	candidate("ai-near", "p1", "near", 100, 10, "primary", true, "ai-compatible"),
	candidate("ai-fast", "p2", "fast", 20, 10, "primary", true, "ai-compatible")
], policy, "ai-compatible", null, "near");
if (!result.ok || result.region_id != "near" || result.reason != "followed_capability_region") {
	print("ai_followed_standard_region_failed\n");
	exit(1);
}

print("selection_contract_ok\n");
