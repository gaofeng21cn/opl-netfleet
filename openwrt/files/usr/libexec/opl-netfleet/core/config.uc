import { validate as validate_policy, ordered_regions } from "./policy.uc";

function object(value) {
	return type(value) == "object";
};

function nonempty(value) {
	return type(value) == "string" && length(trim(value)) > 0;
};

function clone(value) {
	return json(sprintf("%J", value));
};

function has(object, key) {
	return type(object) == "object" && key in object;
};

function sorted_names(value) {
	const result = keys(value ?? {});
	for (let i = 1; i < length(result); i++) {
		for (let j = i; j > 0 && result[j] < result[j - 1]; j--) {
			const previous = result[j - 1];
			result[j - 1] = result[j];
			result[j] = previous;
		}
	}
	return result;
};

function known_keys(value, allowed, errors, path) {
	if (!object(value)) {
		push(errors, `${path} must be an object`);
		return false;
	}
	const names = keys(value);
	for (let i = 0; i < length(names); i++) {
		if (index(allowed, names[i]) < 0) {
			push(errors, `${path} contains unsupported field: ${names[i]}`);
		}
	}
	return true;
};

function option_exists(options, kind, ref) {
	for (let i = 0; i < length(options ?? []); i++) {
		if ((kind == null || options[i]?.kind == kind) && options[i]?.ref == ref) return true;
	}
	return false;
};

function array_of_known_ids(value, known, errors, path) {
	if (type(value) != "array") {
		push(errors, `${path} must be an array`);
		return false;
	}
	const seen = {};
	for (let i = 0; i < length(value); i++) {
		if (type(value[i]) != "string" || !has(known, value[i])) {
			push(errors, `${path} references unknown id: ${value[i]}`);
		} else if (seen[value[i]] == true) {
			push(errors, `${path} contains duplicate id: ${value[i]}`);
		}
		seen[value[i]] = true;
	}
	return true;
};

function probe_url(policy, probe_id) {
	const probes = policy?.fail_open?.probes ?? [];
	for (let i = 0; i < length(probes); i++) {
		if (probes[i]?.id == probe_id) return probes[i]?.url ?? null;
	}
	return null;
};

function set_probe_url(policy, probe_id, url) {
	const probes = policy?.fail_open?.probes ?? [];
	for (let i = 0; i < length(probes); i++) {
		if (probes[i]?.id == probe_id) probes[i].url = url;
	}
};

function allowed_region_ids(policy, capability) {
	const region_names = ordered_regions(policy);
	const allowed = capability?.allowed_regions;
	const excluded = capability?.excluded_regions ?? [];
	const result = [];
	for (let i = 0; i < length(region_names); i++) {
		if ((type(allowed) != "array" || index(allowed, region_names[i]) >= 0) &&
			index(excluded, region_names[i]) < 0) {
			push(result, region_names[i]);
		}
	}
	return result;
};

function display_for_ref(options, kind, ref, fallback) {
	for (let i = 0; i < length(options ?? []); i++) {
		if ((kind == null || options[i]?.kind == kind) && options[i]?.ref == ref)
			return options[i]?.display_name ?? fallback;
	}
	return fallback;
};

