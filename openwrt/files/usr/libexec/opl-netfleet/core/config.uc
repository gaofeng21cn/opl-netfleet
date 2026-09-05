import { validate as validate_policy, ordered_regions } from "./policy.uc";

function object(value) {
	return type(value) == "object";
};

function nonempty(value) {
	return type(value) == "string" && length(trim(value)) > 0;
};

function stable_id(value) {
	return nonempty(value) && match(value, /^[A-Za-z0-9][A-Za-z0-9_-]*$/);
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

function option_by_id(options, id) {
	for (let i = 0; i < length(options ?? []); i++) {
		if (options[i]?.id == id) return options[i];
	}
	return null;
};

function source_groups(resources, source) {
	const key = `${source?.kind ?? ""}|${source?.ref ?? ""}`;
	return resources?.policy_source_groups?.[key] ?? [];
};

function joined(values, extra) {
	const result = [];
	for (let i = 0; i < length(values ?? []); i++) push(result, values[i]);
	for (let i = 0; i < length(extra ?? []); i++) push(result, extra[i]);
	return result;
};

function next_display_order(items) {
	let highest = 0;
	const names = keys(items ?? {});
	for (let i = 0; i < length(names); i++) {
		const value = items[names[i]]?.display_order;
		if (type(value) == "int" && value > highest) highest = value;
	}
	return highest + 10;
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
		const region_ids = map(policy?.provider_regions?.[id] ?? [], entry => entry.region);
		push(providers, {
			id: id,
			display_name: resources?.provider_names?.[id] ?? id,
			section: provider.section,
			enabled: provider.enabled == true,
			role: provider.role,
			billing: provider.billing ?? "subscription",
			region_ids: region_ids
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
		let entry_group = null;
		const policy_groups = [];
		const binding_names = keys(policy?.bindings ?? {});
		for (let j = 0; j < length(binding_names); j++) {
			const binding = policy.bindings[binding_names[j]];
			if (binding?.capability != id) continue;
			if (binding.kind == "entry") entry_group = binding_names[j];
			else push(policy_groups, binding_names[j]);
		}
		push(capabilities, {
			id: id,
			display_name: capability.display_name ?? id,
			enabled: capability.enabled == true,
			mode: capability.mode,
			region_ids: allowed_region_ids(policy, capability),
			prefer_region_from: capability.prefer_region_from ?? null,
			entry_group: entry_group,
			policy_groups: policy_groups,
			base_groups: entry_group == null ? policy_groups : joined([entry_group], policy_groups)
		});
	}
	const policy_source_options = resources?.policy_source_options ?? [];
	const recovery_profile_options = resources?.recovery_profile_options ?? [];
	const healthcheck = policy?.fail_open?.healthcheck ?? {};
	return {
		backend: resources?.backend ?? { id: "nikki-mihomo", display_name: "Nikki + Mihomo" },
		main_enabled: policy?.main?.enabled == true,
		policy_source: {
			kind: policy.policy_source.kind,
			ref: policy.policy_source.ref,
			display_name: display_for_ref(policy_source_options, policy.policy_source.kind,
				policy.policy_source.ref, policy.policy_source.kind == "bundle" ? "NetFleet 内置基础策略" : "当前基础配置")
		},
		policy_source_options: policy_source_options,
		policy_groups: source_groups(resources, policy.policy_source),
		recovery_profile: {
			ref: policy.recovery_profile.ref,
			display_name: display_for_ref(recovery_profile_options, null, policy.recovery_profile.ref, "当前原生配置")
		},
		recovery_profile_options: recovery_profile_options,
		providers: providers,
		provider_options: map(resources?.provider_options ?? [], option => ({
			id: option.id,
			section: option.section,
			display_name: option.display_name,
			region_ids: option.region_ids ?? []
		})),
		regions: regions,
		region_options: map(resources?.region_options ?? [], option => ({
			id: option.id,
			code: option.code,
			display_name: option.display_name,
			display_order: option.display_order
		})),
		capabilities: capabilities,
		routing_rules: clone(policy?.routing_rules ?? []),
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
		"capabilities", "routing_rules", "automation", "safety"], errors, "request")) {
		return { ok: false, errors: errors };
	}
	const requested_source = object(request.policy_source) ? request.policy_source : {};
	const requested_automation = object(request.automation) ? request.automation : {};
	const requested_safety = object(request.safety) ? request.safety : {};
	if (type(request.revision) != "string" || !match(request.revision, /^[0-9a-f]{64}$/))
		push(errors, "revision must be a sha256 digest");
	if (known_keys(request.policy_source, ["kind", "ref"], errors, "policy_source")) {
		if ((requested_source.kind != "bundle" && requested_source.kind != "profile") ||
			!nonempty(requested_source.ref) ||
			!option_exists(resources?.policy_source_options, requested_source.kind, requested_source.ref))
			push(errors, "policy_source must reference an available device option");
	}
	if (!nonempty(request.recovery_profile_ref) ||
		!option_exists(resources?.recovery_profile_options, null, request.recovery_profile_ref))
		push(errors, "recovery_profile_ref must reference an available device option");

	const requested_regions = object(request.regions) ? request.regions : {};
	if (object(request.providers)) {
		const names = keys(request.providers);
		for (let i = 0; i < length(names); i++) {
			const id = names[i];
			const value = request.providers[names[i]];
			const existing = policy?.providers?.[id];
			const available = option_by_id(resources?.provider_options, id);
			if (!stable_id(id)) push(errors, `provider id is invalid: ${id}`);
			if (existing == null && (available == null || available.section != id))
				push(errors, `provider must reference an available subscription: ${id}`);
			if (known_keys(value, ["section", "enabled", "role", "billing", "region_ids"], errors, `providers.${id}`)) {
				if (!nonempty(value.section) || (existing != null && value.section != existing.section) ||
					(existing == null && value.section != available?.section))
					push(errors, `providers.${id}.section is not an available immutable section`);
				if (type(value.enabled) != "bool") push(errors, `providers.${names[i]}.enabled must be boolean`);
				if (value.role != "primary" && value.role != "reserve") push(errors, `providers.${names[i]}.role is invalid`);
				if (value.billing != "subscription" && value.billing != "buyout") push(errors, `providers.${names[i]}.billing is invalid`);
				array_of_known_ids(value.region_ids, requested_regions, errors, `providers.${id}.region_ids`);
				for (let j = 0; j < length(value.region_ids ?? []); j++) {
					const region_id = value.region_ids[j];
					const old_mapping = policy?.provider_regions?.[id] ?? [];
					let previously_mapped = false;
					for (let k = 0; k < length(old_mapping); k++) {
						if (old_mapping[k]?.region == region_id) previously_mapped = true;
					}
					if (!previously_mapped && index(available?.region_ids ?? [], region_id) < 0)
						push(errors, `providers.${id}.region_ids contains a region not found in its cache: ${region_id}`);
				}
			}
		}
	} else push(errors, "providers must be an object");
	if (object(request.regions)) {
		const names = keys(request.regions);
		for (let i = 0; i < length(names); i++) {
			const id = names[i];
			const value = request.regions[names[i]];
			if (!stable_id(id) || (policy?.regions?.[id] == null && option_by_id(resources?.region_options, id) == null))
				push(errors, `region must reference the shared catalog: ${id}`);
			if (policy?.regions?.[id] == null) {
				let mapped = false;
				const provider_names = keys(request.providers ?? {});
				for (let j = 0; j < length(provider_names); j++) {
					if (index(request.providers[provider_names[j]]?.region_ids ?? [], id) >= 0) mapped = true;
				}
				if (!mapped) push(errors, `region must be mapped by at least one provider: ${id}`);
			}
			if (known_keys(value, ["display_name", "mode"], errors, `regions.${names[i]}`)) {
				if (!nonempty(value.display_name) || length(trim(value.display_name)) > 80)
					push(errors, `regions.${names[i]}.display_name is invalid`);
				if (value.mode != "automatic" && value.mode != "manual_only")
					push(errors, `regions.${names[i]}.mode is invalid`);
			}
		}
	} else push(errors, "regions must be an object");
	if (object(request.capabilities)) {
		const claimed_groups = {};
		const names = keys(request.capabilities);
		for (let i = 0; i < length(names); i++) {
			const id = names[i];
			const value = request.capabilities[names[i]];
			if (!stable_id(id)) push(errors, `capability id is invalid: ${id}`);
			if (known_keys(value, ["display_name", "enabled", "mode", "region_ids", "prefer_region_from", "entry_group", "policy_groups"], errors, `capabilities.${id}`)) {
				if (!nonempty(value.display_name) || length(trim(value.display_name)) > 80)
					push(errors, `capabilities.${id}.display_name is invalid`);
				if (type(value.enabled) != "bool") push(errors, `capabilities.${names[i]}.enabled must be boolean`);
				if (value.mode != "automatic" && value.mode != "manual") push(errors, `capabilities.${names[i]}.mode is invalid`);
				array_of_known_ids(value.region_ids, requested_regions, errors, `capabilities.${names[i]}.region_ids`);
				if (value.prefer_region_from != null && (!stable_id(value.prefer_region_from) ||
					request.capabilities?.[value.prefer_region_from] == null))
					push(errors, `capabilities.${id}.prefer_region_from is invalid`);
				if (value.entry_group != null && (type(value.entry_group) != "string" ||
					index(source_groups(resources, requested_source), value.entry_group) < 0))
					push(errors, `capabilities.${id}.entry_group is unavailable`);
				if (value.enabled == true && value.entry_group == null)
					push(errors, `capabilities.${id}.entry_group is required when enabled`);
				if (value.entry_group != null) {
					if (claimed_groups[value.entry_group] != null)
						push(errors, `policy group is assigned more than once: ${value.entry_group}`);
					claimed_groups[value.entry_group] = id;
				}
				if (type(value.policy_groups) != "array") push(errors, `capabilities.${id}.policy_groups must be an array`);
				for (let j = 0; j < length(value.policy_groups ?? []); j++) {
					const group = value.policy_groups[j];
					if (type(group) != "string" ||
						index(source_groups(resources, requested_source), group) < 0)
						push(errors, `capabilities.${id}.policy_groups contains an unavailable group`);
					else {
						if (claimed_groups[group] != null)
							push(errors, `policy group is assigned more than once: ${group}`);
						claimed_groups[group] = id;
					}
				}
			}
		}
	} else push(errors, "capabilities must be an object");
	if (type(request.routing_rules) != "array") push(errors, "routing_rules must be an array");
	else {
		for (let i = 0; i < length(request.routing_rules); i++) {
			const rule = request.routing_rules[i];
			if (!known_keys(rule, ["kind", "value", "capability"], errors, `routing_rules.${i}`)) continue;
			if (rule.kind != "domain_suffix" || !nonempty(rule.value) || !stable_id(rule.capability) ||
				request.capabilities?.[rule.capability] == null)
				push(errors, `routing_rules.${i} is invalid`);
		}
	}
	if (known_keys(request.automation, ["enabled", "selection_interval_seconds", "subscription_refresh_enabled",
		"subscription_refresh_interval_seconds"], errors, "automation")) {
		if (type(requested_automation.enabled) != "bool" ||
			type(requested_automation.subscription_refresh_enabled) != "bool")
			push(errors, "automation switches must be boolean");
		if (type(requested_automation.selection_interval_seconds) != "int" ||
			requested_automation.selection_interval_seconds < 300 || requested_automation.selection_interval_seconds > 86400)
			push(errors, "selection_interval_seconds must be between 300 and 86400");
		if (type(requested_automation.subscription_refresh_interval_seconds) != "int" ||
			requested_automation.subscription_refresh_interval_seconds < 3600 ||
			requested_automation.subscription_refresh_interval_seconds > 604800)
			push(errors, "subscription_refresh_interval_seconds must be between 3600 and 604800");
	}
	if (known_keys(request.safety, ["region_switch_margin_ms", "leaf_switch_margin_ms", "runtime_grace_seconds",
		"latency_url", "path_probe_url", "guard_probe_url"], errors, "safety")) {
		if (type(requested_safety.region_switch_margin_ms) != "int" || requested_safety.region_switch_margin_ms < 0 ||
			requested_safety.region_switch_margin_ms > 5000 || type(requested_safety.leaf_switch_margin_ms) != "int" ||
			requested_safety.leaf_switch_margin_ms < 0 || requested_safety.leaf_switch_margin_ms > 5000)
			push(errors, "selection margins must be integers from 0 to 5000");
		if (type(requested_safety.runtime_grace_seconds) != "int" || requested_safety.runtime_grace_seconds < 15 ||
			requested_safety.runtime_grace_seconds > 300)
			push(errors, "runtime_grace_seconds must be between 15 and 300");
		for (let i = 0; i < 3; i++) {
			const field = ["latency_url", "path_probe_url", "guard_probe_url"][i];
			if (!nonempty(requested_safety[field]) || index(requested_safety[field], "https://") != 0)
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
	next.regions = {};
	let names = keys(request.regions);
	for (let i = 0; i < length(names); i++) {
		const id = names[i];
		const option = option_by_id(resources?.region_options, id);
		const region = clone(policy?.regions?.[id] ?? {
			flag: option?.code,
			display_order: option?.display_order,
			mode: "automatic"
		});
		region.display_name = trim(request.regions[id].display_name);
		region.mode = request.regions[id].mode;
		next.regions[id] = region;
	}
	next.providers = {};
	next.provider_regions = {};
	names = keys(request.providers);
	for (let i = 0; i < length(names); i++) {
		const id = names[i];
		const requested = request.providers[id];
		const provider = clone(policy?.providers?.[id] ?? {
			section: requested.section,
			quota: { available_field: "avaliable", total_field: "total", used_field: "used" }
		});
		provider.section = requested.section;
		provider.enabled = requested.enabled;
		provider.role = requested.role;
		provider.billing = requested.billing;
		next.providers[id] = provider;
		next.provider_regions[id] = [];
		const old_mappings = policy?.provider_regions?.[id] ?? [];
		for (let j = 0; j < length(requested.region_ids); j++) {
			const region_id = requested.region_ids[j];
			let filter = option_by_id(resources?.region_options, region_id)?.filter;
			for (let k = 0; k < length(old_mappings); k++) {
				if (old_mappings[k]?.region == region_id) filter = old_mappings[k].filter;
			}
			if (!nonempty(filter)) return { ok: false, errors: [`provider region filter is unavailable: ${id}/${region_id}`] };
			push(next.provider_regions[id], { region: region_id, filter: filter });
		}
	}
	const region_names = ordered_regions(next);
	next.capabilities = {};
	next.bindings = {};
	names = sorted_names(request.capabilities);
	let display_order = next_display_order(policy?.capabilities);
	for (let i = 0; i < length(names); i++) {
		const id = names[i];
		const requested = request.capabilities[id];
		const capability = clone(policy?.capabilities?.[id] ?? { display_order: display_order });
		if (policy?.capabilities?.[id] == null) display_order += 10;
		const selected = requested.region_ids;
		const excluded = [];
		for (let j = 0; j < length(region_names); j++) {
			if (index(selected, region_names[j]) < 0) push(excluded, region_names[j]);
		}
		capability.display_name = trim(requested.display_name);
		capability.enabled = requested.enabled;
		capability.mode = requested.mode;
		capability.prefer_region_from = requested.prefer_region_from;
		capability.allowed_regions = null;
		capability.excluded_regions = length(excluded) > 0 ? excluded : null;
		next.capabilities[id] = capability;
		if (requested.entry_group != null)
			next.bindings[requested.entry_group] = { capability: id, kind: "entry" };
		for (let j = 0; j < length(requested.policy_groups); j++)
			next.bindings[requested.policy_groups[j]] = { capability: id, kind: "policy" };
	}
	next.routing_rules = clone(request.routing_rules);
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

function singular_scope(scope) {
	if (scope == "providers") return "provider";
	if (scope == "regions") return "region";
	return "capability";
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
		const left_by_id = {};
		const right_by_id = {};
		for (let i = 0; i < length(left_items); i++) left_by_id[left_items[i].id] = left_items[i];
		for (let i = 0; i < length(right_items); i++) right_by_id[right_items[i].id] = right_items[i];
		const ids = sorted_names(left_by_id);
		const right_ids = sorted_names(right_by_id);
		for (let i = 0; i < length(right_ids); i++) {
			if (!has(left_by_id, right_ids[i])) push(ids, right_ids[i]);
		}
		for (let i = 0; i < length(ids); i++) {
			const id = ids[i];
			if (!has(left_by_id, id) || !has(right_by_id, id)) {
				add_change(result, singular_scope(scopes[s]), id,
					"item", left_by_id[id] ?? null, right_by_id[id] ?? null);
				continue;
			}
			const fields = keys(left_by_id[id]);
			for (let j = 0; j < length(fields); j++) {
				if (fields[j] != "id" && fields[j] != "base_groups" && fields[j] != "section" &&
					(fields[j] != "display_name" || scopes[s] != "providers"))
					add_change(result, singular_scope(scopes[s]), id,
						fields[j], left_by_id[id][fields[j]], right_by_id[id][fields[j]]);
			}
		}
	}
	add_change(result, "policy", null, "routing_rules", left.routing_rules, right.routing_rules);
	const groups = ["automation", "safety"];
	for (let i = 0; i < length(groups); i++) {
		const fields = keys(left[groups[i]]);
		for (let j = 0; j < length(fields); j++)
			add_change(result, groups[i], null, fields[j], left[groups[i]][fields[j]], right[groups[i]][fields[j]]);
	}
	return result;
};
