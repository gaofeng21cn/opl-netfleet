const PARTITIONS = [
	"main",
	"policy_source",
	"recovery_profile",
	"bindings",
	"providers",
	"regions",
	"provider_regions",
	"capabilities",
	"selection",
	"checks",
	"evidence",
	"fail_open"
];

function is_object(value) {
	return type(value) == "object";
};

function is_nonempty_string(value) {
	return type(value) == "string" && length(value) > 0;
};

function is_stable_id(value) {
	return is_nonempty_string(value) && match(value, /^[A-Za-z0-9][A-Za-z0-9_-]*$/);
};

function is_stable_uci_section(value) {
	return is_nonempty_string(value) && match(value, /^[A-Za-z0-9_]+$/) &&
		!match(value, /^cfg[0-9a-f]+$/);
};

function add_error(errors, message) {
	push(errors, message);
};

function validate_profile_reference(value, path, errors) {
	if (!is_nonempty_string(value) ||
		(index(value, "subscription:") != 0 && index(value, "file:") != 0)) {
		add_error(errors, `${path} must start with subscription: or file:`);
	} else if (index(value, "subscription:") == 0 &&
		!is_stable_uci_section(substr(value, length("subscription:")))) {
		add_error(errors, `${path} must reference a stable named subscription section`);
	}
};

function validate_bundle_reference(value, path, errors) {
	if (!is_nonempty_string(value) || !match(value, /^bundle:[A-Za-z0-9][A-Za-z0-9_-]*$/)) {
		add_error(errors, `${path} must reference bundle:<stable-id>`);
	}
};

function has(object, key) {
	return is_object(object) && key in object;
};

function valid_mode(value, allowed) {
	return index(allowed, value) >= 0;
};

function array_has(values, value) {
	return type(values) == "array" && index(values, value) >= 0;
};

function validate_margin(value, path, errors) {
	if (value != null && (type(value) != "int" || value < 0 || value > 10000)) {
		add_error(errors, `${path} must be an integer from 0 to 10000`);
	}
};

export function canonical_cidr(value) {
	if (type(value) != "string" || value != trim(value) || !match(value, /^[0-9A-Fa-f:.]+\/(0|[1-9][0-9]{0,2})$/)) return null;
	const parts = split(value, "/");
	const bytes = iptoarr(parts[0]);
	const prefix = int(parts[1]);
	if (bytes == null || prefix > length(bytes) * 8) return null;
	// Require a network prefix so a mistyped host does not silently broaden a rule.
	for (let i = 0; i < length(bytes); i++) {
		const remaining = prefix - i * 8;
		if (remaining <= 0 && bytes[i] != 0 || remaining > 0 && remaining < 8 &&
			(bytes[i] & ((1 << (8 - remaining)) - 1)) != 0) return null;
	}
	return `${arrtoip(bytes)}/${prefix}`;
};

export function validate_routing_rules(rules, capabilities, errors) {
	if (rules == null) return;
	if (type(rules) != "array") {
		add_error(errors, "routing_rules must be an array when present");
		return;
	}
	const seen = {};
	for (let i = 0; i < length(rules); i++) {
		const rule = rules[i];
		if (!is_object(rule)) {
			add_error(errors, `routing_rules.${i} must be an object`);
			continue;
		}
		const fields = keys(rule);
		for (let j = 0; j < length(fields); j++) {
			if (index(["kind", "value", "capability", "target"], fields[j]) < 0)
				add_error(errors, `routing_rules.${i} contains unsupported field: ${fields[j]}`);
		}
		if (index(["domain_suffix", "ip_cidr"], rule.kind) < 0)
			add_error(errors, `routing_rules.${i}.kind must be domain_suffix or ip_cidr`);
		if (rule.kind == "domain_suffix" && (!is_nonempty_string(rule.value) || length(rule.value) > 253 ||
			index(rule.value, ".") < 1 || index(rule.value, "..") >= 0 ||
			!match(rule.value, /^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$/)))
			add_error(errors, `routing_rules.${i}.value must be a plain domain suffix`);
		if (rule.kind == "ip_cidr" && canonical_cidr(rule.value) == null)
			add_error(errors, `routing_rules.${i}.value must be an IPv4 or IPv6 network CIDR`);
		if (rule.target == "direct") {
			if (has(rule, "capability")) add_error(errors, `routing_rules.${i} must not combine direct and capability targets`);
		} else if (has(rule, "target") || !is_stable_id(rule.capability) || capabilities?.[rule.capability]?.enabled != true)
			add_error(errors, `routing_rules.${i}.capability must reference an enabled capability`);
		const value = rule.kind == "ip_cidr" ? canonical_cidr(rule.value) : lc(rule.value ?? "");
		const identity = `${rule.kind}/${value}/${rule.target == "direct" ? "direct" : `capability:${rule.capability}`}`;
		if (seen[identity] == true)
			add_error(errors, `routing_rules contains duplicate entry: ${identity}`);
		seen[identity] = true;
	}
};

