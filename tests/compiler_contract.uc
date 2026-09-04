#!/usr/bin/ucode

import { compile } from "../openwrt/files/usr/libexec/opl-netfleet/core/compiler.uc";
import { validate } from "../openwrt/files/usr/libexec/opl-netfleet/core/policy.uc";

const profile = {
	dns: {
		"default-nameserver": ["223.5.5.5", "119.29.29.29"],
		nameserver: ["https://dns.alidns.com/dns-query", "https://doh.pub/dns-query"],
		"proxy-server-nameserver": ["https://dns.alidns.com/dns-query", "https://doh.pub/dns-query"],
		"respect-rules": false,
		"nameserver-policy": {
			"rule-set:geolocation-non-cn": ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]
		},
		fallback: ["tls://1.1.1.1", "tls://8.8.8.8"],
		"fallback-filter": {
			geoip: true,
			"geoip-code": "CN",
			ipcidr: ["240.0.0.0/4", "0.0.0.0/32", "127.0.0.1/32", "100.64.0.0/10"],
			domain: ["+.google.com", "+.facebook.com", "+.youtube.com"]
		}
	},
	"proxy-groups": [
		{ name: "Outbound", type: "select", proxies: ["Auto", "NearLegacy", "DIRECT"] },
		{ name: "AI", type: "select", proxies: ["DIRECT"] },
		{ name: "Claude", type: "select", proxies: ["provider-raw", "DIRECT"] },
		{ name: "Streaming", type: "select", proxies: ["provider-raw", "DIRECT"] },
		{ name: "DirectFirst", type: "select", proxies: ["DIRECT", "Outbound"] },
		{ name: "Parked", type: "select", proxies: ["DIRECT"] },
		{ name: "Other", type: "select", proxies: ["DIRECT"] },
		{ name: "Auto", type: "url-test", proxies: ["NearLegacy"] },
		{ name: "NearLegacy", type: "select", proxies: ["DIRECT"] }
	],
	"proxy-providers": {},
	rules: [
		"DOMAIN-SUFFIX,example.com,AI",
		"DOMAIN-SUFFIX,legacy.example,Auto",
		"IP-CIDR,192.0.2.0/24,Outbound,no-resolve",
		"MATCH,Outbound"
	],
	"sub-rules": { nested: ["DOMAIN,chat.example,AI"] }
};
const policy = {
	schema_version: 2,
	main: { target: "fixture", enabled: true },
	policy_source: { kind: "profile", ref: "file:base.json" },
	recovery_profile: { ref: "file:recovery.json" },
	routing_rules: [
		{ kind: "domain_suffix", value: "private.example", capability: "standard" }
	],
	bindings: {
		Outbound: { capability: "standard", kind: "entry" },
		Streaming: { capability: "standard", kind: "policy" },
		DirectFirst: { capability: "standard", kind: "policy" },
		AI: { capability: "ai-compatible", kind: "entry" },
		Claude: { capability: "ai-compatible", kind: "policy" },
		Parked: { capability: "parked", kind: "policy" }
	},
	providers: {
		alpha: { section: "alpha", enabled: true, role: "primary" },
		backup: { section: "backup", enabled: true, role: "reserve" }
	},
	regions: {
		far: { mode: "automatic", display_name: "加拿大", flag: "🇨🇦", display_order: 20 },
		near: { mode: "automatic", display_name: "日本", flag: "🇯🇵", display_order: 10 }
	},
	provider_regions: {
		alpha: [{ region: "near", filter: "near" }, { region: "far", filter: "far" }],
		backup: [{ region: "near", filter: "near" }, { region: "far", filter: "far" }]
	},
	capabilities: {
		standard: {
			display_name: "常规出口",
			display_order: 10,
			enabled: true,
			mode: "automatic",
			region_switch_margin_ms: 150
		},
		"ai-compatible": {
			display_name: "AI 出口",
			display_order: 20,
			enabled: true,
			mode: "automatic",
			excluded_regions: ["far"],
			prefer_region_from: "standard",
			leaf_switch_margin_ms: 80
		},
		parked: { enabled: false, mode: "manual" }
	},
	selection: { region_switch_margin_ms: 200, leaf_switch_margin_ms: 150 },
	checks: {
		provider_healthcheck_timeout_ms: 20000,
		latency: { method: "mihomo_delay", url: "https://www.gstatic.com/generate_204", timeout_ms: 2000, expected_status: 204 },
		quota: { source: "nikki_subscription_metadata", zero_is_exhausted: true }
	},
		evidence: { path: "/etc/opl-netfleet/evidence.json" },
		fail_open: {
			healthcheck: {
				path_probe_id: "path",
				guard_probe_id: "guard",
				timeout_ms: 5000,
				interval_seconds: 300,
				max_failed_times: 2
			},
			probes: [
				{ id: "path", url: "https://path.example.invalid", expected_status: 200 },
				{ id: "guard", url: "https://guard.example.invalid", expected_status: 204 }
			]
		}
};
const providers = {
	alpha: { path: "/tmp/alpha.yaml", runtime_path: "/tmp/alpha.yaml", display_name: "Alpha机场", profile: { proxies: [{ name: "near-1" }] } },
	backup: { path: "/tmp/backup.yaml", runtime_path: "/tmp/backup.yaml", display_name: "Backup机场", profile: { proxies: [{ name: "far-1" }] } }
};
const result = compile(profile, policy, "source", "recovery", "policy", providers);
const groups = {};
for (let i = 0; i < length(result.profile?.["proxy-groups"] ?? []); i++) {
	const group = result.profile["proxy-groups"][i];
	groups[group.name] = group;
}

