#!/usr/bin/ucode

import { discover } from "../openwrt/files/usr/libexec/opl-netfleet/core/onboarding.uc";

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

print("onboarding_contract_ok\n");