function capability_before(policy, left, right) {
	const left_order = policy?.capabilities?.[left]?.display_order ?? 1000;
	const right_order = policy?.capabilities?.[right]?.display_order ?? 1000;
	return left_order != right_order ? left_order < right_order : left < right;
};

function region_before(policy, left, right) {
	const left_order = policy?.regions?.[left]?.display_order ?? 1000;
	const right_order = policy?.regions?.[right]?.display_order ?? 1000;
	return left_order != right_order ? left_order < right_order : left < right;
};

export function ordered_regions(policy) {
	const result = keys(policy?.regions ?? {});
	for (let i = 1; i < length(result); i++) {
		for (let j = i; j > 0 && region_before(policy, result[j], result[j - 1]); j--) {
			const previous = result[j - 1];
			result[j - 1] = result[j];
			result[j] = previous;
		}
	}
	return result;
};

export function ordered_capabilities(policy) {
	const result = keys(policy?.capabilities ?? {});
	for (let i = 1; i < length(result); i++) {
		for (let j = i; j > 0 && capability_before(policy, result[j], result[j - 1]); j--) {
			const previous = result[j - 1];
			result[j - 1] = result[j];
			result[j] = previous;
		}
	}
	return result;
};

function validate_region_list(value, path, regions, errors) {
	if (value == null) {
		return;
	}
	if (type(value) != "array" || length(value) == 0) {
		add_error(errors, `${path} must be a non-empty array when present`);
		return;
	}
	const seen = {};
	for (let i = 0; i < length(value); i++) {
		const region = value[i];
		if (!is_stable_id(region) || !has(regions, region)) {
			add_error(errors, `${path} references unknown region: ${region}`);
		} else if (seen[region] == true) {
			add_error(errors, `${path} contains duplicate region: ${region}`);
		}
		seen[region] = true;
	}
};

function validate_checks(checks, errors) {
	if (checks == null) {
		return;
	}
	if (!is_object(checks)) {
		add_error(errors, "checks must be an object");
		return;
	}
	if (has(checks, "availability")) {
		add_error(errors, "checks.availability is unsupported; use transaction protected probes");
	}
	if (type(checks.provider_healthcheck_timeout_ms) != "int" ||
		checks.provider_healthcheck_timeout_ms < 1000 || checks.provider_healthcheck_timeout_ms > 30000) {
		add_error(errors, "checks.provider_healthcheck_timeout_ms must be between 1000 and 30000");
	}
	const latency = checks.latency;
	if (!is_object(latency) || latency.method != "mihomo_delay" ||
		!is_nonempty_string(latency.url) || index(latency.url, "https://") != 0 ||
		type(latency.timeout_ms) != "int" || latency.timeout_ms < 100 || latency.timeout_ms > 10000 ||
		type(latency.expected_status) != "int" || latency.expected_status < 100 || latency.expected_status > 599) {
		add_error(errors, "checks.latency must define a bounded Mihomo proxy-path delay test with expected_status");
	}
	const quota = checks.quota;
	if (quota != null && (!is_object(quota) || quota.source != "nikki_subscription_metadata" || quota.zero_is_exhausted != true)) {
		add_error(errors, "checks.quota must use Nikki subscription metadata");
	}
};

export function automation(policy) {
	const configured = policy?.automation ?? {};
	return {
		enabled: configured.enabled ?? true,
		selection_interval_seconds: configured.selection_interval_seconds ?? 1800,
		subscription_refresh_enabled: configured.subscription_refresh_enabled ?? true,
		subscription_refresh_interval_seconds: configured.subscription_refresh_interval_seconds ?? 43200,
		poll_interval_seconds: configured.poll_interval_seconds ?? 15,
		startup_grace_seconds: configured.startup_grace_seconds ?? 120,
		runtime_grace_seconds: configured.runtime_grace_seconds ?? 45
	};
};

