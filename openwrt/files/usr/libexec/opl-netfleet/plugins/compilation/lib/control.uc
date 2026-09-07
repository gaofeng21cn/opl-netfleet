

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let compile_result, compile_action, package_cleanup_action, command_compile, command_package_cleanup, command_validate_schema, command_validate;

const compile_profile = context.use("compilation.compiler").compile;
const fail = context.use("events.output").fail;
const ok = context.use("events.output").ok;
const resolve_profile = context.use("mihomo.backend").resolve_profile;
const prepare_provider_links = context.use("mihomo.backend").prepare_provider_links;
const remove_provider_links = context.use("mihomo.backend").remove_provider_links;
const test_profile_object = context.use("mihomo.backend").test_profile_object;
const install_artifact = context.use("mihomo.backend").install_artifact;
const ARTIFACT_PATH = context.use("mihomo.backend").ARTIFACT_PATH;
const MANIFEST_PATH = context.use("mihomo.backend").MANIFEST_PATH;
const remove_artifact = context.use("mihomo.backend").remove_artifact;
const test_profile = context.use("mihomo.controller").test_profile;
const resolve_policy_source = context.use("mihomo.policy-source").resolve;
const load_policy_source = context.use("mihomo.policy-source").load;
const is_active = context.use("models.activation").is_active;
const load_policy = context.use("platform.documents").load_policy;
const current_profile = context.use("platform.uci").current_profile;
const shell_quote = context.use("platform.uci").shell_quote;
const sha256 = context.use("platform.uci").sha256;
const POLICY_PATH = context.use("platform.uci").POLICY_PATH;
const read_json = context.use("platform.uci").read_json;
const policy_provider_profiles = context.use("subscriptions.facts").policy_provider_profiles;
const manifest_provider_profiles = context.use("subscriptions.facts").manifest_provider_profiles;
const require_provider_profiles = context.use("subscriptions.facts").require_provider_profiles;
const load_provider_profile_result = context.use("subscriptions.providers").load;

compile_result = function(policy, allow_active) {
	if (system("printf '{}' | yq -M -p yaml -o json >/dev/null 2>&1") != 0)
		return { ok: false, error: "yaml_reader_unavailable" };
	const current = current_profile();
	if (is_active(current) && allow_active != true) {
		return { ok: false, error: "active_profile_requires_disable", detail: current };
	}
	const source_path = resolve_policy_source(policy.policy_source);
	if (source_path == null || system(`test -f ${shell_quote(source_path)}`) != 0) {
		return { ok: false, error: "policy_source_missing", detail: policy.policy_source.ref };
	}
	const baseline = load_policy_source(policy.policy_source);
	if (baseline == null) {
		return { ok: false, error: "policy_source_unreadable", detail: source_path };
	}
	const recovery_path = resolve_profile(policy.recovery_profile.ref);
	if (recovery_path == null || system(`test -f ${shell_quote(recovery_path)}`) != 0) {
		return { ok: false, error: "recovery_profile_missing", detail: policy.recovery_profile.ref };
	}
	const provider_result = load_provider_profile_result(policy);
	if (!provider_result.ok) {
		return provider_result;
	}
	const provider_profiles = provider_result.profiles;
	const result = compile_profile(baseline, policy, sha256(source_path), sha256(recovery_path),
		sha256(POLICY_PATH), provider_profiles);
	if (!result.ok) {
		return { ok: false, error: "compile_rejected", detail: result.errors };
	}
	if (!prepare_provider_links(provider_profiles)) {
		// A partially prepared SAFE_PATH must not survive a failed compile.  The
		// active Nikki profile is untouched, but stale links would contaminate a
		// later staged attempt.
		if (allow_active != true) remove_provider_links(provider_profiles);
		return { ok: false, error: "provider_link_prepare_failed", detail: null };
	}
	if (!test_profile_object(result.profile)) {
		if (allow_active != true) remove_provider_links(provider_profiles);
		return { ok: false, error: "staged_profile_test_failed", detail: null };
	}
	if (!install_artifact(result.profile, result.manifest) || !test_profile(ARTIFACT_PATH)) {
		if (allow_active != true) remove_provider_links(provider_profiles);
		return { ok: false, error: "staged_readback_failed", detail: null };
	}
	return { ok: true, result: {
		state: "staged",
		artifact: ARTIFACT_PATH,
		manifest: MANIFEST_PATH,
		policy_source: policy.policy_source,
		recovery_profile: policy.recovery_profile.ref,
		binding_count: length(keys(policy.bindings))
	} };
};

compile_action = function(policy) {
	const result = compile_result(policy, false);
	if (!result.ok) {
		fail("compile", result.error, result.detail);
	}
	ok("compile", result.result);
};

package_cleanup_action = function() {
	const profile = current_profile();
	if (is_active(profile)) {
		fail("package-cleanup", "netfleet_profile_active", { profile: profile });
	}
	const policy = load_policy();
	const manifest = read_json(MANIFEST_PATH);
	const policy_links_removed = policy == null || remove_provider_links(policy_provider_profiles(policy));
	const manifest_links_removed = manifest == null || remove_provider_links(manifest_provider_profiles(manifest));
	if (!policy_links_removed || !manifest_links_removed) {
		fail("package-cleanup", "provider_link_cleanup_failed", null);
	}
	if (!remove_artifact()) {
		fail("package-cleanup", "artifact_cleanup_failed", null);
	}
	ok("package-cleanup", { profile: profile, artifact_removed: true });
};

command_compile = function(argv) {
	const policy = load_policy();
	if (policy == null) fail(argv[0], "policy_unreadable", POLICY_PATH);
	compile_action(policy);
};

command_package_cleanup = function(argv) {
	package_cleanup_action();
};

command_validate_schema = function(argv) {
	const policy_path = argv[1] ?? POLICY_PATH;
	const policy = load_policy(policy_path);
	if (policy == null) fail("validate-schema", "policy_unreadable", policy_path);
	ok("validate-schema", { policy_schema: policy.schema_version });
};

command_validate = function(argv) {
	const policy_path = argv[1] ?? POLICY_PATH;
	const policy = load_policy(policy_path);
	if (policy == null) fail("validate", "policy_unreadable", policy_path);
	const source_path = resolve_policy_source(policy.policy_source);
	if (source_path == null || system(`test -f ${shell_quote(source_path)}`) != 0) {
		fail("validate", "policy_source_missing", policy.policy_source.ref);
	}
	const baseline = load_policy_source(policy.policy_source);
	const recovery_path = resolve_profile(policy.recovery_profile.ref);
	if (recovery_path == null || system(`test -f ${shell_quote(recovery_path)}`) != 0) {
		fail("validate", "recovery_profile_missing", policy.recovery_profile.ref);
	}
	const provider_profiles = require_provider_profiles(policy, "validate");
	const result = compile_profile(baseline, policy, sha256(source_path), sha256(recovery_path),
		sha256(policy_path), provider_profiles);
	if (!result.ok) {
		fail("validate", "compile_rejected", result.errors);
	}
	ok("validate", { current_profile: current_profile(), policy_source: policy.policy_source,
		recovery_profile: policy.recovery_profile.ref, would_generate: true });
};

return { compile_result, compile_action, package_cleanup_action, command_compile, command_package_cleanup, command_validate_schema, command_validate };
};