if (!result.ok || sprintf("%J", result.profile?.dns) != sprintf("%J", profile.dns) ||
	length(keys(result.manifest.generated_groups)) != 2 ||
	result.manifest.generated_groups.standard.mode != "automatic" ||
	result.manifest.generated_groups["ai-compatible"].mode != "automatic" ||
	result.manifest.generated_groups["ai-compatible"].prefer_region_from != "standard" ||
	result.manifest.generated_groups.standard.base_type != "select" ||
	length(result.manifest.generated_groups["ai-compatible"].base_groups) != 2 ||
	result.manifest.generated_groups["ai-compatible"].business_routes?.[0]?.name != "Claude" ||
	result.manifest.generated_groups["ai-compatible"].business_routes?.[0]?.default_route != "capability" ||
	result.manifest.generated_groups.standard.entry_group != "Outbound" ||
	result.manifest.generated_groups["ai-compatible"].policy_groups?.[0] != "Claude" ||
	length(result.manifest.generated_groups.standard.candidate_groups) != 4 ||
	length(result.manifest.generated_groups["ai-compatible"].candidate_groups) != 2 ||
	length(keys(result.profile["proxy-providers"])) != 2 ||
	result.profile["proxy-providers"]["NETFLEET-SOURCE-alpha"]?.["health-check"]?.enable != false ||
	result.profile["proxy-providers"]["NETFLEET-SOURCE-alpha"]?.["health-check"]?.url !=
		"https://www.gstatic.com/generate_204" ||
	result.profile["proxy-providers"]["NETFLEET-SOURCE-alpha"]?.["health-check"]?.timeout != 2000 ||
	result.profile["proxy-providers"]["NETFLEET-SOURCE-alpha"]?.["health-check"]?.lazy != true ||
	result.profile["proxy-providers"]["NETFLEET-SOURCE-alpha"]?.["health-check"]?.["expected-status"] != 204 ||
	groups.Outbound?.proxies?.[0] != "常规出口" || length(groups.Outbound?.proxies ?? []) != 1 ||
	groups.Outbound?.hidden != true ||
	groups.AI?.proxies?.[0] != "AI 出口" || length(groups.AI?.proxies ?? []) != 1 ||
	groups.AI?.hidden != true ||
	groups["NetFleet · 直连护栏"]?.type != "select" ||
	groups["NetFleet · 直连护栏"]?.proxies?.[0] != "DIRECT" ||
	length(groups["NetFleet · 直连护栏"]?.proxies ?? []) != 1 ||
	groups["NetFleet · 直连护栏"]?.hidden != true ||
	groups.Claude?.proxies?.[0] != "AI 出口 · 自动选优" ||
	groups.Claude?.proxies?.[1] != "常规出口 · 🇯🇵 日本" ||
	groups.Claude?.proxies?.[2] != "DIRECT" ||
	length(groups.Claude?.proxies ?? []) != 3 ||
	groups.Streaming?.proxies?.[0] != "常规出口 · 自动选优" ||
	groups.Streaming?.proxies?.[1] != "常规出口 · 🇯🇵 日本" ||
	groups.Streaming?.proxies?.[3] != "DIRECT" ||
	groups.DirectFirst?.proxies?.[0] != "DIRECT" ||
	groups.DirectFirst?.proxies?.[1] != "常规出口 · 自动选优" ||
	result.manifest.generated_groups.standard.business_routes?.[1]?.name != "DirectFirst" ||
	result.manifest.generated_groups.standard.business_routes?.[1]?.default_route != "direct" ||
	groups.DirectFirst?.proxies?.[2] != "常规出口 · 🇯🇵 日本" ||
	index(groups.Streaming?.proxies ?? [], "provider-raw") >= 0 ||
	groups.Parked?.proxies?.[0] != "DIRECT" || groups.Other?.proxies?.[0] != "DIRECT" ||
	groups.Auto != null || groups.NearLegacy != null ||
	result.profile.rules?.[0] != "DOMAIN-SUFFIX,private.example,常规出口" ||
	result.profile.rules?.[1] != "DOMAIN-SUFFIX,example.com,AI 出口" ||
	result.profile.rules?.[2] != "DOMAIN-SUFFIX,legacy.example,常规出口" ||
	result.profile.rules?.[3] != "IP-CIDR,192.0.2.0/24,常规出口,no-resolve" ||
	result.profile.rules?.[4] != "MATCH,常规出口" ||
	result.manifest.routing_rule_count != 1 ||
	result.profile["sub-rules"]?.nested?.[0] != "DOMAIN,chat.example,AI 出口" ||
	result.profile["proxy-groups"]?.[0]?.name != "常规出口" ||
	result.profile["proxy-groups"]?.[1]?.name != "AI 出口" ||
	result.profile["proxy-groups"]?.[2]?.name != "Claude" ||
	result.profile["proxy-groups"]?.[3]?.name != "Streaming" ||
	result.profile["proxy-groups"]?.[4]?.name != "DirectFirst" ||
	groups["常规出口 · Alpha机场"]?.filter != "near`far" ||
	groups["常规出口 · Backup机场"]?.filter != "near`far" ||
	groups["AI 出口 · Alpha机场"]?.filter != "near" ||
	groups["AI 出口 · Backup机场"]?.filter != "near" ||
	groups["AI 出口 · 当前优选"]?.proxies?.[0] != "AI 出口 · 🇯🇵 日本 · Alpha机场" ||
	groups["常规出口 · Alpha机场"]?.tolerance != 150 ||
		groups["AI 出口 · Alpha机场"]?.tolerance != 80 ||
		groups["常规出口"]?.proxies?.[0] != "常规出口 · 自动选优" ||
		groups["常规出口"]?.proxies?.[1] != "常规出口 · 🇯🇵 日本" ||
		groups["常规出口"]?.proxies?.[3] != "DIRECT" ||
		length(groups["常规出口"]?.proxies ?? []) != 4 ||
		groups["常规出口 · 自动选优"]?.proxies?.[0] != "常规出口 · 代理路径" ||
		groups["常规出口 · 自动选优"]?.proxies?.[1] != "NetFleet · 直连护栏" ||
		groups["常规出口 · 自动选优"]?.url != "https://guard.example.invalid" ||
		groups["常规出口 · 自动选优"]?.["expected-status"] != 204 ||
		groups["常规出口 · 代理路径"]?.proxies?.[0] != "常规出口 · 当前优选" ||
		groups["常规出口 · 代理路径"]?.proxies?.[1] != "常规出口 · 主用机场" ||
		groups["常规出口 · 代理路径"]?.proxies?.[2] != "常规出口 · 备用机场" ||
		length(groups["常规出口 · 代理路径"]?.proxies ?? []) != 3 ||
		groups["常规出口 · 主用机场"]?.proxies?.[0] != "常规出口 · Alpha机场" ||
		groups["常规出口 · 备用机场"]?.proxies?.[0] != "常规出口 · Backup机场" ||
		length(result.manifest.generated_groups.standard.fail_open_stages ?? []) != 4 ||
		result.manifest.generated_groups.standard.fail_open_stages?.[1]?.role != "primary" ||
		result.manifest.generated_groups.standard.fail_open_stages?.[2]?.role != "reserve" ||
		result.manifest.generated_groups.standard.fail_open_stages?.[3]?.group != "NetFleet · 直连护栏" ||
		result.manifest.generated_groups.standard.direct_guard_name != "NetFleet · 直连护栏" ||
		groups["常规出口 · 代理路径"]?.url != "https://path.example.invalid" ||
		groups["常规出口 · Alpha机场"]?.url != "https://path.example.invalid" ||
		groups["常规出口 · 🇯🇵 日本 · Alpha机场"]?.url != "https://www.gstatic.com/generate_204" ||
	groups["常规出口 · 🇯🇵 日本"]?.proxies?.[0] != "常规出口 · 🇯🇵 日本 · 主用" ||
		groups["常规出口 · 🇯🇵 日本"]?.proxies?.[1] != "常规出口 · 🇯🇵 日本 · 备用" ||
		groups["常规出口 · 🇯🇵 日本"]?.proxies?.[2] != "NetFleet · 直连护栏" ||
		groups["AI 出口 · 代理路径"]?.proxies?.[1] != "AI 出口 · 主用机场" ||
		groups["AI 出口 · 代理路径"]?.proxies?.[2] != "AI 出口 · 备用机场" ||
		length(groups["AI 出口 · 代理路径"]?.proxies ?? []) != 3 ||
		groups["AI 出口"]?.proxies?.[0] != "AI 出口 · 自动选优" ||
		groups["AI 出口"]?.proxies?.[1] != "常规出口 · 🇯🇵 日本" ||
		groups["AI 出口"]?.proxies?.[2] != "DIRECT" ||
		length(groups["AI 出口"]?.proxies ?? []) != 3 ||
		groups["AI 出口 · 🇯🇵 日本"] != null ||
		result.manifest.generated_groups["ai-compatible"].region_groups?.[0]?.name != "常规出口 · 🇯🇵 日本" ||
		groups["NETFLEET-NATIVE-standard"] != null ||
		groups["NETFLEET-NATIVE-ai-compatible"] != null ||
	result.manifest.generated_groups.standard.region_switch_margin_ms != 150 ||
	result.manifest.generated_groups["ai-compatible"].region_switch_margin_ms != 200 ||
	result.manifest.generated_groups["ai-compatible"].leaf_switch_margin_ms != 80 ||
	("cache" in result.manifest.generated_groups.standard.providers.alpha)) {
	print("multi_capability_compiler_failed\n");
	exit(1);
}

