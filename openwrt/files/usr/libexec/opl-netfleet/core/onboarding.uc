const REGION_CATALOG = [
	{ id: "hong_kong", code: "HK", display_name: "香港", display_order: 10,
		names: ["香港", "hong kong", "🇭🇰"], filter: "(?i)(香港|Hong[ _-]?Kong|\\bHK\\b|🇭🇰)" },
	{ id: "taiwan", code: "TW", display_name: "台湾", display_order: 20,
		names: ["台湾", "taiwan", "taipei", "🇹🇼"], filter: "(?i)(台湾|Taiwan|Taipei|\\bTW\\b|🇹🇼)" },
	{ id: "singapore", code: "SG", display_name: "新加坡", display_order: 30,
		names: ["新加坡", "singapore", "狮城", "🇸🇬"], filter: "(?i)(新加坡|狮城|Singapore|\\bSG\\b|🇸🇬)" },
	{ id: "japan", code: "JP", display_name: "日本", display_order: 40,
		names: ["日本", "japan", "tokyo", "osaka", "🇯🇵"], filter: "(?i)(日本|Japan|Tokyo|Osaka|\\bJP\\b|🇯🇵)" },
	{ id: "south_korea", code: "KR", display_name: "韩国", display_order: 50,
		names: ["韩国", "韓國", "south korea", "korea", "seoul", "🇰🇷"], filter: "(?i)(韩国|韓國|South[ _-]?Korea|Korea|Seoul|\\bKR\\b|🇰🇷)" },
	{ id: "united_states", code: "US", display_name: "美国", display_order: 60,
		names: ["美国", "美國", "united states", "america", "los angeles", "san jose", "seattle", "dallas", "new york", "🇺🇸"], filter: "(?i)(美国|美國|United[ _-]?States|America|Los[ _-]?Angeles|San[ _-]?Jose|Seattle|Dallas|New[ _-]?York|\\bUS\\b|\\bUSA\\b|🇺🇸)" },
	{ id: "germany", code: "DE", display_name: "德国", display_order: 70,
		names: ["德国", "德國", "germany", "frankfurt", "🇩🇪"], filter: "(?i)(德国|德國|Germany|Frankfurt|\\bDE\\b|🇩🇪)" },
	{ id: "france", code: "FR", display_name: "法国", display_order: 80,
		names: ["法国", "法國", "france", "paris", "🇫🇷"], filter: "(?i)(法国|法國|France|Paris|\\bFR\\b|🇫🇷)" },
	{ id: "netherlands", code: "NL", display_name: "荷兰", display_order: 90,
		names: ["荷兰", "荷蘭", "netherlands", "amsterdam", "🇳🇱"], filter: "(?i)(荷兰|荷蘭|Netherlands|Amsterdam|\\bNL\\b|🇳🇱)" },
	{ id: "united_kingdom", code: "GB", display_name: "英国", display_order: 100,
		names: ["英国", "英國", "united kingdom", "london", "🇬🇧"], codes: ["gb", "uk"], filter: "(?i)(英国|英國|United[ _-]?Kingdom|London|\\bGB\\b|\\bUK\\b|🇬🇧)" },
	{ id: "canada", code: "CA", display_name: "加拿大", display_order: 110,
		names: ["加拿大", "canada", "toronto", "vancouver", "🇨🇦"], filter: "(?i)(加拿大|Canada|Toronto|Vancouver|\\bCA\\b|🇨🇦)" },
	{ id: "australia", code: "AU", display_name: "澳大利亚", display_order: 120,
		names: ["澳大利亚", "澳大利亞", "澳洲", "australia", "sydney", "🇦🇺"], filter: "(?i)(澳大利亚|澳大利亞|澳洲|Australia|Sydney|\\bAU\\b|🇦🇺)" },
	{ id: "india", code: "IN", display_name: "印度", display_order: 130,
		names: ["印度", "india", "mumbai", "🇮🇳"], filter: "(?i)(印度|India|Mumbai|\\bIN\\b|🇮🇳)" },
	{ id: "vietnam", code: "VN", display_name: "越南", display_order: 140,
		names: ["越南", "vietnam", "hanoi", "🇻🇳"], filter: "(?i)(越南|Vietnam|Hanoi|\\bVN\\b|🇻🇳)" },
	{ id: "thailand", code: "TH", display_name: "泰国", display_order: 150,
		names: ["泰国", "泰國", "thailand", "bangkok", "🇹🇭"], filter: "(?i)(泰国|泰國|Thailand|Bangkok|\\bTH\\b|🇹🇭)" },
	{ id: "malaysia", code: "MY", display_name: "马来西亚", display_order: 160,
		names: ["马来西亚", "馬來西亞", "malaysia", "kuala lumpur", "🇲🇾"], filter: "(?i)(马来西亚|馬來西亞|Malaysia|Kuala[ _-]?Lumpur|\\bMY\\b|🇲🇾)" },
	{ id: "indonesia", code: "ID", display_name: "印度尼西亚", display_order: 170,
		names: ["印度尼西亚", "印度尼西亞", "印尼", "indonesia", "jakarta", "🇮🇩"], filter: "(?i)(印度尼西亚|印度尼西亞|印尼|Indonesia|Jakarta|\\bID\\b|🇮🇩)" },
	{ id: "philippines", code: "PH", display_name: "菲律宾", display_order: 180,
		names: ["菲律宾", "菲律賓", "philippines", "manila", "🇵🇭"], filter: "(?i)(菲律宾|菲律賓|Philippines|Manila|\\bPH\\b|🇵🇭)" }
];

