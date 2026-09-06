function copy(value) { return json(sprintf("%J", value)); };
function array(value) { return type(value) == "array" ? value : value == null ? [] : [value]; };
function enabled(value) { return `${value ?? "0"}` == "1"; };
export function error_code(error, fallback) {
	const value = type(error?.message) == "string" ? error.message : `${error}`;
	const code = trim(split(value, "\n")[0]);
	return length(code) <= 96 && match(code, /^network_[a-z0-9_]+$/) ? code : fallback;
};
function exact_domain(value) {
	if (type(value) != "string" || length(value) > 253 || index(value, ".") < 0) return false;
	for (let part in split(value, "."))
		if (!match(part, /^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/)) return false;
	return true;
};
function policies(values) {
	const result = [];
	for (let domain in sort(keys(values ?? {})))
		if (exact_domain(domain)) push(result, { domain: domain, nameservers: array(values[domain]) });
	return result;
};

export function project(profile, sections) {
	const by_name = {};
	for (let section in sections) by_name[section[".name"]] = section;
	const rules = [];
	for (let section in sections) {
		if (section[".type"] != "lan_access_control") continue;
		push(rules, { id: section[".name"], enabled: enabled(section.enabled),
			ipv4: array(section.ip), ipv6: array(section.ip6), mac: array(section.mac),
			proxy: enabled(section.proxy), dns: enabled(section.dns) });
	}
	const credentials = [];
	for (let entry in profile.authentication ?? []) {
		const separator = index(entry, ":");
		if (separator < 1) continue;
		push(credentials, { id: `auth_${length(credentials)}`, username: substr(entry, 0, separator),
			password_configured: length(entry) > separator + 1, password: substr(entry, separator + 1) });
	}
	return {
		dns: { nameservers: array(profile.dns?.nameserver), default_nameservers: array(profile.dns?.["default-nameserver"]),
			proxy_nameservers: array(profile.dns?.["proxy-server-nameserver"]), direct_nameservers: array(profile.dns?.["direct-nameserver"]),
			policies: policies(profile.dns?.["nameserver-policy"]), proxy_policies: policies(profile.dns?.["proxy-server-nameserver-policy"]) },
		lan: { enabled: enabled(by_name.proxy?.lan_proxy), interfaces: array(by_name.proxy?.lan_inbound_interface), rules: rules },
		router: { enabled: enabled(by_name.proxy?.router_proxy) },
		listeners: { mixed_port: int(profile["mixed-port"] ?? 0), http_port: int(profile.port ?? 0), socks_port: int(profile["socks-port"] ?? 0),
			authentication_enabled: length(credentials) > 0, credentials: credentials }
	};
};

export function public_settings(settings) {
	const result = copy(settings);
	for (let credential in result.listeners.credentials) delete credential.password;
	return result;
};

