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

export function catalog() {
	return clone(REGION_CATALOG);
};

export function discover(profile) {
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
		if (matched[REGION_CATALOG[i].id] == true) push(result, clone(REGION_CATALOG[i]));
	}
	return result;
};
