#!/usr/bin/ucode

import { recovery_owner, recovery_profile, passthrough_outcome, preferred_runtime_ready, expected_runtime_groups, expected_runtime_residue_groups } from "../openwrt/files/usr/libexec/opl-netfleet/core/activation.uc";

const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const manifest = {
	kind: "opl-netfleet-manifest",
	schema_version: 2,
	state: "staged",
	provider_mode: "file-provider",
	recovery_profile: { ref: "subscription:recovery", sha256: digest },
	artifact_sha256: digest
};
if (recovery_profile(manifest, digest, "file:OPL-NetFleet.json", digest) != "subscription:recovery" ||
	recovery_profile(manifest, digest, "subscription:recovery", digest) != "subscription:recovery" ||
	recovery_profile(manifest, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
		"file:OPL-NetFleet.json", digest) != null ||
	recovery_profile(manifest, digest, "file:OPL-NetFleet.json",
		"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") != null) {
	print("recovery_manifest_identity_failed\n");
	exit(1);
}
const self_referencing = json(sprintf("%J", manifest));
self_referencing.recovery_profile.ref = "file:OPL-NetFleet.json";
if (recovery_profile(self_referencing, digest, "file:OPL-NetFleet.json", digest) != null) {
	print("recovery_manifest_self_reference_accepted\n");
	exit(1);
}

if (!recovery_owner("file:OPL-NetFleet.json", "subscription:base", false) ||
	!recovery_owner("subscription:base", "file:OPL-NetFleet.json", false) ||
	!recovery_owner("file:opl-netfleet/mvp.json", "subscription:base", false) ||
	!recovery_owner("subscription:base", "subscription:base", true) ||
	recovery_owner("subscription:user-choice", "subscription:base", false)) {
	print("recovery_owner_scope_failed\n");
	exit(1);
}

const preferred_runtime = {
	user_mode: "automatic",
	data_path: "preferred",
	selected_group: "常规出口 · JP 日本 · Alpha",
	leaf: "Alpha Japan 01",
	alive: true
};
if (!preferred_runtime_ready(preferred_runtime, preferred_runtime.selected_group) ||
	preferred_runtime_ready({ user_mode: "unknown", data_path: "preferred", selected_group: preferred_runtime.selected_group, leaf: preferred_runtime.leaf, alive: true }, preferred_runtime.selected_group) ||
	preferred_runtime_ready({ user_mode: "automatic", data_path: "unknown", selected_group: preferred_runtime.selected_group, leaf: preferred_runtime.leaf, alive: true }, preferred_runtime.selected_group) ||
	preferred_runtime_ready({ user_mode: "automatic", data_path: "preferred", selected_group: "旧地区", leaf: preferred_runtime.leaf, alive: true }, preferred_runtime.selected_group) ||
	preferred_runtime_ready({ user_mode: "automatic", data_path: "preferred", selected_group: preferred_runtime.selected_group, leaf: null, alive: true }, preferred_runtime.selected_group) ||
	preferred_runtime_ready({ user_mode: "automatic", data_path: "preferred", selected_group: preferred_runtime.selected_group, leaf: preferred_runtime.leaf, alive: false }, preferred_runtime.selected_group)) {
	print("preferred_runtime_readback_contract_failed\n");
	exit(1);
}

const runtime_groups = expected_runtime_groups({
	generated_groups: {
		standard: {
			name: "常规出口",
			automatic_name: "常规出口 · 自动选优",
			selector_name: "常规出口 · 当前优选",
			proxy_path_name: "常规出口 · 代理路径",
			user_members: ["常规出口 · 自动选优", "常规出口 · 🇭🇰 香港", "DIRECT"],
			direct_name: "DIRECT",
			direct_guard_name: "NetFleet · 直连护栏",
			region_groups: [{ name: "常规出口 · 🇭🇰 香港", primary_name: "常规出口 · 🇭🇰 香港 · 主用" }],
				providers: { alpha: { group: "常规出口 · Alpha 机场" } },
				candidate_groups: [{ name: "常规出口 · 🇭🇰 香港 · Alpha 机场", group: "常规出口 · Alpha 机场" }]
		}
	}
});
if (index(runtime_groups, "DIRECT") >= 0 ||
	index(runtime_groups, "NetFleet · 直连护栏") < 0 ||
	index(runtime_groups, "常规出口 · 自动选优") < 0 ||
	index(runtime_groups, "常规出口 · 🇭🇰 香港 · Alpha 机场") < 0) {
	print("runtime_owner_groups_failed\n");
	exit(1);
}
const residue_groups = expected_runtime_residue_groups({
	generated_groups: {
		standard: {
			name: "原生入口",
			automatic_name: "自动选优",
			direct_guard_name: "直连护栏"
		}
	}
}, ["原生入口"]);
if (index(residue_groups, "原生入口") >= 0 ||
	index(residue_groups, "自动选优") < 0 || index(residue_groups, "直连护栏") < 0) {
	print("native_entry_group_must_not_be_runtime_residue\n");
	exit(1);
}

let result = passthrough_outcome({ ok: true }, true, false);
if (!result.ok || !result.safe || !result.persistent || result.business_ok != false) {
	print("direct_probe_failure_must_not_block_safe_passthrough\n");
	exit(1);
}

result = passthrough_outcome({ ok: true }, true, null);
if (!result.ok || result.business_ok != null) {
	print("unavailable_business_probe_must_remain_unknown\n");
	exit(1);
}

result = passthrough_outcome({ ok: true }, false, true);
if (result.ok || !result.safe || result.persistent || result.business_ok != true) {
	print("missing_persistence_must_block_completion\n");
	exit(1);
}

result = passthrough_outcome({ ok: false }, true, true);
if (result.ok || result.safe || !result.persistent) {
	print("unverified_cleanup_must_not_claim_passthrough\n");
	exit(1);
}

result = passthrough_outcome({ ok: true }, true, "unavailable");
if (!result.ok || result.business_ok != null) {
	print("non_boolean_business_probe_must_remain_unknown\n");
	exit(1);
}

print("activation_contract_ok\n");
