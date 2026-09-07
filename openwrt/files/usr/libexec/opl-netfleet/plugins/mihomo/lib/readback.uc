

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let recovery_runtime_groups, state_has_netfleet, runtime_readback;

const resolve_profile = context.use("mihomo.backend").resolve_profile;
const ARTIFACT_PATH = context.use("mihomo.backend").ARTIFACT_PATH;
const running = context.use("mihomo.backend").running;
const proxies = context.use("mihomo.controller").proxies;
const test_runtime = context.use("mihomo.controller").test_runtime;
const is_active = context.use("models.activation").is_active;
const expected_runtime_groups = context.use("models.activation").expected_runtime_groups;
const expected_runtime_residue_groups = context.use("models.activation").expected_runtime_residue_groups;
const sha256 = context.use("platform.storage").sha256;
const read_yaml = context.use("platform.storage").read_yaml;
const api_secret = context.use("platform.credentials").api_secret;
const current_profile = context.use("platform.profile").current_profile;

recovery_runtime_groups = function(profile, manifest) {
	const recovery = manifest?.recovery_profile;
	const path = resolve_profile(profile);
	if (is_active(profile) || path == null || recovery?.ref != profile ||
		type(recovery?.sha256) != "string" || sha256(path) != recovery.sha256) return [];
	const source = read_yaml(path);
	const groups = source?.["proxy-groups"] ?? [];
	const result = [];
	for (let i = 0; i < length(groups); i++) {
		const name = groups[i]?.name;
		if (type(name) == "string" && length(name) > 0) push(result, name);
	}
	return result;
};

state_has_netfleet = function(state, manifest, profile) {
	const current = state?.proxies ?? {};
	const expected = is_active(profile) ? expected_runtime_groups(manifest) :
		expected_runtime_residue_groups(manifest, recovery_runtime_groups(profile, manifest));
	for (let i = 0; i < length(expected); i++) {
		if (current[expected[i]] != null) return true;
	}
	return false;
};

runtime_readback = function(profile, manifest) {
	const secret = api_secret();
	const proxy_state = secret ? proxies(secret) : null;
	const current = proxy_state?.proxies ?? {};
	const selected = {};
	const expected = expected_runtime_groups(manifest);
	const residue = is_active(profile) ? expected :
		expected_runtime_residue_groups(manifest, recovery_runtime_groups(profile, manifest));
	const expected_set = {};
	let present_count = 0;
	let missing_count = 0;
	let residue_present_count = 0;
	for (let i = 0; i < length(expected); i++) {
		expected_set[expected[i]] = true;
		if (current[expected[i]] != null) {
			present_count++;
			selected[expected[i]] = current[expected[i]]?.now ?? null;
		} else {
			missing_count++;
		}
	}
	for (let i = 0; i < length(residue); i++) {
		if (current[residue[i]] != null) residue_present_count++;
	}
	const unexpected_netfleet = false;
	const profile_match = current_profile() == profile;
	const manifest_valid = manifest?.kind == "opl-netfleet-manifest" &&
		manifest?.schema_version == 2 && type(manifest?.artifact_sha256) == "string" &&
		match(manifest.artifact_sha256, /^[0-9a-f]{64}$/);
	const artifact_identity_ok = !is_active(profile) ||
		(manifest_valid && sha256(ARTIFACT_PATH) == manifest.artifact_sha256);
	const generated_complete = length(expected) > 0 && missing_count == 0;
	const netfleet_present = residue_present_count > 0 || unexpected_netfleet;
	return {
		profile: profile,
		profile_match: profile_match,
		mihomo_running: running(),
		mihomo_config_valid: test_runtime(),
		state_available: proxy_state?.proxies != null,
		netfleet_present: netfleet_present,
		generated_complete: generated_complete,
		unexpected_netfleet: unexpected_netfleet,
		expected_group_count: length(expected),
		present_group_count: present_count,
		missing_group_count: missing_count,
		residue_group_count: length(residue),
		residue_present_count: residue_present_count,
		artifact_identity_ok: artifact_identity_ok,
		runtime_identity_ok: profile_match && artifact_identity_ok &&
			(is_active(profile) ? generated_complete && !unexpected_netfleet : !netfleet_present),
		selected: selected
	};
};

return { recovery_runtime_groups, state_has_netfleet, runtime_readback };
};
