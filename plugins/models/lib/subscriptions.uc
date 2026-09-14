

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let valid_id, quota_reset_day, safe_text, valid_url, desired_source, userinfo, referenced, source_identity_input, public_source;



valid_id = function(id) {
	return type(id) == "string" && match(id, /^[A-Za-z0-9_]+$/) != null;
};

quota_reset_day = function(value) {
	if (type(value) == "string" && match(value, /^([1-9]|[12][0-9]|3[01])$/)) return int(value);
	return type(value) == "int" && value >= 1 && value <= 31 ? value : null;
};

safe_text = function(value) {
	if (type(value) != "string") return false;
	for (let i = 0; i < length(value); i++) {
		const byte = ord(substr(value, i, 1));
		if (byte < 32 || byte == 127) return false;
	}
	return true;
};

valid_url = function(value) {
	return safe_text(value) && length(value) <= 8192 &&
		match(value, /^https?:\/\/[^\/[:space:]?#@]+([\/?][^[:space:]#]*)?$/) != null;
};

desired_source = function(envelope, previous) {
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
userinfo = function(headers) {
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

referenced = function(policy, id) {
	for (let key, provider in policy?.providers ?? {}) {
		if (provider?.section == id) return true;
	}
	return policy?.policy_source?.ref == `subscription:${id}` ||
		policy?.recovery_profile?.ref == `subscription:${id}`;
};

source_identity_input = function(source) {
	return { url: source?.url ?? "", user_agent: source?.user_agent || "clash.meta", info_url: source?.info_url ?? "" };
};

public_source = function(source, cache) {
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

// Both platform adapters supply numeric evidence; absent counters remain unknown.
function quota_state(input) {
	const result = { state: "unknown" };
	if (input?.expires_at != null) result.expires_at = input.expires_at;
	const reset = quota_reset_day(input?.reset_day);
	if (reset != null) { result.reset_day = reset; result.reset_day_source = "manual"; }
	const remaining = input?.available ??
		(input?.total != null && input?.used != null ? input.total - input.used : null);
	if (remaining != null) {
		result.state = remaining > 0 ? "available" : "exhausted";
		if (remaining > 0) result.remaining_bytes = remaining;
	}
	return result;
}
function normalize_sources(values, previous, imported) {
	if (type(values) != "object" || length(keys(values)) > 100) return { ok: false, error: "invalid_subscriptions" };
	const result = {};
	for (let id, value in values) {
		if (!valid_id(id) || length(id) > 64 || type(value) != "object") return { ok: false, error: "invalid_subscription" };
		const old = previous?.[id];
		const url = value.url ?? old?.url;
		const name = value.name ?? old?.name ?? id;
		if (!url && (old?.imported == true || imported?.[id] == true)) {
			if (!safe_text(name) || !length(trim(name)) || length(name) > 128) return { ok: false, error: "invalid_subscription_name" };
			result[id] = { name, enabled: value.enabled != false, imported: true };
			continue;
		}
		const desired = desired_source({ revision: "candidate", source: { id, name, url,
			user_agent: value.user_agent ?? old?.user_agent ?? "clash.meta" } }, old);
		if (!desired.ok) return desired;
		result[id] = { name: desired.source.name, url: desired.source.url,
			user_agent: desired.source.user_agent, enabled: value.enabled != false, imported: false };
	}
	return { ok: true, sources: result };
}
return { valid_id, quota_reset_day, valid_url, desired_source, userinfo, referenced, source_identity_input, public_source, quota_state, normalize_sources };
};
