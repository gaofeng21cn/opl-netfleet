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
		{ ref: "subscription:beta", display_name: "Beta 机场" }
	]
};

const projection = project(policy, resources);
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
		alpha: { enabled: true, role: "primary", billing: "buyout" },
		beta: { enabled: true, role: "reserve", billing: "subscription" }
	},
	regions: {
		hong_kong: { display_name: "香港", mode: "manual_only" },
		japan: { display_name: "日本", mode: "automatic" }
	},
	capabilities: {
		standard: { enabled: true, mode: "automatic", region_ids: ["japan"] }
	},
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
	merged.policy.regions.hong_kong.flag != "🇭🇰" ||
	merged.policy.capabilities.standard.allowed_regions != null ||
	merged.policy.capabilities.standard.excluded_regions?.[0] != "hong_kong" ||
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

const unknown = json(sprintf("%J", request));
unknown.providers.unknown = { enabled: true, role: "primary", billing: "subscription" };
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
all_regions.capabilities.standard.region_ids = ["hong_kong", "japan"];
const all_regions_merged = apply(policy, all_regions, resources);
if (!all_regions_merged.ok || all_regions_merged.policy.capabilities.standard.allowed_regions != null ||
	all_regions_merged.policy.capabilities.standard.excluded_regions != null) {
	print("all_regions_constraint_failed\n");
	exit(1);
}

print("config_contract_ok\n");
