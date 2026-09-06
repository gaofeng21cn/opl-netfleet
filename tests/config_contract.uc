#!/usr/bin/ucode

import { project, validate_request, apply, changes } from "../openwrt/files/usr/libexec/opl-netfleet/core/config.uc";

const policy = {
	schema_version: 2,
	main: { target: "fixture", enabled: true },
	policy_source: { kind: "bundle", ref: "bundle:base-v1" },
	recovery_profile: { ref: "subscription:alpha" },
	bindings: { OUTBOUND: { capability: "standard", kind: "entry" } },
	providers: {
		alpha: { section: "alpha", enabled: true, role: "primary", billing: "subscription", quota: { available_field: "available" } },
		beta: { section: "beta", enabled: true, role: "reserve", billing: "buyout" }
	},
	regions: {
		japan: { flag: "🇯🇵", display_name: "日本", mode: "automatic", display_order: 20 },
		hong_kong: { flag: "🇭🇰", display_name: "香港", mode: "automatic", display_order: 10 }
	},
	provider_regions: {
		alpha: [{ region: "hong_kong", filter: "Hong Kong" }, { region: "japan", filter: "Japan" }],
		beta: [{ region: "hong_kong", filter: "Hong Kong" }, { region: "japan", filter: "Japan" }]
	},
	capabilities: {
		standard: { display_name: "常规出口", enabled: true, mode: "automatic", allowed_regions: ["hong_kong"] }
	},
	selection: { region_switch_margin_ms: 150, leaf_switch_margin_ms: 150 },
	automation: {
		enabled: true,
		selection_interval_seconds: 1800,
		subscription_refresh_enabled: true,
		subscription_refresh_interval_seconds: 43200,
		poll_interval_seconds: 15,
		startup_grace_seconds: 120,
		runtime_grace_seconds: 45
	},
	checks: {
		provider_healthcheck_timeout_ms: 20000,
		latency: { method: "mihomo_delay", url: "https://latency.example.invalid", timeout_ms: 2000, expected_status: 204 },
		quota: { source: "nikki_subscription_metadata", zero_is_exhausted: true }
	},
	evidence: { path: "/etc/opl-netfleet/evidence.json" },
	fail_open: {
		healthcheck: {
			path_probe_id: "path", guard_probe_id: "guard", timeout_ms: 5000,
			interval_seconds: 300, max_failed_times: 2
		},
		probes: [
			{ id: "path", url: "https://path.example.invalid", expected_status: 204 },
			{ id: "guard", url: "https://guard.example.invalid", expected_status: 204 }
		]
	}
};

const resources = {
	provider_names: { alpha: "Alpha 机场", beta: "Beta 机场" },
	policy_source_options: [
		{ kind: "bundle", ref: "bundle:base-v1", display_name: "NetFleet 内置基础策略" },
		{ kind: "profile", ref: "subscription:alpha", display_name: "Alpha 机场" }
	],
	recovery_profile_options: [
		{ ref: "subscription:alpha", display_name: "Alpha 机场" },
		{ ref: "subscription:beta", display_name: "Beta 机场" },
		{ ref: "subscription:gamma", display_name: "Gamma 机场" }
	],
	provider_options: [
		{ id: "alpha", section: "alpha", display_name: "Alpha 机场", region_ids: ["hong_kong", "japan"] },
		{ id: "beta", section: "beta", display_name: "Beta 机场", region_ids: ["hong_kong", "japan"] },
		{ id: "gamma", section: "gamma", display_name: "Gamma 机场", region_ids: ["singapore"] }
	],
	region_options: [
		{ id: "hong_kong", code: "HK", display_name: "香港", display_order: 10, filter: "Hong Kong" },
		{ id: "japan", code: "JP", display_name: "日本", display_order: 20, filter: "Japan" },
		{ id: "singapore", code: "SG", display_name: "新加坡", display_order: 30, filter: "Singapore" }
	],
	policy_source_groups: {
		"bundle|bundle:base-v1": ["OUTBOUND", "Media"],
		"profile|subscription:alpha": ["OUTBOUND", "AI", "Media"]
	}
};