function clone(value) {
	return json(sprintf("%J", value));
};

function push_unique(values, value) {
	if (index(values, value) < 0) push(values, value);
};

function normalized_ascii(value) {
	return ` ${replace(lc(`${value ?? ""}`), /[^a-z0-9]+/g, " ")} `;
};

function region_matches(name, region) {
	const lower = lc(`${name ?? ""}`);
	for (let i = 0; i < length(region.names ?? []); i++) {
		if (index(lower, lc(region.names[i])) >= 0) return true;
	}
	const normalized = normalized_ascii(name);
	const codes = region.codes ?? [lc(region.code)];
	for (let i = 0; i < length(codes); i++) {
		if (index(normalized, ` ${lc(codes[i])} `) >= 0) return true;
	}
	return false;
};

function profile_group(profile, name) {
	const groups = profile?.["proxy-groups"] ?? [];
	for (let i = 0; i < length(groups); i++) {
		if (groups[i]?.name == name && type(groups[i]?.proxies) == "array" && length(groups[i].proxies) > 0)
			return groups[i];
	}
	return null;
};

function match_entry_group(profile) {
	const rules = profile?.rules ?? [];
	for (let i = length(rules) - 1; i >= 0; i--) {
		if (type(rules[i]) != "string") continue;
		const parts = split(rules[i], ",");
		if (lc(trim(parts[0] ?? "")) != "match" || length(parts) < 2) continue;
		const target = trim(parts[1]);
		if (profile_group(profile, target) != null) return { name: target, source: "match_rule" };
	}
	const candidates = ["节点选择", "代理", "Proxy", "PROXY"];
	const matched = [];
	for (let i = 0; i < length(candidates); i++) {
		if (profile_group(profile, candidates[i]) != null) push_unique(matched, candidates[i]);
	}
	return length(matched) == 1 ? { name: matched[0], source: "known_name" } : null;
};

function provider_regions(profile) {
	const matched = {};
	const proxies = profile?.proxies ?? [];
	for (let i = 0; i < length(proxies); i++) {
		const name = proxies[i]?.name;
		if (type(name) != "string" || length(name) == 0) continue;
		for (let j = 0; j < length(REGION_CATALOG); j++) {
			if (region_matches(name, REGION_CATALOG[j])) matched[REGION_CATALOG[j].id] = true;
		}
	}
	const result = [];
	for (let i = 0; i < length(REGION_CATALOG); i++) {
		if (matched[REGION_CATALOG[i].id] == true) push(result, REGION_CATALOG[i]);
	}
	return result;
};

function stable_subscriptions(values) {
	const result = clone(values ?? []);
	for (let i = 1; i < length(result); i++) {
		for (let j = i; j > 0 && result[j].section < result[j - 1].section; j--) {
			const previous = result[j - 1];
			result[j - 1] = result[j];
			result[j] = previous;
		}
	}
	return result;
};

function add_blocker(blockers, code, detail) {
	push(blockers, { code: code, detail: detail ?? null });
};

