export function valid_id(id) {
	return type(id) == "string" && match(id, /^[A-Za-z0-9_]+$/) != null;
};

export function quota_reset_day(value) {
	if (type(value) == "string" && match(value, /^([1-9]|[12][0-9]|3[01])$/)) return int(value);
	return type(value) == "int" && value >= 1 && value <= 31 ? value : null;
};

function safe_text(value) {
	if (type(value) != "string") return false;
	for (let i = 0; i < length(value); i++) {
		const byte = ord(substr(value, i, 1));
		if (byte < 32 || byte == 127) return false;
	}
	return true;
};

export function valid_url(value) {
	return safe_text(value) && length(value) <= 8192 &&
		match(value, /^https?:\/\/[^\/[:space:]?#@]+([\/?][^[:space:]#]*)?$/) != null;
};

export function desired_source(envelope, previous) {
	if (type(envelope) != "object" || type(envelope.revision) != "string" ||
		type(envelope.source) != "object" || !valid_id(envelope.source.id))
		return { ok: false, error: "invalid_subscription_input" };
	for (let key in envelope) {
		if (index(["revision", "source", "delete"], key) < 0)
			return { ok: false, error: "unknown_subscription_field" };
	}
	for (let key in envelope.source) {
		if (index(["id", "name", "url", "user_agent", "info_url", "prefer", "quota_reset_day"], key) < 0)
			return { ok: false, error: "unknown_source_field" };
	}
	if (envelope.delete != null && type(envelope.delete) != "bool")
		return { ok: false, error: "invalid_delete" };
	if (envelope.delete == true) return { ok: true, deleted: true, id: envelope.source.id };
	const source = {};
	if (exists(envelope.source, "quota_reset_day") && envelope.source.quota_reset_day != null &&
		(type(envelope.source.quota_reset_day) != "int" || quota_reset_day(envelope.source.quota_reset_day) == null))
		return { ok: false, error: "invalid_quota_reset_day" };
	source.quota_reset_day = exists(envelope.source, "quota_reset_day") ? envelope.source.quota_reset_day : quota_reset_day(previous?.quota_reset_day);
	for (let key in ["name", "url", "user_agent", "info_url", "prefer"])
		source[key] = envelope.source[key] ?? previous?.[key] ?? "";
	source.id = envelope.source.id;
	if (source.url == "") source.url = previous?.url ?? "";
	if (source.user_agent == "") source.user_agent = "clash.meta";
	if (source.prefer == "") source.prefer = "remote";
	if (!safe_text(source.name) || length(trim(source.name)) == 0 || length(source.name) > 128)
		return { ok: false, error: "invalid_subscription_name" };
	if (!valid_url(source.url) || (source.info_url != "" && !valid_url(source.info_url)))
		return { ok: false, error: "invalid_subscription_url" };
	if (!safe_text(source.user_agent) || length(source.user_agent) > 512)
		return { ok: false, error: "invalid_user_agent" };
	if (index(["remote", "local"], source.prefer) < 0)
		return { ok: false, error: "invalid_subscription_preference" };
	return { ok: true, source: source, source_changed: previous != null &&
		(source.url != previous.url || source.user_agent != (previous.user_agent || "clash.meta") ||
			source.info_url != (previous.info_url ?? "")) };
};

// Subscription-Userinfo is the same wire contract consumed by Nikki.
// Redirect and interim response metadata must not replace the final response.
export function userinfo(headers) {
	let value = null;
	for (let line in split(headers ?? "", "\n")) {
		line = trim(line);
		if (match(line, /^HTTP\/[0-9.]+ [0-9]{3}/)) value = null;
		const field = match(line, /^([A-Za-z-]+):[ \t]*(.*)$/);
		if (field != null && lc(field[1]) == "subscription-userinfo") value = field[2];
	}
	if (value == null) return null;
	const result = {};
	for (let field in split(value, ";")) {
		const pair = match(trim(field), /^(upload|download|total|expire)=([0-9]+)$/);
		if (pair != null && length(pair[2]) <= 18) result[pair[1]] = int(pair[2]);
	}
	if (length(keys(result)) == 0) return null;
	if (result.upload != null && result.download != null) {
		result.used = result.upload + result.download;
		if (result.total != null) result.avaliable = result.total - result.used;
	}
	return result;
};

export function referenced(policy, id) {
	for (let key, provider in policy?.providers ?? {}) {
		if (provider?.section == id) return true;
	}
	return policy?.policy_source?.ref == `subscription:${id}` ||
		policy?.recovery_profile?.ref == `subscription:${id}`;
};

export function source_identity_input(source) {
	return { url: source?.url ?? "", user_agent: source?.user_agent || "clash.meta", info_url: source?.info_url ?? "" };
};

export function public_source(source, cache) {
	const current = cache?.present == true && cache.current != false;
	return {
		id: source[".name"] ?? source.id,
		name: source.name,
		has_url: length(source.url ?? "") > 0,
		has_info_url: length(source.info_url ?? "") > 0,
		prefer: source.prefer ?? "remote",
		quota_reset_day: quota_reset_day(source.quota_reset_day),
		cache_present: cache?.present == true,
		cache_current: current,
		pending_update: !current,
		using_previous_cache: cache?.present == true && !current,
		cache_sha256: cache?.digest ?? null,
		node_count: cache?.node_count ?? null,
		last_attempt: int(source.last_attempt ?? 0) || null,
		last_success: int(source.last_success ?? 0) || null,
		last_result: source.last_result ?? null,
		error: source.last_error ?? null,
		quota: { upload: source.upload ?? null, download: source.download ?? null,
			total: source.total ?? null, used: source.used ?? null,
			available: source.avaliable ?? null, expire: source.expire ?? null }
	};
};