const projection = project(policy, resources);
const native_resources = { ...resources, backend: { id: "native-mihomo", display_name: "NetFleet + Mihomo" } };
if (project(policy, native_resources).backend.id != "native-mihomo") {
	print("native_backend_projection_failed\n");
	exit(1);
}
if (projection.backend.id != "nikki-mihomo" || projection.providers?.[0]?.display_name != "Alpha 机场" ||
	projection.policy_source.display_name != "NetFleet 内置基础策略" ||
	projection.recovery_profile.display_name != "Alpha 机场" ||
	projection.capabilities?.[0]?.region_ids?.[0] != "hong_kong" ||
	projection.safety.path_probe_url != "https://path.example.invalid" ||
	projection.safety.guard_probe_url != "https://guard.example.invalid") {
	print("config_projection_failed\n");
	exit(1);
}

const request = {
	revision: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	policy_source: { kind: "profile", ref: "subscription:alpha" },
	recovery_profile_ref: "subscription:beta",
	providers: {
		alpha: { section: "alpha", enabled: true, role: "primary", billing: "buyout", region_ids: ["hong_kong", "japan"] },
		gamma: { section: "gamma", enabled: true, role: "reserve", billing: "subscription", region_ids: ["singapore"] }
	},
	regions: {
		hong_kong: { display_name: "香港", mode: "manual_only" },
		japan: { display_name: "日本", mode: "automatic" },
		singapore: { display_name: "新加坡", mode: "automatic" }
	},
	capabilities: {
		standard: { display_name: "常规出口", enabled: true, mode: "automatic", region_ids: ["japan"], prefer_region_from: null, entry_group: "OUTBOUND", policy_groups: ["Media"] },
		ai: { display_name: "AI 出口", enabled: true, mode: "automatic", region_ids: ["singapore"], prefer_region_from: "standard", entry_group: "AI", policy_groups: [] }
	},
	routing_rules: [{ kind: "domain_suffix", value: "example.com", capability: "ai" }],
	automation: {
		enabled: true,
		selection_interval_seconds: 3600,
		subscription_refresh_enabled: false,
		subscription_refresh_interval_seconds: 86400
	},
	safety: {
		region_switch_margin_ms: 200,
		leaf_switch_margin_ms: 100,
		runtime_grace_seconds: 60,
		latency_url: "https://new-latency.example.invalid",
		path_probe_url: "https://new-path.example.invalid",
		guard_probe_url: "https://new-guard.example.invalid"
	}
};

const merged = apply(policy, request, resources);
if (!merged.ok || merged.policy.policy_source.kind != "profile" ||
	merged.policy.recovery_profile.ref != "subscription:beta" ||
	merged.policy.providers.alpha.section != "alpha" ||
	merged.policy.providers.alpha.billing != "buyout" ||
	merged.policy.providers.alpha.role != "primary" ||
		merged.policy.providers.alpha.quota?.available_field != "available" ||
		merged.policy.provider_regions.alpha?.[0]?.filter != "Hong Kong" ||
		merged.policy.bindings.OUTBOUND?.capability != "standard" ||
		merged.policy.bindings.AI?.capability != "ai" ||
		merged.policy.providers.beta != null || merged.policy.providers.gamma?.section != "gamma" ||
		merged.policy.regions.hong_kong.flag != "🇭🇰" ||
		merged.policy.regions.singapore.flag != "SG" ||
		merged.policy.capabilities.standard.allowed_regions != null ||
		index(merged.policy.capabilities.standard.excluded_regions, "hong_kong") < 0 ||
		merged.policy.capabilities.ai.prefer_region_from != "standard" ||
		merged.policy.routing_rules?.[0]?.value != "example.com" ||
		merged.policy.fail_open.probes?.[0]?.url != "https://new-path.example.invalid" ||
	merged.policy.fail_open.probes?.[1]?.url != "https://new-guard.example.invalid" ||
	length(changes(policy, merged.policy, resources)) < 8) {
	print("config_merge_failed\n");
	exit(1);
}