export function discover(input) {
	const blockers = [];
	const warnings = [];
	const profile = input?.current_profile_object;
	const profile_ref = input?.current_profile;
	if (type(profile_ref) != "string" ||
		(index(profile_ref, "subscription:") != 0 && index(profile_ref, "file:") != 0))
		add_blocker(blockers, "current_profile_missing", null);
	else if (profile_ref == "file:OPL-NetFleet.json")
		add_blocker(blockers, "netfleet_profile_already_selected", null);
	if (type(profile) != "object") add_blocker(blockers, "current_profile_unreadable", null);
	if (input?.nikki_enabled != true) add_blocker(blockers, "nikki_disabled", null);
	if (input?.mihomo_running != true || input?.runtime_valid != true)
		add_blocker(blockers, "nikki_runtime_unhealthy", null);
	if (input?.controller_ready != true) add_blocker(blockers, "mihomo_controller_unavailable", null);
	if (input?.generated_artifacts_present == true)
		add_blocker(blockers, "existing_generated_artifacts", null);

	const entry = type(profile) == "object" ? match_entry_group(profile) : null;
	if (type(profile) == "object" && entry == null) add_blocker(blockers, "entry_group_unresolved", null);

	const subscriptions = stable_subscriptions(input?.subscriptions);
	const providers = {};
	const mappings = {};
	const regions_seen = {};
	const provider_preview = [];
	let valid_cache_count = 0;
	for (let i = 0; i < length(subscriptions); i++) {
		const subscription = subscriptions[i];
		if (type(subscription?.profile) != "object" || type(subscription?.digest) != "string") continue;
		valid_cache_count++;
		const found = provider_regions(subscription.profile);
		if (length(found) == 0) {
			push(warnings, { code: "subscription_has_no_known_region", detail: subscription.display_name });
			continue;
		}
		providers[subscription.section] = {
			section: subscription.section,
			enabled: true,
			role: "primary",
			billing: "subscription",
			quota: { available_field: "avaliable", total_field: "total", used_field: "used" }
		};
		mappings[subscription.section] = [];
		const region_ids = [];
		for (let j = 0; j < length(found); j++) {
			const region = found[j];
			regions_seen[region.id] = region;
			push(region_ids, region.id);
			push(mappings[subscription.section], { region: region.id, filter: region.filter });
		}
		push(provider_preview, {
			id: subscription.section,
			display_name: subscription.display_name,
			region_ids: region_ids
		});
	}
	if (valid_cache_count == 0) add_blocker(blockers, "subscription_cache_missing", null);
	else if (length(keys(providers)) == 0) add_blocker(blockers, "recognized_region_missing", null);

	const regions = {};
	const region_preview = [];
	for (let i = 0; i < length(REGION_CATALOG); i++) {
		const catalog = REGION_CATALOG[i];
		if (regions_seen[catalog.id] == null) continue;
		regions[catalog.id] = {
			flag: catalog.code,
			display_name: catalog.display_name,
			display_order: catalog.display_order,
			mode: "automatic"
		};
		push(region_preview, { id: catalog.id, display_name: `${catalog.code} ${catalog.display_name}` });
	}

	const bindings = {};
	if (entry != null) bindings[entry.name] = { capability: "standard", kind: "entry" };
	const policy = length(blockers) == 0 ? {
		schema_version: 2,
		main: { target: input.target, enabled: true },
		policy_source: { kind: "profile", ref: profile_ref },
		recovery_profile: { ref: profile_ref },
		bindings: bindings,
		providers: providers,
		regions: regions,
		provider_regions: mappings,
		capabilities: {
			standard: { display_name: entry.name, display_order: 10, enabled: true, mode: "automatic" }
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
			latency: { method: "mihomo_delay", url: "https://www.gstatic.com/generate_204", timeout_ms: 2000, expected_status: 204 },
			quota: { source: "nikki_subscription_metadata", zero_is_exhausted: true }
		},
		evidence: { path: "/etc/opl-netfleet/evidence.json" },
		fail_open: {
			healthcheck: { path_probe_id: "default-egress", guard_probe_id: "default-egress", timeout_ms: 5000, interval_seconds: 300, max_failed_times: 2 },
			probes: [{ id: "default-egress", url: "https://www.gstatic.com/generate_204", expected_status: 204 }]
		}
	} : null;

	return {
		ready: length(blockers) == 0,
		blockers: blockers,
		warnings: warnings,
		policy: policy,
		preview: {
			recovery_profile_display_name: input?.current_profile_display_name ?? "当前原生配置",
			entry_group: entry?.name ?? null,
			entry_group_source: entry?.source ?? null,
			providers: provider_preview,
			regions: region_preview
		},
		revision_input: {
			profile_ref: profile_ref,
			profile_digest: input?.current_profile_digest ?? null,
			subscriptions: map(subscriptions, entry => ({ section: entry.section, display_name: entry.display_name, digest: entry.digest })),
			policy: policy
		}
	};
};
