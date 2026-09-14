return function(context) {
// Bind the service functions before assigning closures that may reference them.
let is_control_proxy, is_proxy_leaf, is_provider_proxy_leaf, provider_group_leaf_with_health, provider_group_current_leaf, provider_group_leaf, control_proxy_type, provider_source_summary, provider_round_summary;

const CONTROL_PROXY_TYPES = {
	direct: true,
	reject: true,
	compatible: true,
	global: true,
	pass: true,
	block: true
};


is_control_proxy = function(proxy_state, value) {
	return CONTROL_PROXY_TYPES[lc(`${proxy_state?.[value]?.type ?? ""}`)] == true;
};

is_proxy_leaf = function(proxy_state, value) {
	if (type(value) != "string" || length(trim(value)) == 0) {
		return false;
	}
	const state = proxy_state?.[value];
	if (state == null || type(state) != "object") {
		return false;
	}
	const proxy_type = lc(`${state.type ?? ""}`);
	return CONTROL_PROXY_TYPES[proxy_type] != true &&
		type(state.all) != "array" && type(state.now) != "string";
};

is_provider_proxy_leaf = function(provider_state, source_name, value, require_alive, url) {
	if (type(source_name) != "string" || length(trim(source_name)) == 0 ||
		type(value) != "string" || length(trim(value)) == 0) {
		return false;
	}
	const nodes = provider_state?.[source_name]?.proxies;
	if (type(nodes) != "array") {
		return false;
	}
	let matched = null;
	for (let i = 0; i < length(nodes); i++) {
		if (nodes[i]?.name != value) {
			continue;
		}
		if (matched != null) {
			return false;
		}
		matched = nodes[i];
	}
	const proxy_type = lc(`${matched?.type ?? ""}`);
	return matched != null && (require_alive != true || matched.extra?.[url]?.alive == true) && length(proxy_type) > 0 &&
		CONTROL_PROXY_TYPES[proxy_type] != true;
};

function history_time(health) {
	const history = health?.history;
	const last = type(history) == 'array' && length(history) ? history[length(history) - 1] : null;
	const parts = match(last?.time ?? '', /^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.([0-9]{1,9}))?Z$/);
	return parts == null ? null : `${parts[1]}.${substr((parts[3] ?? '') + '000000000', 0, 9)}Z`;
};

function newer_group_success(group, leaf) {
	const group_time = history_time(group), leaf_time = history_time(leaf);
	const last = group?.history?.[length(group?.history ?? []) - 1];
	return group?.alive == true && leaf?.alive == false && group_time != null && leaf_time != null &&
		group_time > leaf_time && type(last?.delay) == 'int' && last.delay >= 0;
};

function provider_group_measurement_reason(proxy_state, provider_state, source_name, group, url) {
	const state = proxy_state?.[group];
	if (state == null) return "group_unavailable";
	if (type(state.all) != "array") return "group_members_unavailable";
	if (type(state.now) != "string" || index(state.all, state.now) < 0)
		return "selected_leaf_unavailable";
	if (is_control_proxy(proxy_state, state.now)) return "no_proxy_leaf";
	const nodes = provider_state?.[source_name]?.proxies;
	if (type(nodes) != "array") return "provider_nodes_unavailable";
	const matches = filter(nodes, node => node.name == state.now);
	if (length(matches) == 0) return "leaf_not_in_provider";
	if (length(matches) > 1) return "leaf_identity_ambiguous";
	const leaf = matches[0];
	if (length(`${leaf.type ?? ""}`) == 0) return "leaf_type_unavailable";
	if (CONTROL_PROXY_TYPES[lc(leaf.type)] == true) return "no_proxy_leaf";
	if (state.extra?.[url]?.alive == false) return "group_latency_failed";
	if (state.extra?.[url]?.alive != true) return "group_latency_unrecorded";
	// Provider-wide health checks can precede a successful candidate URLTest.
	// An older leaf failure must not veto the newer same-target group result.
	if (leaf.extra?.[url]?.alive == false)
		return newer_group_success(state.extra[url], leaf.extra[url]) ? null : "leaf_latency_failed";
	if (leaf.extra?.[url]?.alive != true) return "leaf_latency_unrecorded";
	return null;
};

