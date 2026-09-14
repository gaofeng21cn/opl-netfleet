

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let enable_precondition, is_active, recovery_owner, preferred_runtime_ready, add_runtime_group, expected_runtime_groups, expected_runtime_residue_groups, recovery_profile, passthrough_outcome;



enable_precondition = function(current_profile, recovery_profile, manifest) {
	if (current_profile != recovery_profile) {
		return { ok: false, error: "recovery_profile_changed" };
	}
	if (manifest?.kind != "opl-netfleet-manifest" || manifest?.state != "staged" ||
		manifest?.provider_mode != "file-provider" || manifest?.schema_version != 2 ||
		type(manifest?.artifact_sha256) != "string" ||
		!match(manifest.artifact_sha256, /^[0-9a-f]{64}$/) ||
		manifest?.recovery_profile?.ref != recovery_profile) {
		return { ok: false, error: "invalid_staged_manifest" };
	}
	return { ok: true };
};

is_active = function(current_profile) {
	return current_profile == "file:OPL-NetFleet.json" ||
		current_profile == "file:opl-netfleet/mvp.json";
};

function operating_mode(owner) {
	const compatibility_stopped = owner.compatibility?.running != true && owner.compatibility?.enabled != true;
	if (owner.backend_enabled == false && owner.mihomo_running == false &&
		owner.cleanup?.ok == true && owner.supervisor?.running == false && owner.supervisor?.enabled == false && compatibility_stopped) return "openwrt";
	if (owner.backend_enabled != true || owner.mihomo_running != true || owner.controller_available != true) return null;
	if (owner.active == true && owner.netfleet_present == true &&
		owner.supervisor?.running == true && owner.supervisor?.enabled == true) return "netfleet";
	if (type(owner.profile) == "string" && !is_active(owner.profile) && owner.netfleet_present == false &&
		owner.supervisor?.running == false && owner.supervisor?.enabled == false && compatibility_stopped) return "mihomo";
	return null;
};

recovery_owner = function(current_profile, previous_profile, runtime_netfleet_present) {
	return is_active(current_profile) || is_active(previous_profile) ||
		runtime_netfleet_present == true;
};

preferred_runtime_ready = function(runtime, choice) {
	return runtime?.user_mode == "automatic" &&
		runtime?.data_path == "preferred" &&
		runtime?.selected_group == choice &&
		type(runtime?.leaf) == "string" && length(runtime.leaf) > 0 &&
		runtime?.alive == true;
};

add_runtime_group = function(result, seen, value) {
	if (type(value) != "string" || length(value) == 0 || value == "DIRECT" || seen[value] == true) {
		return;
	}
	seen[value] = true;
	push(result, value);
};

expected_runtime_groups = function(manifest) {
	const result = [];
	const seen = {};
	const generated = manifest?.generated_groups ?? {};
	const capability_names = keys(generated);
	for (let i = 0; i < length(capability_names); i++) {
		const entry = generated[capability_names[i]];
		add_runtime_group(result, seen, entry?.name);
		add_runtime_group(result, seen, entry?.automatic_name);
		add_runtime_group(result, seen, entry?.selector_name);
		add_runtime_group(result, seen, entry?.proxy_path_name);
		add_runtime_group(result, seen, entry?.direct_guard_name);
		const user_members = entry?.user_members ?? [];
		for (let j = 0; j < length(user_members); j++) add_runtime_group(result, seen, user_members[j]);
		const regions = entry?.region_groups ?? [];
		for (let j = 0; j < length(regions); j++) {
			add_runtime_group(result, seen, regions[j]?.name);
			add_runtime_group(result, seen, regions[j]?.primary_name);
			add_runtime_group(result, seen, regions[j]?.reserve_name);
		}
		const providers = entry?.providers ?? {};
		const provider_names = keys(providers);
		for (let j = 0; j < length(provider_names); j++) {
			add_runtime_group(result, seen, providers[provider_names[j]]?.group);
		}
		const candidates = entry?.candidate_groups ?? [];
		for (let j = 0; j < length(candidates); j++) {
			add_runtime_group(result, seen, candidates[j]?.name);
			add_runtime_group(result, seen, candidates[j]?.group);
		}
	}
	return result;
};

expected_runtime_residue_groups = function(manifest, recovery_groups) {
	const native = {};
	for (let i = 0; i < length(recovery_groups ?? []); i++) {
		const name = recovery_groups[i];
		if (type(name) == "string" && length(name) > 0) native[name] = true;
	}
	const expected = expected_runtime_groups(manifest);
	const result = [];
	for (let i = 0; i < length(expected); i++) {
		if (native[expected[i]] != true) push(result, expected[i]);
	}
	return result;
};

recovery_profile = function(manifest, artifact_sha256, active_profile, recovery_sha256) {
	const recovery = manifest?.recovery_profile?.ref;
	if (manifest?.kind != "opl-netfleet-manifest" || manifest?.state != "staged" ||
		manifest?.provider_mode != "file-provider" || manifest?.schema_version != 2 ||
		type(manifest?.artifact_sha256) != "string" ||
		!match(manifest.artifact_sha256, /^[0-9a-f]{64}$/) ||
		type(manifest?.recovery_profile?.sha256) != "string" ||
		!match(manifest.recovery_profile.sha256, /^[0-9a-f]{64}$/) ||
		manifest.artifact_sha256 != artifact_sha256 ||
		manifest.recovery_profile.sha256 != recovery_sha256 || type(recovery) != "string" ||
		is_active(recovery) ||
		(index(recovery, "subscription:") != 0 && index(recovery, "file:") != 0)) {
		return null;
	}
	return recovery;
};

// Cleanup safety, next-start persistence, and business reachability are
// independent facts.  A direct probe failure must not invalidate an already
// safe/durable passthrough, while missing persistence must remain a real
// recovery failure because the next Nikki start could select the bad artifact.
passthrough_outcome = function(cleanup, persistent, business_ok) {
	const safe = cleanup?.ok == true;
	const durable = persistent == true;
	let business = null;
	if (business_ok == true) {
		business = true;
	} else if (business_ok == false) {
		business = false;
	}
	return {
		ok: safe && durable,
		safe: safe,
		persistent: durable,
		durable: durable,
		business_ok: business
	};
};

return { enable_precondition, is_active, operating_mode, recovery_owner, preferred_runtime_ready, expected_runtime_groups, expected_runtime_residue_groups, recovery_profile, passthrough_outcome };
};