export function guard_probe_url(policy) {
	const id = policy?.fail_open?.healthcheck?.guard_probe_id;
	const probes = policy?.fail_open?.probes ?? [];
	for (let i = 0; i < length(probes); i++) {
		if (probes[i]?.id == id) return probes[i]?.url ?? null;
	}
	return null;
};

function resolved_margin(policy, capability, field) {
	const override = type(capability) == "string" ?
		policy?.capabilities?.[capability]?.[field] : null;
	const value = type(override) == "int" ? override : policy?.selection?.[field];
	return type(value) == "int" ? value : 150;
};

export function region_switch_margin(policy, capability) {
	return resolved_margin(policy, capability, "region_switch_margin_ms");
};

export function leaf_switch_margin(policy, capability) {
	return resolved_margin(policy, capability, "leaf_switch_margin_ms");
};

export function validate(policy) {
	const errors = [];

	if (!is_object(policy)) {
		return { ok: false, errors: ["policy must be an object"] };
	}
	if (policy.schema_version != 2) {
		add_error(errors, "schema_version must be 2");
	}
	for (let i = 0; i < length(PARTITIONS); i++) {
		const partition = PARTITIONS[i];
		if (!has(policy, partition)) {
			add_error(errors, `missing partition: ${partition}`);
		}
	}

	const main = policy.main;
	if (!is_object(main)) {
		add_error(errors, "main must be an object");
	} else {
		if (!is_nonempty_string(main.target)) {
			add_error(errors, "main.target must be a non-empty string");
		}
		if (type(main.enabled) != "bool") {
			add_error(errors, "main.enabled must be boolean");
		}
		if (has(main, "base_profile")) {
			add_error(errors, "main.base_profile is unsupported; use policy_source and recovery_profile");
		}
	}

	const policy_source = policy.policy_source;
	if (!is_object(policy_source)) {
		add_error(errors, "policy_source must be an object");
	} else {
		if (policy_source.kind == "profile") {
			validate_profile_reference(policy_source.ref, "policy_source.ref", errors);
		} else if (policy_source.kind == "bundle") {
			validate_bundle_reference(policy_source.ref, "policy_source.ref", errors);
		} else {
			add_error(errors, "policy_source.kind must be profile or bundle");
		}
	}

	const recovery_profile = policy.recovery_profile;
	if (!is_object(recovery_profile)) {
		add_error(errors, "recovery_profile must be an object");
	} else {
		validate_profile_reference(recovery_profile.ref, "recovery_profile.ref", errors);
	}

	const capabilities = policy.capabilities;
	let enabled_capability_count = 0;
	let automatic_capability_count = 0;
	let automatic_root_count = 0;
	if (!is_object(capabilities) || length(keys(capabilities)) == 0) {
		add_error(errors, "at least one capability is required");
	} else {
		const capability_names = keys(capabilities);
		for (let i = 0; i < length(capability_names); i++) {
			const name = capability_names[i];
			const capability = capabilities[name];
			if (!is_stable_id(name)) {
				add_error(errors, `capability id is not stable: ${name}`);
			}
			if (!is_object(capability)) {
				add_error(errors, `capability ${name} must be an object`);
				continue;
			}
			if (type(capability.enabled) != "bool") {
				add_error(errors, `capability ${name}.enabled must be boolean`);
			}
			if (!valid_mode(capability.mode, ["manual", "automatic"])) {
				add_error(errors, `capability ${name}.mode must be manual or automatic`);
			}
			if (capability.display_name != null && !is_nonempty_string(capability.display_name)) {
				add_error(errors, `capability ${name}.display_name must be a non-empty string when present`);
			}
			if (capability.display_order != null &&
				(type(capability.display_order) != "int" || capability.display_order < 0 || capability.display_order > 10000)) {
				add_error(errors, `capability ${name}.display_order must be an integer from 0 to 10000`);
			}
			if (has(capability, "fallback_provider")) {
				add_error(errors, `capability ${name}.fallback_provider is unsupported; use provider primary/reserve roles`);
			}
			validate_margin(capability.region_switch_margin_ms,
				`capabilities.${name}.region_switch_margin_ms`, errors);
			validate_margin(capability.leaf_switch_margin_ms,
				`capabilities.${name}.leaf_switch_margin_ms`, errors);
			if (capability.enabled == true) {
				enabled_capability_count++;
				if (capability.mode == "automatic") {
					automatic_capability_count++;
					if (capability.prefer_region_from == null) {
						automatic_root_count++;
					}
				}
			}
			if (capability.prefer_region_from != null &&
				!is_stable_id(capability.prefer_region_from)) {
				add_error(errors, `capability ${name}.prefer_region_from must be a stable capability id`);
			}
		}
	}
	if (enabled_capability_count == 0 && main?.enabled == true) {
		add_error(errors, "main.enabled requires at least one enabled capability");
	}
	if (automatic_capability_count > 0 && automatic_root_count != 1) {
		add_error(errors, "enabled automatic capabilities require exactly one root without prefer_region_from");
	}
	const automatic_names = keys(capabilities ?? {});
	for (let i = 0; i < length(automatic_names); i++) {
		const name = automatic_names[i];
		const capability = capabilities[name];
		const parent = capability?.prefer_region_from;
		if (parent == null) {
			continue;
		}
		if (capability?.enabled != true) {
			continue;
		}
		if (capability?.mode != "automatic") {
			add_error(errors, `capability ${name}.prefer_region_from requires enabled automatic mode`);
			continue;
		}
		if (parent == name || capabilities?.[parent]?.enabled != true ||
			capabilities?.[parent]?.mode != "automatic") {
			add_error(errors, `capability ${name}.prefer_region_from references a non-automatic capability: ${parent}`);
			continue;
		}
		const seen = {};
		let current = name;
		for (let depth = 0; depth <= length(automatic_names); depth++) {
			if (seen[current] == true) {
				add_error(errors, `automatic capability dependency cycle reaches: ${current}`);
				break;
			}
			seen[current] = true;
			current = capabilities?.[current]?.prefer_region_from;
			if (current == null) {
				break;
			}
		}
	}
	validate_routing_rules(policy.routing_rules, capabilities, errors);

	const bindings = policy.bindings;
	const entry_counts = {};
	if (!is_object(bindings)) {
		add_error(errors, "bindings must be an object");
	} else {
		const binding_names = keys(bindings);
		for (let i = 0; i < length(binding_names); i++) {
			const group = binding_names[i];
			const binding = bindings[group];
			const capability = binding?.capability;
			if (!is_nonempty_string(group) || !is_object(binding)) {
				add_error(errors, `binding ${group} must be an object`);
				continue;
			}
			if (!is_stable_id(capability) || !has(capabilities, capability)) {
				add_error(errors, `binding ${group} references unknown capability: ${capability}`);
				continue;
			}
			if (!valid_mode(binding.kind, ["entry", "policy"])) {
				add_error(errors, `binding ${group}.kind must be entry or policy`);
				continue;
			}
			if (binding.kind == "entry") {
				entry_counts[capability] = (entry_counts[capability] ?? 0) + 1;
			}
		}
	}
	const capability_names = keys(capabilities ?? {});
	for (let i = 0; i < length(capability_names); i++) {
		const name = capability_names[i];
		const count = entry_counts[name] ?? 0;
		if (capabilities[name]?.enabled == true && count != 1) {
			add_error(errors, `enabled capability ${name} must have exactly one entry binding`);
		}
	}

	const providers = policy.providers;
	if (!is_object(providers) || length(keys(providers)) == 0) {
		add_error(errors, "at least one provider is required");
	} else {
		let enabled = 0;
		let primary = 0;
		const sections = {};
		const provider_names = keys(providers);
		for (let i = 0; i < length(provider_names); i++) {
			const name = provider_names[i];
			const provider = providers[name];
			if (!is_stable_id(name)) {
				add_error(errors, `provider id is not stable: ${name}`);
			}
			if (!is_object(provider) || !is_stable_uci_section(provider.section)) {
				add_error(errors, `provider ${name} must reference a stable named subscription section`);
				continue;
			}
			if (provider.billing != null && !valid_mode(provider.billing, ["subscription", "buyout"])) {
				add_error(errors, `provider ${name} billing must be subscription or buyout`);
			}
			if (has(provider, "cache")) {
				add_error(errors, `provider ${name} cache override is unsupported; cache identity comes from section`);
			}
			if (provider.quota != null && !is_object(provider.quota)) {
				add_error(errors, `provider ${name} quota must be an object`);
			}
			if (provider.enabled == true) {
				enabled++;
				if (sections[provider.section]) {
					add_error(errors, `enabled providers share subscription section: ${provider.section}`);
				}
				sections[provider.section] = true;
			}
			if (provider.role != "primary" && provider.role != "reserve") {
				add_error(errors, `provider ${name} role must be primary or reserve`);
			} else if (provider.enabled == true && provider.role == "primary") {
				primary++;
			}
		}
		if (enabled == 0) {
			add_error(errors, "MVP requires at least one enabled provider");
		}
		if (primary == 0) {
			add_error(errors, "MVP requires one enabled primary provider");
		}
	}
	const regions = policy.regions;
	if (!is_object(regions) || length(keys(regions)) == 0) {
		add_error(errors, "at least one region is required");
	} else {
		const region_names = keys(regions);
		for (let i = 0; i < length(region_names); i++) {
			const name = region_names[i];
			const region = regions[name];
			if (!is_stable_id(name)) {
				add_error(errors, `region id is not stable: ${name}`);
			}
			if (!is_object(region)) {
				add_error(errors, `region ${name} must be an object`);
				continue;
			}
			if (region.capability != null) {
				add_error(errors, `region ${name}.capability is unsupported; constrain regions in capabilities`);
			}
			if (!valid_mode(region.mode, ["manual_only", "automatic"])) {
				add_error(errors, `region ${name} mode must be manual_only or automatic`);
			}
			if (region.display_name != null && !is_nonempty_string(region.display_name)) {
				add_error(errors, `region ${name} display_name must be a non-empty string when present`);
			}
			if (region.flag != null && !is_nonempty_string(region.flag)) {
				add_error(errors, `region ${name} flag must be a non-empty string when present`);
			}
			if (region.display_order != null &&
				(type(region.display_order) != "int" || region.display_order < 0 || region.display_order > 10000)) {
				add_error(errors, `region ${name}.display_order must be an integer from 0 to 10000`);
			}
			if (region.group != null) {
				add_error(errors, `region ${name}.group is unsupported; bind groups in bindings`);
			}
		}
		const display_orders = {};
		for (let i = 0; i < length(region_names); i++) {
			const order = regions[region_names[i]]?.display_order;
			if (order != null) {
				if (display_orders[order] != null) add_error(errors,
					`regions contain duplicate display_order: ${order}`);
				display_orders[order] = region_names[i];
			}
		}
	}
	for (let i = 0; i < length(capability_names); i++) {
		const name = capability_names[i];
		const capability = capabilities[name];
		if (!is_object(capability)) {
			continue;
		}
		validate_region_list(capability.allowed_regions,
			`capabilities.${name}.allowed_regions`, regions, errors);
		validate_region_list(capability.excluded_regions,
			`capabilities.${name}.excluded_regions`, regions, errors);
		if (type(capability.allowed_regions) == "array" && type(capability.excluded_regions) == "array") {
			for (let j = 0; j < length(capability.allowed_regions); j++) {
				if (array_has(capability.excluded_regions, capability.allowed_regions[j])) {
					add_error(errors, `capability ${name} cannot both allow and exclude region: ${capability.allowed_regions[j]}`);
				}
			}
		}
	}

	const provider_regions = policy.provider_regions;
	if (!is_object(provider_regions)) {
		add_error(errors, "provider_regions must be an object");
	} else {
		const provider_names = keys(provider_regions);
		for (let i = 0; i < length(provider_names); i++) {
			const provider = provider_names[i];
			if (!has(providers, provider)) {
				add_error(errors, `provider_regions references unknown provider: ${provider}`);
				continue;
			}
			const mappings = provider_regions[provider];
			if (type(mappings) != "array" || length(mappings) == 0) {
				add_error(errors, `provider_regions.${provider} must be a non-empty array`);
				continue;
			}
			for (let j = 0; j < length(mappings); j++) {
				const mapping = mappings[j];
				if (!is_object(mapping) || !has(regions, mapping.region)) {
					add_error(errors, `provider_regions.${provider} references unknown region`);
				} else if (!is_nonempty_string(mapping.filter)) {
					add_error(errors, `provider_regions.${provider}.${mapping.region} filter must be a non-empty string`);
				} else if (mapping.members != null) {
					add_error(errors, `provider_regions.${provider}.${mapping.region} members is unsupported; use filter`);
				} else if (mapping.group != null) {
					add_error(errors, `provider_regions.${provider}.${mapping.region} group is unsupported; bind groups in bindings`);
				}
			}
		}
		const configured_providers = keys(providers ?? {});
		for (let i = 0; i < length(configured_providers); i++) {
			const provider_name = configured_providers[i];
			if (providers[provider_name]?.enabled == true && !has(provider_regions, provider_name)) {
				add_error(errors, `enabled provider missing provider_regions: ${provider_name}`);
			}
		}
	}

	if (!is_object(policy.selection)) {
		add_error(errors, "selection must be an object");
	} else {
		validate_margin(policy.selection.region_switch_margin_ms,
			"selection.region_switch_margin_ms", errors);
		validate_margin(policy.selection.leaf_switch_margin_ms,
			"selection.leaf_switch_margin_ms", errors);
		if (policy.selection.mode != null) {
			add_error(errors, "selection.mode is unsupported; configure mode on each capability");
		}
	}
	if (policy.automation != null) {
		const configured = policy.automation;
		if (!is_object(configured) || type(configured.enabled) != "bool" ||
			type(configured.selection_interval_seconds) != "int" ||
			configured.selection_interval_seconds < 300 || configured.selection_interval_seconds > 86400 ||
			(configured.subscription_refresh_enabled != null &&
				type(configured.subscription_refresh_enabled) != "bool") ||
			(configured.subscription_refresh_interval_seconds != null &&
				(type(configured.subscription_refresh_interval_seconds) != "int" ||
				configured.subscription_refresh_interval_seconds < 3600 ||
				configured.subscription_refresh_interval_seconds > 604800)) ||
			type(configured.poll_interval_seconds) != "int" ||
			configured.poll_interval_seconds < 5 || configured.poll_interval_seconds > 60 ||
			(configured.startup_grace_seconds != null &&
				(type(configured.startup_grace_seconds) != "int" ||
				configured.startup_grace_seconds < 30 || configured.startup_grace_seconds > 900)) ||
			type(configured.runtime_grace_seconds) != "int" ||
			configured.runtime_grace_seconds < 15 || configured.runtime_grace_seconds > 300) {
			add_error(errors, "invalid automation configuration");
		}
	}
	validate_checks(policy.checks, errors);
	if (!is_object(policy.evidence) || policy.evidence.path != "/etc/opl-netfleet/evidence.json") {
		add_error(errors, "evidence.path must be /etc/opl-netfleet/evidence.json");
	}
	if (!is_object(policy.fail_open)) {
		add_error(errors, "fail_open must be an object");
	} else if (type(policy.fail_open.probes) != "array" || length(policy.fail_open.probes) == 0) {
		add_error(errors, "fail_open.probes must contain at least one protected probe");
	} else {
		const healthcheck = policy.fail_open.healthcheck;
		if (!is_object(healthcheck) ||
			type(healthcheck.interval_seconds) != "int" || healthcheck.interval_seconds < 30 || healthcheck.interval_seconds > 3600 ||
			type(healthcheck.max_failed_times) != "int" || healthcheck.max_failed_times < 1 || healthcheck.max_failed_times > 10 ||
			type(healthcheck.timeout_ms) != "int" || healthcheck.timeout_ms < 1000 || healthcheck.timeout_ms > 30000 ||
			!is_nonempty_string(healthcheck.path_probe_id) ||
			!is_nonempty_string(healthcheck.guard_probe_id)) {
			add_error(errors, "invalid fail_open.healthcheck");
		}
		const probe_ids = {};
		for (let i = 0; i < length(policy.fail_open.probes); i++) {
			const probe = policy.fail_open.probes[i];
			if (!is_object(probe) || !is_nonempty_string(probe.id) ||
				!is_nonempty_string(probe.url) || index(probe.url, "https://") != 0 ||
				type(probe.expected_status) != "int" || probe.expected_status < 100 || probe.expected_status > 599) {
				add_error(errors, `invalid fail_open.probes entry: ${i}`);
			}
			if (is_nonempty_string(probe?.id)) {
				if (probe_ids[probe.id] == true) {
					add_error(errors, `duplicate fail_open probe id: ${probe.id}`);
				}
				probe_ids[probe.id] = true;
			}
		}
		if (is_object(healthcheck)) {
			if (probe_ids[healthcheck.path_probe_id] != true) {
				add_error(errors, "fail_open.healthcheck.path_probe_id references unknown probe");
			}
			if (probe_ids[healthcheck.guard_probe_id] != true) {
				add_error(errors, "fail_open.healthcheck.guard_probe_id references unknown probe");
			}
		}
	}

	return { ok: length(errors) == 0, errors: errors };
};