if (!validate(policy).ok) {
	print("valid_policy_rejected\n");
	exit(1);
}

const default_display_order_policy = json(sprintf("%J", policy));
delete default_display_order_policy.capabilities.standard.display_order;
delete default_display_order_policy.capabilities["ai-compatible"].display_order;
const default_display_order_result = compile(profile, default_display_order_policy,
	"source", "recovery", "policy", providers);
if (!default_display_order_result.ok ||
	default_display_order_result.manifest.generated_groups["ai-compatible"]?.region_groups?.[0]?.name !=
		"常规出口 · 🇯🇵 日本") {
	print("capability_generation_dependency_order_failed\n");
	exit(1);
}

const same_name_profile = {
	"proxy-groups": [
		{ name: "常规出口", type: "select", proxies: ["DIRECT"] },
		{ name: "AI 出口", type: "select", proxies: ["DIRECT"] }
	],
	"proxy-providers": {},
	rules: ["DOMAIN-SUFFIX,example.com,AI 出口", "MATCH,常规出口"]
};
const same_name_policy = json(sprintf("%J", policy));
same_name_policy.policy_source = { kind: "bundle", ref: "bundle:base-v1" };
delete same_name_policy.routing_rules;
same_name_policy.bindings = {
	"常规出口": { capability: "standard", kind: "entry" },
	"AI 出口": { capability: "ai-compatible", kind: "entry" }
};
const same_name_result = compile(same_name_profile, same_name_policy, "bundle", "recovery", "policy", providers);
let standard_count = 0;
let ai_count = 0;
for (let i = 0; i < length(same_name_result.profile?.["proxy-groups"] ?? []); i++) {
	const name = same_name_result.profile["proxy-groups"][i]?.name;
	if (name == "常规出口") standard_count++;
	if (name == "AI 出口") ai_count++;
}
if (!same_name_result.ok || standard_count != 1 || ai_count != 1 ||
	same_name_result.profile["proxy-groups"]?.[0]?.name != "常规出口" ||
	same_name_result.profile["proxy-groups"]?.[1]?.name != "AI 出口" ||
	same_name_result.profile.rules?.[0] != "DOMAIN-SUFFIX,example.com,AI 出口" ||
	same_name_result.profile.rules?.[1] != "MATCH,常规出口") {
	print("same_name_entry_upgrade_failed\n");
	exit(1);
}

