#!/usr/bin/ucode
import * as fs from "fs";
import { use, release as release_services } from "./services.uc";

const discover = use("configuration.onboarding-model").discover;
const draft = use("configuration.onboarding-model").draft;

function base_input() {
	return {
		target: "OpenWrt",
		current_profile: "subscription:base",
		current_profile_display_name: "当前原生配置",
		current_profile_digest: "a",
		current_profile_object: {
			proxies: [{ name: "Base" }],
			"proxy-groups": [{ name: "节点选择", type: "select", proxies: ["Base", "DIRECT"] }],
			rules: ["MATCH,节点选择"]
		},
		subscriptions: [
			{ section: "beta", display_name: "Beta", digest: "c", profile: { proxies: [
				{ name: "Beta 🇯🇵 Tokyo 01" }, { name: "Beta SG 01" }, { name: "Beta Switzerland 01" }
			] } },
			{ section: "alpha", display_name: "Alpha", digest: "b", profile: { proxies: [
				{ name: "Alpha 香港 01" }, { name: "Alpha Taiwan 01" }, { name: "Alpha Vietnam 01" }
			] } }
		],
		backend_enabled: true,
		mihomo_running: true,
		runtime_valid: true,
		controller_ready: true,
		generated_artifacts_present: false
	};
};

const result = discover(base_input());
if (!result.ready || result.policy.policy_source.ref != "subscription:base" ||
	result.policy.recovery_profile.ref != "subscription:base" ||
	result.policy.bindings["节点选择"]?.kind != "entry" ||
	length(keys(result.policy.providers)) != 2 ||
	result.policy.providers.alpha?.role != "primary" || result.policy.providers.beta?.role != "primary" ||
	result.policy.regions.hong_kong?.flag != "HK" || result.policy.regions.taiwan?.flag != "TW" ||
	result.policy.regions.japan?.flag != "JP" || result.policy.regions.vietnam?.flag != "VN" ||
	result.policy.regions.switzerland != null ||
	result.preview.providers[0]?.id != "alpha" || result.preview.providers[1]?.id != "beta") {
	print("onboarding_discovery_failed\n");
	exit(1);
}

const one_provider = base_input();
one_provider.subscriptions = [one_provider.subscriptions[0]];
const one_result = discover(one_provider);
if (!one_result.ready || length(keys(one_result.policy.providers)) != 1 ||
	one_result.policy.providers.beta?.role != "primary") {
	print("single_provider_onboarding_failed\n");
	exit(1);
}

const no_match = base_input();
no_match.current_profile_object.rules = [];
no_match.current_profile_object["proxy-groups"][0].name = "自定义入口";
const no_match_result = discover(no_match);
if (no_match_result.ready || no_match_result.blockers[0]?.code != "entry_group_unresolved") {
	print("unresolved_entry_group_accepted\n");
	exit(1);
}

const no_cache = base_input();
no_cache.subscriptions = [];
const no_cache_result = discover(no_cache);
if (no_cache_result.ready || no_cache_result.blockers[0]?.code != "subscription_cache_missing") {
	print("missing_subscription_cache_accepted\n");
	exit(1);
}

const unknown_regions = base_input();
unknown_regions.subscriptions = [{ section: "alpha", display_name: "Alpha", digest: "b", profile: {
	proxies: [{ name: "Alpha Switzerland 01" }]
} }];
const unknown_result = discover(unknown_regions);
if (unknown_result.ready || unknown_result.blockers[0]?.code != "recognized_region_missing" ||
	length(unknown_result.preview.regions) != 0) {
	print("unknown_region_promoted\n");
	exit(1);
}

const unstable = base_input();
unstable.mihomo_running = false;
const unstable_result = discover(unstable);
if (unstable_result.ready || unstable_result.blockers[0]?.code != "backend_runtime_unhealthy") {
	print("unhealthy_nikki_accepted\n");
	exit(1);
}

if (sprintf("%J", discover(base_input()).revision_input) != sprintf("%J", discover(base_input()).revision_input)) {
	print("onboarding_revision_input_unstable\n");
	exit(1);
}

const offline = base_input();
offline.backend_enabled = false;
offline.mihomo_running = false;
offline.runtime_valid = false;
offline.controller_ready = false;
offline.evidence_path = "/private/desktop/evidence.json";
const draft_result = draft(offline);
if (!draft_result.ready || draft_result.readiness != "configuration" ||
	draft_result.policy.evidence.path != offline.evidence_path || discover(offline).ready ||
	draft(no_cache).ready || draft(no_match).ready) {
	print("offline_draft_runtime_boundary_failed\n");
	exit(1);
}
const equivalent = discover({ ...base_input(), evidence_path: offline.evidence_path });
if (sprintf("%J", draft_result.policy) != sprintf("%J", equivalent.policy)) {
	print("offline_draft_policy_diverged\n");
	exit(1);
}


const model = use("configuration.onboarding-model");
const original = discover(one_provider).policy;
original.providers.business = original.providers.beta;
delete original.providers.beta;
original.provider_regions.business = original.provider_regions.beta;
delete original.provider_regions.beta;
original.private_extension = { preserved: true };
const before = sprintf("%J", original);
const merged = model.merge_provider(original, result, "alpha");
assert(merged.recognized && merged.policy.providers.business.section == "beta" && merged.policy.providers.alpha.section == "alpha");
assert(merged.policy.private_extension.preserved && sprintf("%J", original) == before);
const same = model.merge_provider(merged.policy, result, "beta");
assert(same.recognized && same.policy.providers.beta == null && length(keys(same.policy.providers)) == 2);
const removed = model.reconcile_sources(same.policy, { beta: { enabled: true }, base: { enabled: true } });
assert(removed.ok && removed.policy.providers.business.enabled && removed.policy.providers.alpha == null);
assert(removed.policy.provider_regions.alpha == null && removed.policy.private_extension.preserved);
assert(!model.reconcile_sources(same.policy, { beta: { enabled: false }, base: { enabled: true } }).ok);
const referenced = { ...original, recovery_profile: { ref: "subscription:alpha" } };
assert(model.reconcile_sources(referenced, { beta: { enabled: true } }).error == "subscription_referenced_by_profile");
assert(sprintf("%J", original) == before);
const unknown = model.merge_provider(original, unknown_result, "alpha");
assert(!unknown.recognized && sprintf("%J", unknown.policy) == before);

const builtin_profile = json(fs.readfile(replace(sourcepath(), /[^/]+$/, "../openwrt/files/etc/opl-netfleet/policy-sources/base-v1.json")));
const builtin = model.draft_builtin(base_input(), builtin_profile);
assert(builtin.ready && builtin.policy.policy_source.ref == "bundle:base-v1");
assert(builtin.policy.bindings["AI 出口"].capability == "ai-compatible");
assert(builtin.policy.capabilities["ai-compatible"].excluded_regions[0] == "hong_kong");
assert(use("models.policy").validate(builtin.policy).ok);
const builtin_one = model.draft_builtin(one_provider, builtin_profile);
assert(builtin_one.ready && use("models.policy").validate(builtin_one.policy).ok);
assert(model.draft(base_input()).policy.policy_source.kind == "profile");
const switched = model.use_builtin(original, builtin_profile);
assert(switched.private_extension.preserved && sprintf("%J", original) == before);

print("onboarding_contract_ok\n");

release_services();