export function project(policy, resources) {
	const providers = [];
	const provider_names = sorted_names(policy?.providers);
	for (let i = 0; i < length(provider_names); i++) {
		const id = provider_names[i];
		const provider = policy.providers[id];
		push(providers, {
			id: id,
			display_name: resources?.provider_names?.[id] ?? id,
			enabled: provider.enabled == true,
			role: provider.role,
			billing: provider.billing ?? "subscription"
		});
	}
	const regions = [];
	const region_names = ordered_regions(policy);
	for (let i = 0; i < length(region_names); i++) {
		const id = region_names[i];
		push(regions, {
			id: id,
			display_name: policy.regions[id]?.display_name ?? id,
			flag: policy.regions[id]?.flag ?? null,
			display_order: policy.regions[id]?.display_order ?? null,
			mode: policy.regions[id]?.mode ?? "automatic"
		});
	}
	const capabilities = [];
	const capability_names = sorted_names(policy?.capabilities);
	for (let i = 0; i < length(capability_names); i++) {
		const id = capability_names[i];
		const capability = policy.capabilities[id];
		const base_groups = [];
		const binding_names = keys(policy?.bindings ?? {});
		for (let j = 0; j < length(binding_names); j++) {
			if (policy.bindings[binding_names[j]]?.capability == id)
				push(base_groups, binding_names[j]);
		}
		push(capabilities, {
			id: id,
			display_name: capability.display_name ?? id,
			enabled: capability.enabled == true,
			mode: capability.mode,
			region_ids: allowed_region_ids(policy, capability),
			prefer_region_from: capability.prefer_region_from ?? null,
			base_groups: base_groups
		});
	}
	const policy_source_options = resources?.policy_source_options ?? [];
	const recovery_profile_options = resources?.recovery_profile_options ?? [];
	const healthcheck = policy?.fail_open?.healthcheck ?? {};
	return {
		backend: { id: "nikki-mihomo", display_name: "Nikki + Mihomo" },
		main_enabled: policy?.main?.enabled == true,
		policy_source: {
			kind: policy.policy_source.kind,
			ref: policy.policy_source.ref,
			display_name: display_for_ref(policy_source_options, policy.policy_source.kind,
				policy.policy_source.ref, policy.policy_source.kind == "bundle" ? "NetFleet 内置基础策略" : "当前 Nikki 配置")
		},
		policy_source_options: policy_source_options,
		recovery_profile: {
			ref: policy.recovery_profile.ref,
			display_name: display_for_ref(recovery_profile_options, null, policy.recovery_profile.ref, "当前原生配置")
		},
		recovery_profile_options: recovery_profile_options,
		providers: providers,
		regions: regions,
		capabilities: capabilities,
		automation: {
			enabled: policy?.automation?.enabled == true,
			selection_interval_seconds: policy?.automation?.selection_interval_seconds,
			subscription_refresh_enabled: policy?.automation?.subscription_refresh_enabled == true,
			subscription_refresh_interval_seconds: policy?.automation?.subscription_refresh_interval_seconds
		},
		safety: {
			region_switch_margin_ms: policy?.selection?.region_switch_margin_ms,
			leaf_switch_margin_ms: policy?.selection?.leaf_switch_margin_ms,
			runtime_grace_seconds: policy?.automation?.runtime_grace_seconds,
			latency_url: policy?.checks?.latency?.url,
			path_probe_url: probe_url(policy, healthcheck.path_probe_id),
			guard_probe_url: probe_url(policy, healthcheck.guard_probe_id)
		}
	};
};

