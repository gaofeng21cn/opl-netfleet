export function identifier(value) {
	return type(value) == "string" && match(value, /^[A-Za-z][A-Za-z0-9_-]{0,47}$/) != null;
};

export function counter(value) {
	return type(value) == "int" && value >= 0 && value <= 9007199254740991;
};

export function default_site_name(hostname) {
	if (type(hostname) != "string") return "OpenWrt";
	const cleaned = replace(trim(hostname), /[[:cntrl:]]/, "");
	return length(cleaned) > 0 && length(cleaned) <= 120 ? cleaned : "OpenWrt";
};

export function project(site, applied, status, totals, previous, now, digest, event) {
	const mode = status.operating_mode;
	const traffic = {};
	const elapsed = now - (previous?.at ?? now);
	for (let direction in ["upload", "download"]) {
		const field = direction + "_bytes", value = totals?.[field], old = previous?.[field];
		if (!counter(value)) continue;
		traffic[field] = value;
		if (counter(old) && value >= old && elapsed > 0 && elapsed <= 180)
			traffic[direction + "_bps"] = int((value - old) * 8 / elapsed);
	}
	const capabilities = [];
	for (let item in status.capabilities ?? []) {
		if (length(capabilities) == 32) break;
		if (item.enabled != true || !identifier(item.id)) continue;
		const entry = { id: item.id };
		if (identifier(item.region_id)) entry.region = item.region_id;
		if (identifier(item.provider_id)) entry.provider = item.provider_id;
		if (type(item.leaf) == "string" && length(item.leaf)) {
			const hashed = digest(item.leaf);
			if (type(hashed) == "string" && match(hashed, /^[a-f0-9]{64}$/))
				entry.node = "node-" + substr(hashed, 0, 12);
		}
		const reason = item.reason;
		if (reason?.kind == "automatic_decision" && item.selected_group != null &&
			item.selected_group == item.preferred_group && item.leaf != null && item.leaf == item.preferred_leaf &&
			counter(reason.delay_ms) && reason.delay_ms <= 600000) entry.rtt_ms = reason.delay_ms;
		push(capabilities, entry);
	}
	const quotas = [];
	for (let item in status.providers ?? []) {
		if (length(quotas) == 32) break;
		if (!identifier(item.id)) continue;
		const quota = { provider: item.id };
		if (counter(item.quota?.remaining_bytes)) quota.remaining_bytes = item.quota.remaining_bytes;
		if (counter(item.quota?.total_bytes)) quota.total_bytes = item.quota.total_bytes;
		if (length(keys(quota)) > 1) push(quotas, quota);
	}
	const body = { site_id: site, applied_revision: applied,
		mode: index(["netfleet", "mihomo", "openwrt"], mode) >= 0 ? mode : "unknown",
		capabilities: capabilities, traffic: traffic, quotas: quotas, recovery: status.recovery != null };
	if (index(["updated", "unchanged", "failed", "recovering", "restored"], event) >= 0) body.event = event;
	return body;
};

export function selected_sources(result, revision, sections, auto_sections) {
	if (result?.revision != revision || type(result.subscriptions) != "array" ||
		!length(result.subscriptions) || length(result.subscriptions) > 16) return null;
	const sources = [], mapped = {};
	for (let item in result.subscriptions) {
		if (type(item?.id) != "string" || !match(item.id, /^[a-z][a-z0-9_-]{1,47}$/)) return null;
		let id = type(sections) == "object" ? sections[item.id] : null;
		if (id == null && auto_sections == true) {
			id = replace(item.id, /-/g, "_");
		}
		const url = item.url;
		if (type(id) != "string" || !match(id, /^[A-Za-z0-9_]+$/) || exists(mapped, id) ||
			type(item.name) != "string" || !length(trim(item.name)) || length(item.name) > 120 ||
			match(item.name, /[[:cntrl:]]/) || type(url) != "string" || length(url) > 2048 ||
			!match(url, /^https:\/\/[^\/[:space:]?#@\\]+([\/?][^[:space:]#\\]*)?$/) ||
			match(url, /[[:cntrl:]]/)) return null;
		mapped[id] = true;
		push(sources, { id: id, name: item.name, url: url });
	}
	return sources;
};
