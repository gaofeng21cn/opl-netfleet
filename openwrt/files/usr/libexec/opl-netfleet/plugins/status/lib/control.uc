

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let normalized_build, installed_build, status_action, profile_display_name, command_status;

const ok = context.use("events.output").ok;
const fail = context.use("events.output").fail;
const MANIFEST_PATH = context.use("mihomo.backend").MANIFEST_PATH;
const running = context.use("mihomo.backend").running;
const cleanup_state = context.use("mihomo.backend").cleanup_state;
const lan_runtime_state = context.use("mihomo.backend").lan_runtime_state;
const proxies = context.use("mihomo.controller").proxies;
const proxy_providers = context.use("mihomo.controller").proxy_providers;
const state_has_netfleet = context.use("mihomo.readback").state_has_netfleet;
const is_active = context.use("models.activation").is_active;
const automation_config = context.use("models.policy").automation;
const build_status = context.use("models.status").build;
const load_policy = context.use("platform.documents").load_policy;
const load_evidence = context.use("platform.documents").load_evidence;
const backend_metadata = context.use("platform.runtime").metadata;
const service_state = context.use("platform.service").service_state;
const read_json = context.use("platform.storage").read_json;
const current_profile = context.use("platform.profile").current_profile;
const api_secret = context.use("platform.credentials").api_secret;
const backend_enabled = context.use("platform.profile").backend_enabled;
const subscription_display_name = context.use("platform.subscriptions").subscription_display_name;
const POLICY_PATH = context.use("platform.paths").POLICY_PATH;
const pending_recovery = context.use("recovery.state").pending;
const provider_quotas = context.use("subscriptions.facts").provider_quotas;
const provider_display_names = context.use("subscriptions.facts").provider_display_names;
const subscription_refresh_projection = context.use("subscriptions.facts").subscription_refresh_projection;

const INSTALLED_IDENTITY_PATH = "/etc/opl-netfleet/installed.json";
const PACKAGE_BUILD_PATH = "/usr/share/opl-netfleet/build.json";
normalized_build = function(identity, version_field) {
	const version = type(identity) == "object" ? identity[version_field] : null;
	const commit = identity?.source_commit;
	const tree = identity?.source_tree;
	if (type(version) != "string" || !match(version, /^[0-9][0-9A-Za-z.+~-]*$/) ||
		type(commit) != "string" || !match(commit, /^[0-9a-f]{40}$/) ||
		type(tree) != "string" || !match(tree, /^[0-9a-f]{40}$/)) return null;
	return { version: version, source_commit: commit, source_tree: tree };
};

installed_build = function() {
	const packaged = normalized_build(read_json(PACKAGE_BUILD_PATH), "version");
	if (packaged != null) return packaged;
	const deployed = normalized_build(read_json(INSTALLED_IDENTITY_PATH), "product_version");
	return deployed ?? { version: null, source_commit: null, source_tree: null };
};

status_action = function(policy, evidence) {
	const profile = current_profile();
	const manifest = read_json(MANIFEST_PATH);
	const secret = api_secret();
	const state = secret ? proxies(secret, 1) : null;
	if (state != null) {
		state.providers = proxy_providers(secret, 1)?.providers ?? null;
	}
	const enabled = backend_enabled();
	const mihomo_running = running();
	let cleanup = null;
	if (enabled == false || !mihomo_running) {
		try {
			cleanup = cleanup_state();
		} catch (error) {
			cleanup = { ok: false, error: "cleanup_readback_error" };
		}
	}
	ok("status", build_status(policy, manifest, state, evidence, {
		build: installed_build(),
		backend: backend_metadata(),
		active: is_active(profile),
		recovery: pending_recovery(policy),
		profile: profile,
		profile_display_name: profile_display_name(profile),
		recovery_profile_display_name: profile_display_name(policy.recovery_profile.ref),
		netfleet_present: state_has_netfleet(state, manifest, profile),
		backend_enabled: enabled,
		mihomo_running: mihomo_running,
		lan_runtime: mihomo_running ? lan_runtime_state() : null,
		cleanup: cleanup,
		quotas: provider_quotas(policy),
		provider_names: provider_display_names(policy),
		automation: automation_config(policy),
		subscription_refresh: subscription_refresh_projection(policy),
		supervisor: service_state()
	}));
};

profile_display_name = function(profile) {
	const prefix = "subscription:";
	if (type(profile) == "string" && index(profile, prefix) == 0) {
		const section = substr(profile, length(prefix));
		const display = subscription_display_name(section);
		return display == section ? null : display;
	}
	return null;
};

command_status = function(argv) {
	const policy = load_policy();
	if (policy == null) fail(argv[0], "policy_unreadable", POLICY_PATH);
	const evidence = load_evidence();
	status_action(policy, evidence);
};

return { normalized_build, installed_build, status_action, profile_display_name, command_status };
};
