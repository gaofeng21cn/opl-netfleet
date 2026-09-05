export function valid_id(id) {
	return type(id) == "string" && match(id, /^[a-z][a-z0-9_-]{0,63}$/) != null;
};

export function validate(config) {
	if (type(config) != "object" || config.schema_version != 1 || type(config.sources) != "array")
		return { ok: false, error: "invalid_source_config" };
	for (let key in config) {
		if (key != "schema_version" && key != "sources")
			return { ok: false, error: "unknown_config_field" };
	}
	const seen = {};
	for (let i = 0; i < length(config.sources); i++) {
		const source = config.sources[i];
		let error = null;
		if (type(source) != "object" || !valid_id(source.id)) error = "invalid_source_id";
		else if (seen[source.id]) error = "duplicate_source_id";
		else if (type(source.enabled) != "bool") error = "invalid_enabled";
		else if (type(source.display_name) != "string" || length(trim(source.display_name)) == 0 ||
			match(source.display_name, /[\x00-\x1f\x7f]/)) error = "invalid_display_name";
		else if (type(source.url) != "string" ||
			!match(source.url, /^https:\/\/[^\/\s?#@]+(?:\/[^\s#]*)?$/) ||
			match(source.url, /[\x00-\x20\x7f]/)) error = "https_url_required";
		else if (source.user_agent != null && (type(source.user_agent) != "string" ||
			match(source.user_agent, /[\x00-\x1f\x7f]/))) error = "invalid_user_agent";
		if (error == null) {
			for (let key in source) {
				if (index(["id", "display_name", "enabled", "url", "user_agent"], key) < 0)
					error = "unknown_source_field";
			}
		}
		if (error != null) return { ok: false, error: error, source_index: i };
		seen[source.id] = true;
	}
	return { ok: true };
};

export function project(source, fingerprint, cache) {
	const accepted = cache?.source_sha256 == fingerprint && type(cache?.proxies) == "array" &&
		length(cache.proxies) > 0 && type(cache?.content_sha256) == "string";
	const attempt = cache?.attempt?.source_sha256 == fingerprint ? cache.attempt : null;
	return {
		id: source.id,
		display_name: source.display_name,
		enabled: source.enabled,
		ready: source.enabled && accepted,
		cache_present: accepted,
		previous_cache_retained: !accepted && length(cache?.proxies ?? []) > 0,
		node_count: accepted ? length(cache.proxies) : null,
		cache_sha256: accepted ? cache.content_sha256 : null,
		last_attempt: attempt?.at ?? null,
		last_success: accepted ? cache.last_success : null,
		last_changed: accepted ? cache.last_changed : null,
		last_result: attempt?.result ?? (cache == null ? "not_fetched" : "source_changed"),
		error: attempt?.error ?? null
	};
};
