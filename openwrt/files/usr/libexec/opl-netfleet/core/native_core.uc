import { valid_id } from "./native_sources.uc";

// Only the compiled routing graph is accepted; listener ownership stays local.
export function prepare(input, sources) {
	if (type(input) != "object" || type(input["proxy-groups"]) != "array" ||
		type(input.rules) != "array" || type(input["proxy-providers"]) != "object")
		return { ok: false, error: "compiled_profile_required" };
	if (length(input.proxies ?? []) > 0 || length(keys(input["rule-providers"] ?? {})) > 0)
		return { ok: false, error: "unsupported_native_source" };
	for (let rule in input.rules) {
		if (type(rule) != "string" || index(["MATCH", "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD",
			"IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR", "SRC-PORT", "DST-PORT", "NETWORK"], split(rule, ",")[0]) < 0)
			return { ok: false, error: "unsupported_native_rule" };
	}
	const port = input["mixed-port"] ?? 17890;
	if (type(port) != "int" || port < 1024 || port > 65535)
		return { ok: false, error: "invalid_mixed_port" };
	const providers = {};
	const bound = {};
	for (let name, provider in input["proxy-providers"]) {
		const path = provider?.path;
		const prefix = "/etc/opl-netfleet/native/cache/";
		if (provider?.type != "file" || type(path) != "string" || index(path, prefix) != 0 ||
			substr(path, -5) != ".json") return { ok: false, error: "native_cache_required" };
		const id = substr(path, length(prefix), length(path) - length(prefix) - 5);
		const source = sources?.[id];
		if (!valid_id(id) || source?.ready != true) return { ok: false, error: "native_source_not_ready" };
		providers[name] = { type: "file", path: path };
		// Mihomo owns health checks and URLTest; never import remote download options.
		if (provider["health-check"] != null) providers[name]["health-check"] = provider["health-check"];
		if (provider["exclude-filter"] != null) providers[name]["exclude-filter"] = provider["exclude-filter"];
		bound[id] = source.cache_sha256;
	}
	if (length(keys(bound)) == 0) return { ok: false, error: "native_source_required" };
	return { ok: true, stage: {
		schema_version: 1,
		sources: bound,
		profile: {
			"proxy-providers": providers, "proxy-groups": input["proxy-groups"], rules: input.rules,
			"mixed-port": port, "allow-lan": false, "bind-address": "127.0.0.1",
			"external-controller-unix": "/etc/opl-netfleet/native/core/controller.sock",
			mode: "rule", ipv6: false, "log-level": "silent",
			dns: { enable: false }, tun: { enable: false }, profile: { "store-selected": false }
		}
	} };
};