function fields(value, allowed, errors, path) {
	if (type(value) != "object") { push(errors, { path: path, reason: "object_required" }); return false; }
	for (let key in keys(value)) if (index(allowed, key) < 0) push(errors, { path: `${path}.${key}`, reason: "unknown_field" });
	return true;
};
function boolean(value, errors, path) {
	if (type(value) != "bool") push(errors, { path: path, reason: "boolean_required" });
};
function bounded_array(value, errors, path, maximum) {
	if (type(value) != "array" || length(value) > maximum) {
		push(errors, { path: path, reason: "invalid_list" }); return false;
	}
	return true;
};
function ipv4(value) {
	if (type(value) != "string" || !match(value, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) return false;
	for (let part in split(value, ".")) if (length(part) > 3 || int(part) > 255 || (length(part) > 1 && substr(part, 0, 1) == "0")) return false;
	return true;
};
function ipv6(value) {
	if (type(value) != "string" || !match(value, /^[0-9A-Fa-f:]+$/) || index(value, ":") < 0) return false;
	const halves = split(value, "::");
	if (length(halves) > 2) return false;
	let groups = 0;
	for (let half in halves) {
		if (half == "") continue;
		for (let group in split(half, ":")) {
			if (!match(group, /^[0-9A-Fa-f]{1,4}$/)) return false;
			groups++;
		}
	}
	return length(halves) == 2 ? groups < 8 : groups == 8;
};
function address(value, family) {
	if (type(value) != "string") return false;
	const parts = split(value, "/");
	if (length(parts) > 2 || !(family == 4 ? ipv4(parts[0]) : ipv6(parts[0]))) return false;
	return length(parts) == 1 || (match(parts[1], /^[0-9]+$/) && int(parts[1]) <= (family == 4 ? 32 : 128));
};
function resolver(value) {
	if (type(value) != "string" || length(value) == 0 || length(value) > 2048 || match(value, /[[:cntrl:][:space:]]/)) return false;
	if (value == "system") return true;
	if (ipv4(value) || ipv6(value)) return true;
	// Resolver syntax remains Mihomo's contract; only network transports enter this form.
	return match(value, /^(https|tls|quic|tcp|udp):\/\/[^\s]+$/) != null;
};
function resolvers(value, errors, path, required) {
	if (!bounded_array(value, errors, path, 32)) return;
	if (required && length(value) == 0) push(errors, { path: path, reason: "resolver_required" });
	const seen = [];
	for (let entry in value) {
		if (!resolver(entry)) push(errors, { path: path, reason: "invalid_resolver" });
		if (index(seen, entry) >= 0) push(errors, { path: path, reason: "duplicate_resolver" });
		push(seen, entry);
	}
};
function validate_policies(value, errors, path) {
	if (!bounded_array(value, errors, path, 128)) return;
	const seen = [];
	for (let entry in value) {
		if (!fields(entry, ["domain", "nameservers"], errors, path)) continue;
		if (!exact_domain(entry.domain)) push(errors, { path: path, reason: "exact_domain_required" });
		else if (index(seen, lc(entry.domain)) >= 0) push(errors, { path: path, reason: "duplicate_domain" });
		else push(seen, lc(entry.domain));
		resolvers(entry.nameservers, errors, path, true);
	}
};

export function validate_request(request, revision, current, resources) {
	const errors = [];
	if (!fields(request, ["revision", "settings"], errors, "request")) return { ok: false, error: "network_invalid", errors: errors };
	if (type(revision) != "string" || request.revision != revision) return { ok: false, error: "network_revision_conflict" };
	const settings = copy(request.settings);
	if (!fields(settings, ["dns", "lan", "router", "listeners"], errors, "settings")) return { ok: false, error: "network_invalid", errors: errors };
	if (fields(settings.dns, ["nameservers", "default_nameservers", "proxy_nameservers", "direct_nameservers", "policies", "proxy_policies"], errors, "dns")) {
		for (let name in ["nameservers", "default_nameservers", "proxy_nameservers", "direct_nameservers"])
			resolvers(settings.dns[name], errors, `dns.${name}`, name == "nameservers");
		validate_policies(settings.dns.policies, errors, "dns.policies");
		validate_policies(settings.dns.proxy_policies, errors, "dns.proxy_policies");
	}
	if (fields(settings.router, ["enabled"], errors, "router")) boolean(settings.router.enabled, errors, "router.enabled");
	if (fields(settings.lan, ["enabled", "interfaces", "rules"], errors, "lan")) {
		boolean(settings.lan.enabled, errors, "lan.enabled");
		if (bounded_array(settings.lan.interfaces, errors, "lan.interfaces", 32)) {
			const known = [...map(resources.interfaces ?? [], (entry) => entry.name), ...(current.lan?.interfaces ?? [])];
			for (let name in settings.lan.interfaces)
				if (type(name) != "string" || !match(name, /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$/) || index(known, name) < 0)
					push(errors, { path: "lan.interfaces", reason: "unknown_interface" });
			if (settings.lan.enabled && length(settings.lan.interfaces) == 0) push(errors, { path: "lan.interfaces", reason: "interface_required" });
		}
		if (bounded_array(settings.lan.rules, errors, "lan.rules", 64)) {
			let matched_all = false;
			const seen = [];
			const known = map(current.lan.rules, (entry) => entry.id);
			for (let rule in settings.lan.rules) {
				if (!fields(rule, ["id", "enabled", "ipv4", "ipv6", "mac", "proxy", "dns"], errors, "lan.rules")) continue;
				if (type(rule.id) != "string" || (!match(rule.id, /^new_[A-Za-z0-9_]{1,48}$/) && index(known, rule.id) < 0) || index(seen, rule.id) >= 0)
					push(errors, { path: "lan.rules.id", reason: "invalid_rule_id" });
				push(seen, rule.id);
				for (let field in ["enabled", "proxy", "dns"]) boolean(rule[field], errors, `lan.rules.${field}`);
				for (let field in ["ipv4", "ipv6", "mac"]) {
					if (!bounded_array(rule[field], errors, `lan.rules.${field}`, 64)) continue;
					for (let value in rule[field]) if (!(field == "mac" ? type(value) == "string" && match(value, /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) : address(value, field == "ipv4" ? 4 : 6)))
						push(errors, { path: `lan.rules.${field}`, reason: "invalid_address" });
				}
				if (rule.enabled == true) {
					if (matched_all) push(errors, { path: "lan.rules", reason: "catch_all_must_be_last" });
					if (length(rule.ipv4 ?? []) + length(rule.ipv6 ?? []) + length(rule.mac ?? []) == 0) matched_all = true;
				}
			}
			if (settings.lan.enabled && !matched_all) push(errors, { path: "lan.rules", reason: "catch_all_required" });
		}
	}
	if (fields(settings.listeners, ["mixed_port", "http_port", "socks_port", "authentication_enabled", "credentials"], errors, "listeners")) {
		const used = [];
		for (let field in ["mixed_port", "http_port", "socks_port"]) {
			const value = settings.listeners[field];
			if (type(value) != "int" || value < 0 || value > 65535 || (value > 0 && (index(used, value) >= 0 || index(resources.reserved_ports ?? [], value) >= 0)))
				push(errors, { path: `listeners.${field}`, reason: "invalid_or_reserved_port" });
			if (value > 0) push(used, value);
		}
		if (settings.listeners.mixed_port == 0 && settings.listeners.http_port == 0)
			push(errors, { path: "listeners", reason: "http_probe_listener_required" });
		boolean(settings.listeners.authentication_enabled, errors, "listeners.authentication_enabled");
		if (bounded_array(settings.listeners.credentials, errors, "listeners.credentials", 32)) {
			const seen = [];
			const ids = [];
			for (let credential in settings.listeners.credentials) {
				if (!fields(credential, ["id", "username", "password", "password_configured"], errors, "listeners.credentials")) continue;
				const previous = filter(current.listeners.credentials, (entry) => entry.id == credential.id)[0];
				if (type(credential.id) != "string" || (previous == null && !match(credential.id, /^new_[A-Za-z0-9_]{1,48}$/)) || index(ids, credential.id) >= 0)
					push(errors, { path: "listeners.credentials.id", reason: "invalid_credential_id" });
				push(ids, credential.id);
				if (credential.password == null) credential.password = previous?.password;
				if (type(credential.username) != "string" || !match(credential.username, /^[^[:cntrl:][:space:]:]{1,128}$/) || index(seen, credential.username) >= 0)
					push(errors, { path: "listeners.credentials.username", reason: "invalid_username" });
				push(seen, credential.username);
				if (type(credential.password) != "string" || !match(credential.password, /^[^[:cntrl:]]{1,256}$/))
					push(errors, { path: "listeners.credentials.password", reason: "password_required" });
				credential.password_configured = true;
			}
			if (settings.listeners.authentication_enabled && length(settings.listeners.credentials) == 0)
				push(errors, { path: "listeners.credentials", reason: "credential_required" });
		}
	}
	return length(errors) > 0 ? { ok: false, error: "network_invalid", errors: errors } : { ok: true, settings: settings };
};

export function managed_policy(original, entries) {
	const result = {};
	for (let name, value in original ?? {}) if (!exact_domain(name)) result[name] = copy(value);
	for (let entry in entries) result[lc(entry.domain)] = copy(entry.nameservers);
	return result;
};

export function runtime_profile(original, settings) {
	const profile = copy(original);
	if (profile.dns == null) profile.dns = {};
	const mapping = { nameservers: "nameserver", default_nameservers: "default-nameserver", proxy_nameservers: "proxy-server-nameserver", direct_nameservers: "direct-nameserver" };
	for (let key, name in mapping) profile.dns[name] = copy(settings.dns[key]);
	profile.dns["nameserver-policy"] = managed_policy(profile.dns["nameserver-policy"], settings.dns.policies);
	profile.dns["proxy-server-nameserver-policy"] = managed_policy(profile.dns["proxy-server-nameserver-policy"], settings.dns.proxy_policies);
	profile["mixed-port"] = settings.listeners.mixed_port;
	profile.port = settings.listeners.http_port;
	profile["socks-port"] = settings.listeners.socks_port;
	profile.authentication = settings.listeners.authentication_enabled ? map(settings.listeners.credentials, (entry) => `${entry.username}:${entry.password}`) : [];
	return profile;
};
