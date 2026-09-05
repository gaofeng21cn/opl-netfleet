import { read_yaml, subscription_exists, subscription_display_name, subscription_quota, shell_quote } from "../adapters/uci.uc";
import { resolve_profile, provider_runtime_path } from "../adapters/backend.uc";

export function load(policy) {
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