provider_group_leaf_with_health = function(proxy_state, provider_state, source_name, group, require_alive, url) {
	const group_state = proxy_state?.[group];
	const leaf = group_state?.now ?? null;
	if (require_alive)
		return provider_group_measurement_reason(proxy_state, provider_state, source_name, group, url) == null ? leaf : null;
	return (require_alive ? group_state?.extra?.[url]?.alive == true : group_state?.alive == true) && type(group_state?.all) == "array" &&
		index(group_state.all, leaf) >= 0 &&
		is_provider_proxy_leaf(provider_state, source_name, leaf, require_alive, url) ? leaf : null;
};

provider_group_current_leaf = function(proxy_state, provider_state, source_name, group) {
	return provider_group_leaf_with_health(proxy_state, provider_state, source_name, group, false);
};

provider_group_leaf = function(proxy_state, provider_state, source_name, group, url) {
	return provider_group_leaf_with_health(proxy_state, provider_state, source_name, group, true, url);
};

control_proxy_type = function(value) {
	return CONTROL_PROXY_TYPES[lc(`${value ?? ""}`)] == true;
};

provider_source_summary = function(provider_state, source_name) {
	if (type(source_name) != "string" || length(trim(source_name)) == 0 ||
		provider_state?.[source_name] == null) {
		return { reason: "source_not_loaded", node_count: 0, alive_count: 0 };
	}
	const nodes = provider_state[source_name]?.proxies;
	if (type(nodes) != "array") {
		return { reason: "source_not_loaded", node_count: 0, alive_count: 0 };
	}
	let node_count = 0;
	let alive_count = 0;
	for (let i = 0; i < length(nodes); i++) {
		const proxy_type = lc(`${nodes[i]?.type ?? ""}`);
		if (control_proxy_type(proxy_type) || type(nodes[i]?.name) != "string" ||
			length(trim(nodes[i].name)) == 0) {
			continue;
		}
		node_count++;
		if (nodes[i]?.alive == true && length(proxy_type) > 0) {
			alive_count++;
		}
	}
	return {
		reason: node_count == 0 ? "zero_nodes" : alive_count == 0 ? "zero_alive_nodes" : "ready",
		node_count: node_count,
		alive_count: alive_count
	};
};

provider_round_summary = function(entry, proxy_state, provider_state, url) {
	const sources = [];
	const groups = [];
	if (provider_state == null || type(provider_state) != "object") {
		return {
			reason: "provider_state_unavailable",
			sources: sources,
			groups: groups
		};
	}
	const providers = entry?.providers ?? {};
	const provider_ids = keys(providers);
	for (let i = 0; i < length(provider_ids) && i < 64; i++) {
		const provider_id = provider_ids[i];
		const counts = provider_source_summary(provider_state, providers[provider_id]?.source_name);
		push(sources, {
			provider_id: provider_id,
			reason: counts.reason,
			node_count: counts.node_count,
			alive_count: counts.alive_count
		});
	}
	const candidate_groups = entry?.candidate_groups ?? [];
	for (let i = 0; i < length(candidate_groups) && i < 64; i++) {
		const group = candidate_groups[i];
		const source_name = entry?.providers?.[group?.provider]?.source_name;
		const leaf = provider_group_leaf(proxy_state, provider_state, source_name, group?.name, url);
		const group_state = proxy_state?.[group?.name];
		const now_type = lc(`${proxy_state?.[group_state?.now]?.type ?? ""}`);
		let reason = "ready";
		if (leaf == null) {
			reason = control_proxy_type(now_type) ? "control_fallback" : "no_verified_leaf";
		}
		push(groups, {
			provider_id: group?.provider ?? null,
			region_id: group?.region ?? null,
			reason: reason,
			member_count: type(group_state?.all) == "array" ? length(group_state.all) : 0
		});
	}
	return {
		reason: null,
		sources: sources,
		groups: groups
	};
};

return { provider_group_measurement_reason, is_control_proxy, is_proxy_leaf, provider_group_current_leaf, provider_group_leaf, provider_round_summary };
};