export function validate_request(policy, request, resources) {
	const errors = [];
	if (!known_keys(request, ["revision", "policy_source", "recovery_profile_ref", "providers", "regions",
		"capabilities", "automation", "safety"], errors, "request")) {
		return { ok: false, errors: errors };
	}
	if (type(request.revision) != "string" || !match(request.revision, /^[0-9a-f]{64}$/))
		push(errors, "revision must be a sha256 digest");
	if (known_keys(request.policy_source, ["kind", "ref"], errors, "policy_source")) {
		if ((request.policy_source.kind != "bundle" && request.policy_source.kind != "profile") ||
			!nonempty(request.policy_source.ref) ||
			!option_exists(resources?.policy_source_options, request.policy_source.kind, request.policy_source.ref))
			push(errors, "policy_source must reference an available device option");
	}
	if (!nonempty(request.recovery_profile_ref) ||
		!option_exists(resources?.recovery_profile_options, null, request.recovery_profile_ref))
		push(errors, "recovery_profile_ref must reference an available device option");

	if (known_keys(request.providers, sorted_names(policy.providers), errors, "providers")) {
		const names = keys(request.providers);
		for (let i = 0; i < length(names); i++) {
			const value = request.providers[names[i]];
			if (known_keys(value, ["enabled", "role", "billing"], errors, `providers.${names[i]}`)) {
				if (type(value.enabled) != "bool") push(errors, `providers.${names[i]}.enabled must be boolean`);
				if (value.role != "primary" && value.role != "reserve") push(errors, `providers.${names[i]}.role is invalid`);
				if (value.billing != "subscription" && value.billing != "buyout") push(errors, `providers.${names[i]}.billing is invalid`);
			}
		}
	}
	if (known_keys(request.regions, sorted_names(policy.regions), errors, "regions")) {
		const names = keys(request.regions);
		for (let i = 0; i < length(names); i++) {
			const value = request.regions[names[i]];
			if (known_keys(value, ["display_name", "mode"], errors, `regions.${names[i]}`)) {
				if (!nonempty(value.display_name) || length(trim(value.display_name)) > 80)
					push(errors, `regions.${names[i]}.display_name is invalid`);
				if (value.mode != "automatic" && value.mode != "manual_only")
					push(errors, `regions.${names[i]}.mode is invalid`);
			}
		}
	}
	if (known_keys(request.capabilities, sorted_names(policy.capabilities), errors, "capabilities")) {
		const names = keys(request.capabilities);
		for (let i = 0; i < length(names); i++) {
			const value = request.capabilities[names[i]];
			if (known_keys(value, ["enabled", "mode", "region_ids"], errors, `capabilities.${names[i]}`)) {
				if (type(value.enabled) != "bool") push(errors, `capabilities.${names[i]}.enabled must be boolean`);
				if (value.mode != "automatic" && value.mode != "manual") push(errors, `capabilities.${names[i]}.mode is invalid`);
				array_of_known_ids(value.region_ids, policy.regions, errors, `capabilities.${names[i]}.region_ids`);
			}
		}
	}
	if (known_keys(request.automation, ["enabled", "selection_interval_seconds", "subscription_refresh_enabled",
		"subscription_refresh_interval_seconds"], errors, "automation")) {
		if (type(request.automation.enabled) != "bool" ||
			type(request.automation.subscription_refresh_enabled) != "bool")
			push(errors, "automation switches must be boolean");
		if (type(request.automation.selection_interval_seconds) != "int" ||
			request.automation.selection_interval_seconds < 300 || request.automation.selection_interval_seconds > 86400)
			push(errors, "selection_interval_seconds must be between 300 and 86400");
		if (type(request.automation.subscription_refresh_interval_seconds) != "int" ||
			request.automation.subscription_refresh_interval_seconds < 3600 ||
			request.automation.subscription_refresh_interval_seconds > 604800)
			push(errors, "subscription_refresh_interval_seconds must be between 3600 and 604800");
	}
	if (known_keys(request.safety, ["region_switch_margin_ms", "leaf_switch_margin_ms", "runtime_grace_seconds",
		"latency_url", "path_probe_url", "guard_probe_url"], errors, "safety")) {
		if (type(request.safety.region_switch_margin_ms) != "int" || request.safety.region_switch_margin_ms < 0 ||
			request.safety.region_switch_margin_ms > 5000 || type(request.safety.leaf_switch_margin_ms) != "int" ||
			request.safety.leaf_switch_margin_ms < 0 || request.safety.leaf_switch_margin_ms > 5000)
			push(errors, "selection margins must be integers from 0 to 5000");
		if (type(request.safety.runtime_grace_seconds) != "int" || request.safety.runtime_grace_seconds < 15 ||
			request.safety.runtime_grace_seconds > 300)
			push(errors, "runtime_grace_seconds must be between 15 and 300");
		for (let i = 0; i < 3; i++) {
			const field = ["latency_url", "path_probe_url", "guard_probe_url"][i];
			if (!nonempty(request.safety[field]) || index(request.safety[field], "https://") != 0)
				push(errors, `safety.${field} must use https`);
		}
	}
	return { ok: length(errors) == 0, errors: errors };
};

