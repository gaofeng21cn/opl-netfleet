

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let load;

const resolve_profile = context.use("mihomo.backend").resolve_profile;
const provider_runtime_path = context.use("mihomo.backend").provider_runtime_path;
const read_yaml = context.use("platform.storage").read_yaml;
const subscription_exists = context.use("platform.subscriptions").subscription_exists;
const subscription_display_name = context.use("platform.subscriptions").subscription_display_name;
const subscription_quota = context.use("platform.subscriptions").subscription_quota;
const shell_quote = context.use("platform.process").shell_quote;

load = function(policy) {
	const result = {};
	const provider_names = keys(policy?.providers ?? {});
	for (let i = 0; i < length(provider_names); i++) {
		const name = provider_names[i];
		const provider = policy.providers[name];
		if (provider?.enabled != true) continue;
		if (!subscription_exists(provider.section))
			return { ok: false, error: "provider_section_missing", detail: { provider: name, section: provider.section } };
		const reference = `subscription:${provider.section}`;
		const path = resolve_profile(reference);
		if (path == null || system(`test -f ${shell_quote(path)}`) != 0)
			return { ok: false, error: "provider_cache_missing", detail: { provider: name, section: provider.section } };
		const profile = read_yaml(path);
		if (profile == null)
			return { ok: false, error: "provider_cache_unreadable", detail: { provider: name, section: provider.section } };
		result[name] = {
			path: path,
			runtime_path: provider_runtime_path(name),
			display_name: subscription_display_name(provider.section),
			profile: profile,
			quota: subscription_quota(provider.section, provider.quota)
		};
	}
	return { ok: true, profiles: result };
};

return { load };
};