const direct_prefix_profile = json(sprintf("%J", profile));
direct_prefix_profile.rules = ["DOMAIN-SUFFIX,control.example,DIRECT"];
for (let i = 0; i < length(profile.rules); i++) push(direct_prefix_profile.rules, profile.rules[i]);
const direct_prefix_result = compile(direct_prefix_profile, policy,
	"source", "recovery", "policy", providers);
if (!direct_prefix_result.ok ||
	direct_prefix_result.profile.rules?.[0] != "DOMAIN-SUFFIX,control.example,DIRECT" ||
	direct_prefix_result.profile.rules?.[1] != "DOMAIN-SUFFIX,private.example,常规出口") {
	print("routing_rule_direct_prefix_order_failed\n");
	exit(1);
}

const bundle_policy = json(sprintf("%J", policy));
bundle_policy.policy_source = { kind: "bundle", ref: "bundle:base-v1" };
if (!validate(bundle_policy).ok ||
	compile(profile, bundle_policy, "bundle", "recovery", "policy", providers).manifest?.policy_source?.kind != "bundle") {
	print("bundle_policy_source_rejected\n");
	exit(1);
}
const invalid_bundle_policy = json(sprintf("%J", bundle_policy));
invalid_bundle_policy.policy_source.ref = "bundle:../escape";
if (validate(invalid_bundle_policy).ok) {
	print("unsafe_bundle_policy_source_accepted\n");
	exit(1);
}