export function apply(policy, request, resources) {
	const request_validation = validate_request(policy, request, resources);
	if (!request_validation.ok) return { ok: false, errors: request_validation.errors };
	const next = clone(policy);
	next.policy_source = clone(request.policy_source);
	next.recovery_profile.ref = request.recovery_profile_ref;
	let names = keys(request.providers);
	for (let i = 0; i < length(names); i++) {
		next.providers[names[i]].enabled = request.providers[names[i]].enabled;
		next.providers[names[i]].role = request.providers[names[i]].role;
		next.providers[names[i]].billing = request.providers[names[i]].billing;
	}
	names = keys(request.regions);
	for (let i = 0; i < length(names); i++) {
		next.regions[names[i]].display_name = trim(request.regions[names[i]].display_name);
		next.regions[names[i]].mode = request.regions[names[i]].mode;
	}
	const region_names = ordered_regions(next);
	names = keys(request.capabilities);
	for (let i = 0; i < length(names); i++) {
		const id = names[i];
		const selected = request.capabilities[id].region_ids;
		const excluded = [];
		for (let j = 0; j < length(region_names); j++) {
			if (index(selected, region_names[j]) < 0) push(excluded, region_names[j]);
		}
		next.capabilities[id].enabled = request.capabilities[id].enabled;
		next.capabilities[id].mode = request.capabilities[id].mode;
		next.capabilities[id].allowed_regions = null;
		next.capabilities[id].excluded_regions = length(excluded) > 0 ? excluded : null;
	}
	next.automation.enabled = request.automation.enabled;
	next.automation.selection_interval_seconds = request.automation.selection_interval_seconds;
	next.automation.subscription_refresh_enabled = request.automation.subscription_refresh_enabled;
	next.automation.subscription_refresh_interval_seconds = request.automation.subscription_refresh_interval_seconds;
	next.selection.region_switch_margin_ms = request.safety.region_switch_margin_ms;
	next.selection.leaf_switch_margin_ms = request.safety.leaf_switch_margin_ms;
	next.automation.runtime_grace_seconds = request.safety.runtime_grace_seconds;
	next.checks.latency.url = request.safety.latency_url;
	set_probe_url(next, next.fail_open.healthcheck.path_probe_id, request.safety.path_probe_url);
	set_probe_url(next, next.fail_open.healthcheck.guard_probe_id, request.safety.guard_probe_url);
	const validation = validate_policy(next);
	return validation.ok ? { ok: true, policy: next } : { ok: false, errors: validation.errors };
};

function add_change(result, scope, id, field, before, after) {
	if (sprintf("%J", before) != sprintf("%J", after))
		push(result, { scope: scope, id: id ?? null, field: field, before: before ?? null, after: after ?? null });
};

export function changes(before, after, resources) {
	const left = project(before, resources);
	const right = project(after, resources);
	const result = [];
	add_change(result, "policy", null, "policy_source", left.policy_source, right.policy_source);
	add_change(result, "policy", null, "recovery_profile", left.recovery_profile, right.recovery_profile);
	const scopes = ["providers", "regions", "capabilities"];
	for (let s = 0; s < length(scopes); s++) {
		const left_items = left[scopes[s]];
		const right_items = right[scopes[s]];
		for (let i = 0; i < length(left_items); i++) {
			const fields = keys(left_items[i]);
			for (let j = 0; j < length(fields); j++) {
				if (fields[j] != "id" && fields[j] != "base_groups" &&
					(fields[j] != "display_name" || scopes[s] == "regions"))
					add_change(result, substr(scopes[s], 0, length(scopes[s]) - 1), left_items[i].id,
						fields[j], left_items[i][fields[j]], right_items[i]?.[fields[j]]);
			}
		}
	}
	const groups = ["automation", "safety"];
	for (let i = 0; i < length(groups); i++) {
		const fields = keys(left[groups[i]]);
		for (let j = 0; j < length(fields); j++)
			add_change(result, groups[i], null, fields[j], left[groups[i]][fields[j]], right[groups[i]][fields[j]]);
	}
	return result;
};
