

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let subscription_facts, subscription_refresh_projection, require_provider_profiles, policy_provider_profiles, manifest_provider_profiles, remove_policy_provider_links, provider_quotas, provider_display_names;

const validate_events = context.use("events.model").validate;
const fail = context.use("events.output").fail;
const read_events = context.use("events.store").read_events;
const resolve_profile = context.use("mihomo.backend").resolve_profile;
const remove_provider_links = context.use("mihomo.backend").remove_provider_links;
const automation_config = context.use("models.policy").automation;
const enabled_subscription_sections = context.use("models.subscription").enabled_sections;
const cache_accepted = context.use("models.subscription").cache_accepted;
const subscription_quota_config = context.use("models.subscription").quota_config;
const project_subscriptions = context.use("models.subscription").project;
const sha256 = context.use("platform.storage").sha256;
const read_yaml = context.use("platform.storage").read_yaml;
const subscription_display_name = context.use("platform.subscriptions").subscription_display_name;
const file_mtime = context.use("platform.storage").file_mtime;
const subscription_quota = context.use("platform.subscriptions").subscription_quota;
const load_provider_profile_result = context.use("subscriptions.providers").load;

subscription_facts = function(policy) {
	const facts = [];
	const sections = enabled_subscription_sections(policy);
	for (let i = 0; i < length(sections); i++) {
		const section = sections[i];
		const path = resolve_profile(`subscription:${section}`);
		const digest = path == null ? null : sha256(path);
		const parsed = digest == null ? null : read_yaml(path);
		push(facts, {
			section: section,
			ref: `subscription:${section}`,
			display_name: subscription_display_name(section),
			present: digest != null,
			digest: digest,
			valid: cache_accepted(parsed),
			node_count: type(parsed?.proxies) == "array" ? length(parsed.proxies) : null,
			updated_at: path == null ? null : file_mtime(path),
			quota: subscription_quota(section, subscription_quota_config(policy, section))
		});
	}
	return facts;
};

subscription_refresh_projection = function(policy) {
	const store = read_events();
	const events = validate_events(store).ok ? store?.events ?? [] : [];
	return project_subscriptions(automation_config(policy), subscription_facts(policy), events);
};

require_provider_profiles = function(policy, stage) {
	const result = load_provider_profile_result(policy);
	if (!result.ok) {
		fail(stage, result.error, result.detail);
	}
	return result.profiles;
};

policy_provider_profiles = function(policy) {
	const result = {};
	const names = keys(policy.providers ?? {});
	for (let i = 0; i < length(names); i++) {
		const name = names[i];
		const section = policy.providers[name]?.section;
		if (type(section) == "string" && length(section) > 0) {
			result[name] = { path: resolve_profile(`subscription:${section}`) };
		}
	}
	return result;
};

manifest_provider_profiles = function(manifest) {
	const result = {};
	const generated = manifest?.generated_groups ?? {};
	const capability_names = keys(generated);
	for (let capability_index = 0; capability_index < length(capability_names); capability_index++) {
		const providers = generated[capability_names[capability_index]]?.providers ?? {};
		const names = keys(providers);
		for (let i = 0; i < length(names); i++) {
			const name = names[i];
			const section = providers[name]?.section;
			if (!match(name, /^[A-Za-z0-9_-]+$/) ||
				type(section) != "string" || !match(section, /^[A-Za-z0-9_]+$/)) {
				continue;
			}
			const path = resolve_profile(`subscription:${section}`);
			if (path != null) {
				result[name] = { path: path };
			}
		}
	}
	return result;
};

remove_policy_provider_links = function(policy) {
	remove_provider_links(policy_provider_profiles(policy));
};

provider_quotas = function(policy) {
	const result = {};
	const names = keys(policy.providers ?? {});
	for (let i = 0; i < length(names); i++) {
		const name = names[i];
		const provider = policy.providers[name];
		if (provider?.enabled == true) {
			result[name] = subscription_quota(provider.section, provider.quota);
		}
	}
	return result;
};

provider_display_names = function(policy) {
	const result = {};
	const names = keys(policy.providers ?? {});
	for (let i = 0; i < length(names); i++) {
		const name = names[i];
		const provider = policy.providers[name];
		result[name] = subscription_display_name(provider.section);
	}
	return result;
};

return { subscription_facts, subscription_refresh_projection, require_provider_profiles, policy_provider_profiles, manifest_provider_profiles, remove_policy_provider_links, provider_quotas, provider_display_names };
};