const invalid_routing_rule = json(sprintf("%J", policy));
invalid_routing_rule.routing_rules[0].value = "bad,value";
if (validate(invalid_routing_rule).ok) {
	print("invalid_routing_rule_accepted\n");
	exit(1);
}

const unknown_routing_capability = json(sprintf("%J", policy));
unknown_routing_capability.routing_rules[0].capability = "missing";
if (validate(unknown_routing_capability).ok) {
	print("unknown_routing_capability_accepted\n");
	exit(1);
}

const missing_parent = json(sprintf("%J", policy));
missing_parent.capabilities["ai-compatible"].prefer_region_from = "missing";
if (validate(missing_parent).ok) {
	print("missing_automatic_parent_accepted\n");
	exit(1);
}

const cycle = json(sprintf("%J", policy));
cycle.capabilities.standard.prefer_region_from = "ai-compatible";
if (validate(cycle).ok) {
	print("automatic_dependency_cycle_accepted\n");
	exit(1);
}

const all_disabled = json(sprintf("%J", policy));
all_disabled.main.enabled = false;
delete all_disabled.routing_rules;
const disabled_capability_names = keys(all_disabled.capabilities);
for (let i = 0; i < length(disabled_capability_names); i++) {
	all_disabled.capabilities[disabled_capability_names[i]].enabled = false;
}
if (!validate(all_disabled).ok) {
	print("globally_disabled_policy_rejected\n");
	exit(1);
}
all_disabled.main.enabled = true;
if (validate(all_disabled).ok) {
	print("empty_enabled_policy_accepted\n");
	exit(1);
}

