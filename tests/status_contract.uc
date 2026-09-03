#!/usr/bin/ucode

import { build } from "../openwrt/files/usr/libexec/opl-netfleet/core/status.uc";
import { MEASUREMENT_MODEL } from "../openwrt/files/usr/libexec/opl-netfleet/core/evidence.uc";

const policy = {
	main: { enabled: true },
	policy_source: { kind: "profile", ref: "subscription:source" },
	recovery_profile: { ref: "subscription:recovery" },
	bindings: {
		OUTBOUND: { capability: "standard", kind: "entry" },
		"AI-OUTBOUND": { capability: "ai-compatible", kind: "entry" },
		"CLAUDE-OUTBOUND": { capability: "ai-compatible", kind: "policy" },
		PARKED: { capability: "parked", kind: "policy" }
	},
	providers: {
		alpha: { enabled: true, role: "primary", billing: "subscription" },
		beta: { enabled: true, role: "reserve", billing: "buyout" }
	},
	regions: {
		south: { mode: "automatic", display_name: "南方", display_order: 20 },
		north: { mode: "automatic", display_name: "北方", flag: "🇯🇵", display_order: 10 }
	},
	capabilities: {
		standard: {
			display_name: "常规出口",
			display_order: 10,
			enabled: true,
			mode: "automatic"
		},
		"ai-compatible": {
			display_name: "AI 出口",
			display_order: 20,
			enabled: true,
			mode: "automatic",
			allowed_regions: ["north"],
			prefer_region_from: "standard",
			leaf_switch_margin_ms: 80
		},
		parked: { display_name: "停放能力", enabled: false, mode: "manual" }
	},
	selection: { region_switch_margin_ms: 150, leaf_switch_margin_ms: 150 }
};
const manifest = {
	artifact_sha256: "artifact",
	policy_source: { kind: "profile", ref: "subscription:source", sha256: "source" },
	recovery_profile: { ref: "subscription:recovery", sha256: "recovery" },
	policy_sha256: "policy",
	generated_groups: {
			standard: {
				name: "常规出口",
				automatic_name: "常规出口 · 自动选优",
				selector_name: "常规出口 · 当前优选",
				proxy_path_name: "常规出口 · 代理路径",
				direct_guard_name: "NetFleet · 直连护栏",
			base_group: "OUTBOUND",
			mode: "automatic",
				providers: {
					alpha: { group: "常规出口 · Alpha", role: "primary", source_name: "SOURCE-ALPHA" },
					beta: { group: "常规出口 · Beta", role: "reserve", source_name: "SOURCE-BETA" }
				},
				candidate_groups: [
					{ name: "常规出口 · 🇯🇵 北方 · Alpha", provider: "alpha", region: "north", role: "primary" },
					{ name: "常规出口 · 南方 · Beta", provider: "beta", region: "south", role: "reserve" }
				],
				region_groups: [
					{ region: "north", name: "常规出口 · 🇯🇵 北方", primary_name: "常规出口 · 🇯🇵 北方 · 主用", reserve_name: null },
					{ region: "south", name: "常规出口 · 南方", primary_name: null, reserve_name: "常规出口 · 南方 · 备用" }
				],
				fail_open_stages: [
					{ kind: "preferred", group: "常规出口 · 当前优选", provider_ids: [] },
					{ kind: "provider_tier", role: "primary", group: "常规出口 · 主用机场", provider_ids: ["alpha"] },
					{ kind: "provider_tier", role: "reserve", group: "常规出口 · 备用机场", provider_ids: ["beta"] },
					{ kind: "direct", group: "NetFleet · 直连护栏", provider_ids: [] }
				]
			},
			"ai-compatible": {
				name: "AI 出口",
				automatic_name: "AI 出口 · 自动选优",
				selector_name: "AI 出口 · 当前优选",
				proxy_path_name: "AI 出口 · 代理路径",
				direct_guard_name: "NetFleet · 直连护栏",
			base_group: "AI-OUTBOUND",
			base_groups: ["AI-OUTBOUND", "CLAUDE-OUTBOUND"],
			business_routes: [{ name: "CLAUDE-OUTBOUND", default_route: "capability" }],
			mode: "automatic",
			prefer_region_from: "standard",
			leaf_switch_margin_ms: 80,
				providers: {
					alpha: { group: "AI 出口 · Alpha", role: "primary", source_name: "SOURCE-ALPHA" }
				},
				candidate_groups: [
					{ name: "AI 出口 · 🇯🇵 北方 · Alpha", provider: "alpha", region: "north", role: "primary" }
				],
				region_groups: [
					{ region: "north", name: "AI 出口 · 🇯🇵 北方", primary_name: "AI 出口 · 🇯🇵 北方 · 主用", reserve_name: null }
				],
				fail_open_stages: [
					{ kind: "preferred", group: "AI 出口 · 当前优选", provider_ids: [] },
					{ kind: "provider_tier", role: "primary", group: "AI 出口 · 主用机场", provider_ids: ["alpha"] },
					{ kind: "direct", group: "NetFleet · 直连护栏", provider_ids: [] }
				]
		}
	}
};
const state = {
	proxies: {
		"常规出口": { alive: true, now: "常规出口 · 自动选优", all: ["常规出口 · 自动选优", "常规出口 · 🇯🇵 北方", "常规出口 · 南方", "DIRECT"] },
		"常规出口 · 自动选优": { alive: true, now: "常规出口 · 代理路径", all: ["常规出口 · 代理路径", "NetFleet · 直连护栏"] },
		"常规出口 · 代理路径": { alive: true, now: "常规出口 · 当前优选", all: ["常规出口 · 当前优选", "常规出口 · 主用机场", "常规出口 · 备用机场"] },
		"常规出口 · 主用机场": { alive: true, now: "常规出口 · Alpha", all: ["常规出口 · Alpha"] },
		"常规出口 · 备用机场": { alive: true, now: "常规出口 · Beta", all: ["常规出口 · Beta"] },
		"常规出口 · 当前优选": { alive: true, now: "常规出口 · 🇯🇵 北方 · Alpha" },
		"常规出口 · 🇯🇵 北方": { alive: true, now: "常规出口 · 🇯🇵 北方 · 主用", all: ["常规出口 · 🇯🇵 北方 · 主用", "NetFleet · 直连护栏"] },
		"常规出口 · 🇯🇵 北方 · 主用": { alive: true, now: "常规出口 · 🇯🇵 北方 · Alpha" },
		"常规出口 · 南方": { alive: true, now: "常规出口 · 南方 · 备用", all: ["常规出口 · 南方 · 备用", "NetFleet · 直连护栏"] },
		"常规出口 · 南方 · 备用": { alive: true, now: "常规出口 · 南方 · Beta" },
		"常规出口 · 🇯🇵 北方 · Alpha": { alive: true, now: "provider-only-alpha", all: ["node-a", "node-shared", "provider-only-alpha"] },
		"常规出口 · 南方 · Beta": { alive: true, now: "provider-only-beta", all: ["provider-only-beta"] },
		"常规出口 · Alpha": { alive: true, now: "provider-only-alpha", all: ["provider-only-alpha"] },
		"常规出口 · Beta": { alive: true, now: "provider-only-beta", all: ["provider-only-beta"] },
		"AI 出口": { alive: true, now: "AI 出口 · 自动选优", all: ["AI 出口 · 自动选优", "AI 出口 · 🇯🇵 北方", "DIRECT"] },
		"AI 出口 · 自动选优": { alive: true, now: "AI 出口 · 代理路径", all: ["AI 出口 · 代理路径", "NetFleet · 直连护栏"] },
		"AI 出口 · 代理路径": { alive: true, now: "AI 出口 · 当前优选", all: ["AI 出口 · 当前优选", "AI 出口 · 主用机场"] },
		"AI 出口 · 主用机场": { alive: true, now: "AI 出口 · Alpha", all: ["AI 出口 · Alpha"] },
		"AI 出口 · 当前优选": { alive: true, now: "AI 出口 · 🇯🇵 北方 · Alpha" },
		"AI 出口 · 🇯🇵 北方": { alive: true, now: "AI 出口 · 🇯🇵 北方 · 主用", all: ["AI 出口 · 🇯🇵 北方 · 主用", "NetFleet · 直连护栏"] },
		"AI 出口 · 🇯🇵 北方 · 主用": { alive: true, now: "AI 出口 · 🇯🇵 北方 · Alpha" },
		"AI 出口 · 🇯🇵 北方 · Alpha": { alive: true, now: "node-ai", all: ["node-ai"] },
		"AI 出口 · Alpha": { alive: true, now: "node-ai" },
		"NetFleet · 直连护栏": { alive: true, now: "DIRECT", all: ["DIRECT"] },
		"node-a": { alive: true },
		"node-ai": { alive: true },
		"node-shared": { alive: false },
		"node-b": { alive: true },
		DIRECT: { alive: true, type: "direct" }
	},
	providers: {
		"SOURCE-ALPHA": { proxies: [
			{ name: "node-a", type: "Hysteria2", alive: true },
			{ name: "node-ai", type: "Hysteria2", alive: true },
			{ name: "node-shared", type: "Hysteria2", alive: false },
			{ name: "provider-only-alpha", type: "Hysteria2", alive: true }
		] },
		"SOURCE-BETA": { proxies: [
			{ name: "provider-only-beta", type: "Hysteria2", alive: true }
		] }
	}
};
const evidence = {
	schema_version: 3,
	identity: { artifact_sha256: "artifact", policy_source_sha256: "source", policy_sha256: "policy", measurement_model: MEASUREMENT_MODEL },
	sampled_at: 123,
	capabilities: {
		standard: {
			sampled_at: 123,
				decision: { group: "常规出口 · 🇯🇵 北方 · Alpha", provider_id: "alpha",
				region_id: "north", delay_ms: 12, layer: "primary", changed_region: false,
				reason: "current_region_fastest", preferred_region: null },
			protected_probes: { ok: true, count: 2 },
			entries: [
					{ candidate: "常规出口 · 🇯🇵 北方 · Alpha", sampled_at: 123, ok: true, provider_id: "alpha", region_id: "north", delay_ms: 12 },
					{ candidate: "常规出口 · 南方 · Beta", sampled_at: 123, ok: true, provider_id: "beta", region_id: "south", delay_ms: 20 }
			],
			providers: {
				alpha: { last_best_delay_ms: 12, total_best_delay_ms: 30, sample_count: 2, sampled_at: 123 },
				beta: { last_best_delay_ms: 20, total_best_delay_ms: 20, sample_count: 1, sampled_at: 123 }
			},
			regions: {
				north: { last_best_delay_ms: 12, total_best_delay_ms: 30, sample_count: 2, sampled_at: 123 },
				south: { last_best_delay_ms: 20, total_best_delay_ms: 20, sample_count: 1, sampled_at: 123 }
			}
		},
		"ai-compatible": {
			sampled_at: 123,
				decision: { group: "AI 出口 · 🇯🇵 北方 · Alpha", provider_id: "alpha",
				region_id: "north", delay_ms: 18, layer: "primary", changed_region: false,
				reason: "followed_capability_region", preferred_region: "north" },
			protected_probes: { ok: true, count: 2 },
				entries: [{ candidate: "AI 出口 · 🇯🇵 北方 · Alpha", sampled_at: 123, ok: true,
				provider_id: "alpha", region_id: "north", delay_ms: 18 }],
			providers: { alpha: { last_best_delay_ms: 18, total_best_delay_ms: 18, sample_count: 1, sampled_at: 123 } },
			regions: { north: { last_best_delay_ms: 18, total_best_delay_ms: 18, sample_count: 1, sampled_at: 123 } }
		}
	}
};
const result = build(policy, manifest, state, evidence, {
	build: { version: "0.3.0", source_commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", source_tree: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
	active: true,
	profile: "file:OPL-NetFleet.json",
	netfleet_present: true,
	nikki_enabled: true,
	mihomo_running: true,
	quotas: {
		alpha: { state: "available", remaining_bytes: 10 },
		beta: { state: "available", remaining_bytes: 20 }
	},
		provider_names: {
			alpha: "Alpha 正式机场",
			beta: "Beta 正式机场"
		},
		automation: { enabled: true, selection_interval_seconds: 1800, poll_interval_seconds: 15, startup_grace_seconds: 120, runtime_grace_seconds: 45 },
		supervisor: { installed: true, enabled: true, running: true }
});

const stale_evidence = json(sprintf("%J", evidence));
stale_evidence.identity.artifact_sha256 = "stale";
const stale_evidence_result = build(policy, manifest, state, stale_evidence, {
	active: true,
	profile: "file:OPL-NetFleet.json",
	netfleet_present: true,
	nikki_enabled: true,
	mihomo_running: true,
	quotas: {}
});

const legacy_manifest = json(sprintf("%J", manifest));
delete legacy_manifest.generated_groups["ai-compatible"].business_routes;
legacy_manifest.generated_groups["ai-compatible"].policy_groups = ["CLAUDE-OUTBOUND"];
const legacy_state = json(sprintf("%J", state));
legacy_state.proxies["CLAUDE-OUTBOUND"] = { all: ["DIRECT", "AI 出口 · 自动选优"] };
const legacy_result = build(policy, legacy_manifest, legacy_state, evidence, {
	active: true,
	profile: "file:OPL-NetFleet.json",
	netfleet_present: true,
	nikki_enabled: true,
	mihomo_running: true,
	quotas: {}
});

function find_by_id(items, id) {
	for (let i = 0; i < length(items); i++) {
		if (items[i]?.id == id) {
			return items[i];
		}
	}
	return null;
};

const alpha = find_by_id(result.providers, "alpha");
const beta = find_by_id(result.providers, "beta");
const north = find_by_id(result.regions, "north");
const south = find_by_id(result.regions, "south");
const standard = find_by_id(result.capabilities, "standard");
const ai = find_by_id(result.capabilities, "ai-compatible");
const parked = find_by_id(result.capabilities, "parked");
if (result.build?.version != "0.3.0" ||
	result.build?.source_commit != "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ||
	!result.active || result.policy_enabled != true ||
	("mode" in result.selection) ||
	result.selection?.automatic_capability_id != "standard" ||
	length(result.selection?.automatic_capability_ids ?? []) != 2 ||
	result.selection?.region_switch_margin_ms != 150 ||
	result.selection?.leaf_switch_margin_ms != 150 ||
	standard?.display_name != "常规出口" || standard?.reason.kind != "automatic_decision" ||
	standard?.data_path != "preferred" || standard?.user_mode != "automatic" ||
	standard?.leaf != "provider-only-alpha" ||
	standard?.preferred_leaf != "provider-only-alpha" ||
	ai?.display_name != "AI 出口" || ai?.enabled != true || ai?.compiled != true ||
	ai?.mode != "automatic" || ai?.data_path != "preferred" || ai?.leaf != "node-ai" ||
	length(ai?.base_groups ?? []) != 2 || ai?.prefer_region_from != "standard" ||
	ai?.business_routes?.[0]?.name != "CLAUDE-OUTBOUND" || ai?.business_routes?.[0]?.default_route != "capability" ||
	length(standard?.fail_open_stages ?? []) != 4 || standard?.fail_open_stages?.[2]?.role != "reserve" ||
	ai?.leaf_switch_margin_ms != 80 || ai?.reason.kind != "automatic_decision" ||
	ai?.reason.decision_reason != "followed_capability_region" ||
	parked?.enabled != false || parked?.compiled != false || parked?.data_path != "disabled" ||
	parked?.base_group != "PARKED" || alpha?.available_count != 2 ||
	result.actions?.can_enable != false || result.actions?.can_select_auto != true ||
	alpha?.best_delay_ms != 12 || alpha?.last_best_delay_ms != 12 ||
	alpha?.average_best_delay_ms != 15 || alpha?.delay_sample_count != 2 || north?.selected != true ||
	beta?.last_best_delay_ms != 20 || beta?.average_best_delay_ms != 20 || beta?.delay_sample_count != 1 ||
	alpha?.display_name != "Alpha 正式机场" || alpha?.region_count != 1 ||
	alpha?.available_region_count != 1 || north?.display_name != "🇯🇵 北方" ||
	north?.provider_count != 1 || north?.available_provider_count != 1 ||
	north?.node_count != 4 || north?.available_node_count != 3 ||
	north?.last_best_delay_ms != 12 || north?.average_best_delay_ms != 15 ||
	north?.delay_sample_count != 2 ||
	south?.node_count != 1 || south?.available_node_count != 1 ||
	south?.provider_count != 1 || south?.available_provider_count != 1 ||
	south?.last_best_delay_ms != 20 || south?.average_best_delay_ms != 20 ||
	find_by_id(stale_evidence_result.regions, "north")?.last_best_delay_ms != null ||
	find_by_id(stale_evidence_result.providers, "alpha")?.last_best_delay_ms != null ||
	stale_evidence_result.capabilities[0].reason.kind != "initial_or_manual" ||
	find_by_id(legacy_result.capabilities, "ai-compatible")?.business_routes?.[0]?.default_route != "direct" ||
	result.runtime?.supervisor?.running != true || result.selection?.automation_paused != false) {
	print("status_contract_failed\n");
	exit(1);
}

const lagging_ancestor_state = json(sprintf("%J", state));
lagging_ancestor_state.proxies["常规出口"].alive = false;
lagging_ancestor_state.proxies["常规出口 · 自动选优"].alive = false;
lagging_ancestor_state.proxies["常规出口 · 代理路径"].alive = false;
lagging_ancestor_state.proxies["常规出口 · 当前优选"].alive = false;
const lagging_ancestor_result = build(policy, manifest, lagging_ancestor_state, evidence, {
	active: true,
	profile: "file:OPL-NetFleet.json",
	netfleet_present: true,
	nikki_enabled: true,
	mihomo_running: true,
	quotas: {}
});
if (lagging_ancestor_result.capabilities[0].data_path != "preferred" ||
	lagging_ancestor_result.capabilities[0].leaf != "provider-only-alpha" ||
	lagging_ancestor_result.capabilities[0].alive != true) {
	print("lagging_ancestor_status_failed\n");
	exit(1);
}

const lagging_provider_state = json(sprintf("%J", state));
lagging_provider_state.providers["SOURCE-ALPHA"].proxies[3].alive = false;
const lagging_provider_result = build(policy, manifest, lagging_provider_state, evidence, {
	active: true,
	profile: "file:OPL-NetFleet.json",
	netfleet_present: true,
	nikki_enabled: true,
	mihomo_running: true,
	quotas: {}
});
if (lagging_provider_result.capabilities[0].data_path != "preferred" ||
	lagging_provider_result.capabilities[0].leaf != "provider-only-alpha" ||
	lagging_provider_result.capabilities[0].alive != true) {
	print("lagging_provider_status_failed\n");
	exit(1);
}

const unavailable_terminal_state = json(sprintf("%J", state));
unavailable_terminal_state.proxies["常规出口 · 🇯🇵 北方 · Alpha"].alive = false;
const unavailable_terminal_result = build(policy, manifest, unavailable_terminal_state, evidence, {
	active: true,
	profile: "file:OPL-NetFleet.json",
	netfleet_present: true,
	nikki_enabled: true,
	mihomo_running: true,
	quotas: {}
});
if (unavailable_terminal_result.capabilities[0].leaf != null ||
	unavailable_terminal_result.capabilities[0].alive != false) {
	print("unavailable_terminal_status_failed\n");
	exit(1);
}

const fallback_state = json(sprintf("%J", state));
fallback_state.proxies["常规出口 · 代理路径"].now = "常规出口 · 备用机场";
const fallback_result = build(policy, manifest, fallback_state, evidence, {
	active: true,
	profile: "file:OPL-NetFleet.json",
	netfleet_present: true,
	nikki_enabled: true,
	mihomo_running: true,
	quotas: {}
});
if (fallback_result.capabilities[0].data_path != "provider_fallback" ||
	fallback_result.capabilities[0].provider_id != "beta" ||
	fallback_result.capabilities[0].leaf != "provider-only-beta" ||
	fallback_result.capabilities[0].reason.kind != "provider_fallback" ||
	fallback_result.providers[1].selected != true) {
	print("provider_fallback_status_failed\n");
	exit(1);
}

const direct_state = json(sprintf("%J", state));
direct_state.proxies["常规出口 · 自动选优"].now = "NetFleet · 直连护栏";
const direct_result = build(policy, manifest, direct_state, evidence, {
	active: true,
	profile: "file:OPL-NetFleet.json",
	netfleet_present: true,
	nikki_enabled: true,
	mihomo_running: true,
	quotas: {}
});
if (direct_result.capabilities[0].data_path != "direct_fallback" ||
	direct_result.capabilities[0].leaf != "DIRECT" ||
	direct_result.capabilities[0].alive != true ||
	direct_result.capabilities[0].reason.kind != "direct_fallback") {
	print("direct_fallback_status_failed\n");
	exit(1);
}

const manual_state = json(sprintf("%J", state));
manual_state.proxies["常规出口"].now = "常规出口 · 🇯🇵 北方";
const manual_result = build(policy, manifest, manual_state, evidence, {
	active: true,
	profile: "file:OPL-NetFleet.json",
	netfleet_present: true,
	nikki_enabled: true,
	mihomo_running: true,
	quotas: {}
});
if (manual_result.capabilities[0].data_path != "manual_region" ||
	manual_result.capabilities[0].user_mode != "manual_region" ||
	manual_result.capabilities[0].region_id != "north" ||
	manual_result.selection?.automation_paused != true) {
	print("manual_region_status_failed\n");
	exit(1);
}

const passthrough_result = build(policy, manifest, { proxies: {} }, evidence, {
	active: false,
	profile: "subscription:base",
	nikki_enabled: false,
	mihomo_running: false,
	cleanup: { ok: true },
	quotas: {}
});
if (passthrough_result.active != false ||
	passthrough_result.capabilities[0].data_path != "passthrough" ||
	passthrough_result.capabilities[0].user_mode != "native_profile" ||
	passthrough_result.capabilities[0].reason.kind != "passthrough" ||
	passthrough_result.runtime.passthrough_ready != true) {
	print("passthrough_status_failed\n");
	exit(1);
}

const stale_owner_result = build(policy, manifest, state, evidence, {
	active: false,
	profile: "subscription:base",
	netfleet_present: true,
	nikki_enabled: true,
	mihomo_running: true,
	quotas: {}
});
const native_state = {
	proxies: {
		OUTBOUND: { alive: true, now: "Native-Auto" },
		"AI-OUTBOUND": { alive: true, now: "Native-AI" },
		"CLAUDE-OUTBOUND": { alive: true, now: "Native-AI" },
		"Native-Auto": { alive: true, now: "native-standard-leaf" },
		"Native-AI": { alive: true, now: "native-ai-leaf" },
		"native-standard-leaf": { alive: true, type: "Hysteria2" },
		"native-ai-leaf": { alive: true, type: "Hysteria2" }
	}
};
const native_owner_result = build(policy, manifest, native_state, evidence, {
	active: false,
	profile: "subscription:recovery",
	profile_display_name: "Base 正式机场",
	recovery_profile_display_name: "Base 正式机场",
	netfleet_present: false,
	nikki_enabled: true,
	mihomo_running: true,
	quotas: {}
});
const uncompiled_manifest = json(sprintf("%J", manifest));
uncompiled_manifest.generated_groups.standard.candidate_groups = [];
const uncompiled_owner_result = build(policy, uncompiled_manifest, state, evidence, {
	active: true,
	profile: "file:OPL-NetFleet.json",
	netfleet_present: true,
	nikki_enabled: true,
	mihomo_running: true,
	quotas: {}
});
if (stale_owner_result.actions?.can_disable != true ||
	stale_owner_result.actions?.can_enable != false ||
	native_owner_result.actions?.can_enable != true ||
	native_owner_result.actions?.can_select_auto != false ||
	native_owner_result.native_runtime?.mode != "native_profile" ||
	native_owner_result.native_runtime?.profile_display_name != "Base 正式机场" ||
	native_owner_result.recovery_profile_display_name != "Base 正式机场" ||
	native_owner_result.native_runtime?.paths?.[0]?.state != "available" ||
	native_owner_result.capabilities?.[0]?.data_path != "native_profile" ||
	native_owner_result.capabilities?.[0]?.user_mode != "native_profile" ||
	native_owner_result.capabilities?.[0]?.runtime_path?.[1] != "Native-Auto" ||
	native_owner_result.capabilities?.[0]?.leaf != "native-standard-leaf" ||
	native_owner_result.capabilities?.[0]?.alive != true ||
	passthrough_result.native_runtime?.mode != "passthrough" ||
	uncompiled_owner_result.actions?.can_select_auto != false ||
	stale_owner_result.runtime?.netfleet_present != true) {
	print("stale_runtime_disable_action_missing\n");
	exit(1);
}

print("status_contract_ok\n");