const raw = json(sprintf("%J", request));
raw.providers.alpha.section = "other";
if (validate_request(policy, raw, resources).ok) {
	print("raw_provider_field_accepted\n");
	exit(1);
}

const routing = json(sprintf("%J", request));
routing.routing_rules = [
	{ kind: "ip_cidr", value: "2001:db8::/32", capability: "ai" },
	{ kind: "ip_cidr", value: "192.0.2.0/24", target: "direct" },
	{ kind: "domain_suffix", value: "local.example", target: "direct" }
];
const routing_result = apply(policy, routing, resources);
if (!routing_result.ok || routing_result.policy.routing_rules[1].target != "direct" ||
	routing_result.policy.routing_rules[0].capability != "ai") {
	print("routing_request_merge_failed\n"); exit(1);
}
routing.routing_rules[0].value = "2001:db8::1/32";
if (validate_request(policy, routing, resources).ok) { print("invalid_network_request_accepted\n"); exit(1); }
routing.routing_rules[0].value = "2001:db8::/32";
routing.capabilities.ai.enabled = false;
if (validate_request(policy, routing, resources).ok) { print("disabled_routing_target_accepted\n"); exit(1); }

const missing_sections = json(sprintf("%J", request));
delete missing_sections.policy_source;
delete missing_sections.automation;
delete missing_sections.safety;
if (validate_request(policy, missing_sections, resources).ok) {
	print("missing_request_sections_accepted\n");
	exit(1);
}

const unknown = json(sprintf("%J", request));
unknown.providers.unknown = { section: "unknown", enabled: true, role: "primary", billing: "subscription", region_ids: ["japan"] };
if (validate_request(policy, unknown, resources).ok) {
	print("unknown_provider_accepted\n");
	exit(1);
}

const unsafe_ref = json(sprintf("%J", request));
unsafe_ref.recovery_profile_ref = "subscription:not_present";
if (validate_request(policy, unsafe_ref, resources).ok) {
	print("unknown_recovery_profile_accepted\n");
	exit(1);
}

const no_primary = json(sprintf("%J", request));
no_primary.providers.alpha.role = "reserve";
if (apply(policy, no_primary, resources).ok) {
	print("no_primary_provider_accepted\n");
	exit(1);
}

const all_regions = json(sprintf("%J", request));
all_regions.capabilities.standard.region_ids = ["hong_kong", "japan", "singapore"];
const all_regions_merged = apply(policy, all_regions, resources);
if (!all_regions_merged.ok || all_regions_merged.policy.capabilities.standard.allowed_regions != null ||
	all_regions_merged.policy.capabilities.standard.excluded_regions != null) {
	print("all_regions_constraint_failed\n");
	exit(1);
}

const duplicate_binding = json(sprintf("%J", request));
duplicate_binding.capabilities.ai.entry_group = "OUTBOUND";
if (validate_request(policy, duplicate_binding, resources).ok) {
	print("duplicate_binding_accepted\n");
	exit(1);
}

const invented_region = json(sprintf("%J", request));
invented_region.regions.mars = { display_name: "火星", mode: "automatic" };
invented_region.providers.alpha.region_ids = ["hong_kong", "mars"];
if (validate_request(policy, invented_region, resources).ok) {
	print("invented_region_accepted\n");
	exit(1);
}

const computed_changes = changes(policy, merged.policy, resources);
if (length(filter(computed_changes, item => item.scope == "provider" && item.id == "beta" && item.field == "item")) != 1 ||
	length(filter(computed_changes, item => item.scope == "provider" && item.id == "gamma" && item.field == "item")) != 1 ||
	length(filter(computed_changes, item => item.scope == "capability" && item.id == "ai" && item.field == "item")) != 1) {
	print("identity_change_detection_failed\n");
	exit(1);
}

print("config_contract_ok\n");