const missing_entry = json(sprintf("%J", policy));
missing_entry.bindings.AI.kind = "policy";
if (validate(missing_entry).ok) {
	print("missing_entry_accepted\n");
	exit(1);
}

const duplicate_entry = json(sprintf("%J", policy));
duplicate_entry.bindings.Claude.kind = "entry";
if (validate(duplicate_entry).ok) {
	print("duplicate_entry_accepted\n");
	exit(1);
}

const invalid_binding_kind = json(sprintf("%J", policy));
invalid_binding_kind.bindings.Claude.kind = "mirror";
if (validate(invalid_binding_kind).ok) {
	print("invalid_binding_kind_accepted\n");
	exit(1);
}

const invalid_display_order = json(sprintf("%J", policy));
invalid_display_order.capabilities.standard.display_order = -1;
if (validate(invalid_display_order).ok) {
	print("invalid_display_order_accepted\n");
	exit(1);
}

const shared_legacy_group = json(sprintf("%J", profile));
shared_legacy_group["proxy-groups"][1].proxies = ["Auto", "DIRECT"];
if (compile(shared_legacy_group, policy, "source", "recovery", "policy", providers).ok) {
	print("ambiguous_legacy_closure_accepted\n");
	exit(1);
}

const unstable_capability = json(sprintf("%J", policy));
unstable_capability.capabilities["bad/name"] = { enabled: false, mode: "manual" };
if (validate(unstable_capability).ok) {
	print("unstable_capability_id_accepted\n");
	exit(1);
}

const legacy_fallback_provider = json(sprintf("%J", policy));
legacy_fallback_provider.capabilities.standard.fallback_provider = "backup";
if (validate(legacy_fallback_provider).ok) {
	print("legacy_fallback_provider_accepted\n");
	exit(1);
}

const legacy_selection = json(sprintf("%J", policy));
legacy_selection.selection.mode = "automatic";
if (validate(legacy_selection).ok) {
	print("legacy_selection_owner_accepted\n");
	exit(1);
}

const legacy_availability = json(sprintf("%J", policy));
legacy_availability.checks.availability = { standard: ["protected"] };
if (validate(legacy_availability).ok) {
	print("unused_availability_contract_accepted\n");
	exit(1);
}

const unknown_path_probe = json(sprintf("%J", policy));
unknown_path_probe.fail_open.healthcheck.path_probe_id = "missing";
if (validate(unknown_path_probe).ok) {
	print("unknown_path_probe_accepted\n");
	exit(1);
}

const invalid_healthcheck_timeout = json(sprintf("%J", policy));
invalid_healthcheck_timeout.fail_open.healthcheck.timeout_ms = 0;
if (validate(invalid_healthcheck_timeout).ok) {
	print("invalid_healthcheck_timeout_accepted\n");
	exit(1);
}

const invalid_provider_healthcheck_timeout = json(sprintf("%J", policy));
invalid_provider_healthcheck_timeout.checks.provider_healthcheck_timeout_ms = 500;
if (validate(invalid_provider_healthcheck_timeout).ok) {
	print("invalid_provider_healthcheck_timeout_accepted\n");
	exit(1);
}

const coupled_region = json(sprintf("%J", policy));
coupled_region.regions.near.capability = "standard";
if (validate(coupled_region).ok) {
	print("capability_coupled_region_accepted\n");
	exit(1);
}

const anonymous_policy = json(sprintf("%J", policy));
anonymous_policy.providers.alpha.section = "@subscription[0]";
if (validate(anonymous_policy).ok) {
	print("anonymous_subscription_accepted\n");
	exit(1);
}

const generated_section_policy = json(sprintf("%J", policy));
generated_section_policy.providers.alpha.section = "cfg1c0caa";
if (validate(generated_section_policy).ok) {
	print("generated_subscription_section_accepted\n");
	exit(1);
}

const cache_override_policy = json(sprintf("%J", policy));
cache_override_policy.providers.alpha.cache = "another_cache";
if (validate(cache_override_policy).ok) {
	print("cache_override_accepted\n");
	exit(1);
}

print("multi_capability_compiler_ok\n");
