

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let relative_path, profile_path, mapped_string, migrate_object, migrate_sections, public_plan;



const OLD = "/etc/nikki";
const NATIVE = "/etc/opl-netfleet/native";

relative_path = function(value) {
	return type(value) == "string" && length(value) > 0 && substr(value, 0, 1) != "/" &&
		!match(value, /[[:cntrl:]]/) && index(value, "\\") < 0 &&
		length(filter(split(value, "/"), (part) => part == ".." || part == "")) == 0;
};

profile_path = function(reference, root) {
	const parts = split(reference ?? "", ":");
	if (length(parts) != 2 || !relative_path(parts[1])) return null;
	if (parts[0] == "subscription" && match(parts[1], /^[A-Za-z0-9_]+$/))
		return `${root}/subscriptions/${parts[1]}.yaml`;
	if (parts[0] == "file" && parts[1] != "OPL-NetFleet.json" && index(parts[1], "opl-netfleet/") != 0)
		return `${root}/profiles/${parts[1]}`;
	return null;
};

mapped_string = function(value) {
	if (index(value, OLD) < 0) return value;
	if (index(value, `${OLD}/`) != 0) die("unsupported_legacy_path");
	const relative = substr(value, length(OLD) + 1);
	if (!relative_path(relative)) die("unsupported_legacy_path");
	const top = split(relative, "/")[0];
	if (index(["run", "profiles", "subscriptions", "providers", "rulesets", "ui", "geodata", "certs"], top) < 0)
		die("unsupported_legacy_path");
	if (relative == "run/config.yaml" || index(relative, "profiles/opl-netfleet/") == 0 || relative == "profiles/OPL-NetFleet.json" ||
		index(relative, "run/providers/proxy/netfleet-") == 0)
		die("generated_artifact_is_not_input");
	return `${NATIVE}/${relative}`;
};

migrate_object = function(value) {
	if (type(value) == "string") return mapped_string(value);
	if (type(value) == "array") return map(value, migrate_object);
	if (type(value) != "object") return value;
	const result = {};
	for (let key in keys(value)) {
		const mapped = index(["nikki-proxies", "nikki-proxy-groups", "nikki-rules"], key) >= 0 ?
			`netfleet-${substr(key, 6)}` : key;
		result[mapped] = migrate_object(value[key]);
	}
	return result;
};

migrate_sections = function(sections, recovery) {
	if (profile_path(recovery, OLD) == null) return { ok: false, error: "invalid_recovery_profile" };
	const result = [];
	let config_found = false;
	let mixin_found = false;
	try {
		for (let section in sections ?? []) {
			const name = section[".name"];
			const kind = section[".type"];
			if (type(name) != "string" || !match(name, /^[A-Za-z0-9_]+$/) ||
				type(kind) != "string" || !match(kind, /^[A-Za-z0-9_]+$/))
				return { ok: false, error: "invalid_uci_section" };
			const options = {};
			for (let key in keys(section)) {
				if (substr(key, 0, 1) == ".") continue;
				if (!match(key, /^[A-Za-z0-9_]+$/)) return { ok: false, error: "invalid_uci_option" };
				options[key] = migrate_object(section[key]);
			}
			if (name == "config") {
				config_found = true;
				options.profile = recovery;
				options.enabled = "1";
			}
			if (name == "mixin") {
				mixin_found = true;
				if (`${options.tun_enabled ?? "0"}` == "1") return { ok: false, error: "tun_mode_not_supported" };
			}
			if (name == "proxy" && (options.tcp_mode != "tproxy" || options.udp_mode != "tproxy"))
				return { ok: false, error: "tproxy_mode_required" };
			if (name == "routing") options.dummy_device = "netfleet-dummy";
			if (options.cgroup_name != null) options.cgroup_name = "opl-netfleet-core";
			push(result, { name: name, type: kind, options: options });
		}
	} catch (error) { return { ok: false, error: error.message ?? "migration_input_invalid" }; }
	if (!config_found || !mixin_found) return { ok: false, error: "missing_backend_configuration" };
	return { ok: true, sections: result };
};

public_plan = function(found) {
	return { ready: found.ready == true, revision: found.revision ?? null,
		backend: found.backend ?? "nikki-mihomo",
		target_backend: "native-mihomo", missing: found.missing ?? [],
		capabilities: { subscriptions: found.subscription_count ?? 0,
			profiles: found.profile_count ?? 0, private_mixin: found.private_mixin == true,
			dashboard: found.dashboard == true, shared_policy: found.policy_valid == true } };
};

return { relative_path, profile_path, migrate_object, migrate_sections, public_plan };
};
