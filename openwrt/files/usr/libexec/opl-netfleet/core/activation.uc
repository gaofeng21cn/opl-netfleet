export function enable_precondition(current_profile, recovery_profile, manifest) {
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

export function is_active(current_profile) {
	return current_profile == "file:OPL-NetFleet.json" ||
		current_profile == "file:opl-netfleet/mvp.json";
};

export function recovery_owner(current_profile, previous_profile, runtime_netfleet_present) {
	return is_active(current_profile) || is_active(previous_profile) ||
		runtime_netfleet_present == true;
};

export function preferred_runtime_ready(runtime, choice) {
	return runtime?.user_mode == "automatic" &&
		runtime?.data_path == "preferred" &&
		runtime?.selected_group == choice &&
		type(runtime?.leaf) == "string" && length(runtime.leaf) > 0 &&
		runtime?.alive == true;
};

function add_runtime_group(result, seen, value) {
	if (type(value) != "string" || length(value) == 0 || value == "DIRECT" || seen[value] == true) {
		return;
	}
	seen[value] = true;
	push(result, value);
};

export function expected_runtime_groups(manifest) {
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

export function expected_runtime_residue_groups(manifest, recovery_groups) {
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

export function recovery_profile(manifest, artifact_sha256, active_profile, recovery_sha256) {
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
export function passthrough_outcome(cleanup, persistent, business_ok) {
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
