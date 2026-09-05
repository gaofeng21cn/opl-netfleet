function sorted_names(object) {
	const result = [];
	const names = keys(object ?? {});
	for (let i = 0; i < length(names); i++) {
		push(result, names[i]);
		for (let j = length(result) - 1; j > 0 && result[j] < result[j - 1]; j--) {
			const previous = result[j - 1];
			result[j - 1] = result[j];
			result[j] = previous;
		}
	}
	return result;
};

export function enabled_sections(policy) {
	const result = [];
	const seen = {};
	const names = sorted_names(policy?.providers ?? {});
	for (let i = 0; i < length(names); i++) {
		const provider = policy.providers[names[i]];
		const section = provider?.section;
		if (provider?.enabled == true && type(section) == "string" && seen[section] != true) {
			seen[section] = true;
			push(result, section);
		}
	}
	return result;
};

export function referenced_sections(policy, profile) {
	const result = enabled_sections(policy);
	const refs = [policy?.policy_source?.kind == "profile" ? policy.policy_source.ref : null,
		policy?.recovery_profile?.ref, profile];
	for (let i = 0; i < length(refs); i++) {
		const matched = type(refs[i]) == "string" ? match(refs[i], /^subscription:([A-Za-z0-9_]+)$/) : null;
		if (matched != null && index(result, matched[1]) < 0) push(result, matched[1]);
	}
	return result;
};

export function quota_config(policy, section) {
	const names = sorted_names(policy?.providers ?? {});
	for (let i = 0; i < length(names); i++) {
		const provider = policy.providers[names[i]];
		if (provider?.enabled == true && provider?.section == section) {
			return provider.quota ?? null;
		}
	}
	return null;
};

export function cache_accepted(parsed) {
	return type(parsed) == "object" && type(parsed.proxies) == "array" && length(parsed.proxies) > 0;
};

export function evaluate_entry(input) {
	const section = input?.section;
	const previous = type(input?.previous_digest) == "string" && length(input.previous_digest) > 0 ?
		input.previous_digest : null;
	const digest = type(input?.digest) == "string" && length(input.digest) > 0 ? input.digest : null;
	if (input?.updated != true || digest == null || !cache_accepted(input?.parsed)) {
		return {
			section: section,
			result: "failed",
			restore: true,
			changed: false,
			digest: previous,
			ok: false
		};
	}
	if (digest == previous) {
		return {
			section: section,
			result: "unchanged",
			restore: false,
			changed: false,
			digest: digest,
			ok: true
		};
	}
	return {
		section: section,
		result: "updated",
		restore: false,
		changed: true,
		digest: digest,
		ok: true
	};
};

export function summarize(outcomes) {
	let changed_count = 0;
	let failed_count = 0;
	const entries = outcomes ?? [];
	for (let i = 0; i < length(entries); i++) {
		if (entries[i]?.result == "failed") failed_count++;
		else if (entries[i]?.changed == true) changed_count++;
	}
	const cache_reason = changed_count == 0 ?
		(failed_count == 0 ? "unchanged" : "update_failed") :
		(failed_count == 0 ? "cache_updated" : "partially_updated");
	return {
		provider_count: length(entries),
		changed_count: changed_count,
		failed_count: failed_count,
		ok: failed_count == 0,
		cache_reason: cache_reason,
		active_reason: changed_count == 0 ? cache_reason :
			(failed_count == 0 ? "updated" : "partially_updated")
	};
};

export function public_results(outcomes) {
	const result = [];
	const entries = outcomes ?? [];
	for (let i = 0; i < length(entries); i++) {
		push(result, {
			section: entries[i]?.section ?? null,
			result: entries[i]?.result ?? "failed",
			digest: entries[i]?.digest ?? null
		});
	}
	return result;
};

export function unavailable_results(sections) {
	const result = [];
	const names = sections ?? [];
	for (let i = 0; i < length(names); i++) {
		push(result, { section: names[i], result: "failed", digest: null });
	}
	return result;
};

function latest_refresh(events) {
	let latest = null;
	const items = events ?? [];
	for (let i = 0; i < length(items); i++) {
		if (items[i]?.action == "refresh") latest = items[i];
	}
	return latest;
};

function section_refresh_state(events) {
	const result = {};
	const items = events ?? [];
	for (let i = length(items) - 1; i >= 0; i--) {
		const event = items[i];
		if (event?.action != "refresh" || type(event.subscriptions) != "array") continue;
		for (let j = 0; j < length(event.subscriptions); j++) {
			const item = event.subscriptions[j];
			const section = item?.section;
			if (type(section) != "string") continue;
			if (result[section] == null) {
				result[section] = {
					last_attempt: event.at ?? null,
					last_result: item.result ?? null,
					last_success: null
				};
			}
			if (result[section].last_success == null &&
				(item.result == "updated" || item.result == "unchanged")) {
				result[section].last_success = event.at ?? null;
			}
		}
	}
	return result;
};

function public_quota(quota) {
	const result = { state: quota?.state ?? "unknown" };
	if (type(quota?.remaining_bytes) == "int" && quota.remaining_bytes > 0) {
		result.remaining_bytes = quota.remaining_bytes;
	}
	if (type(quota?.expires_at) == "string" && length(quota.expires_at) > 0) {
		result.expires_at = quota.expires_at;
	}
	return result;
};

export function project(automation, facts, events) {
	const latest = latest_refresh(events);
	const by_section = section_refresh_state(events);
	const subscriptions = [];
	const entries = facts ?? [];
	for (let i = 0; i < length(entries); i++) {
		const fact = entries[i];
		const section = fact?.section;
		const history = type(section) == "string" ? by_section[section] ?? null : null;
		push(subscriptions, {
			section: section,
			ref: type(fact?.ref) == "string" ? fact.ref : `subscription:${section}`,
			display_name: type(fact?.display_name) == "string" && length(fact.display_name) > 0 ?
				fact.display_name : section,
			cache_present: fact?.present == true,
			cache_sha256: type(fact?.digest) == "string" ? fact.digest : null,
			node_count: type(fact?.node_count) == "int" && fact.node_count >= 0 ? fact.node_count : null,
			quota: public_quota(fact?.quota),
			last_attempt: history?.last_attempt ?? null,
			last_success: history?.last_success ??
				(type(fact?.updated_at) == "int" && fact.updated_at > 0 ? fact.updated_at : null),
			last_result: history?.last_result ?? null
		});
	}
	return {
		enabled: automation?.subscription_refresh_enabled == true,
		interval_seconds: automation?.subscription_refresh_interval_seconds ?? null,
		provider_count: length(subscriptions),
		last_run_at: latest?.at ?? null,
		last_result: latest?.reason ?? null,
		last_ok: latest?.ok ?? null,
		last_changed_count: latest?.changed_count ?? null,
		last_failed_count: latest?.failed_count ?? null,
		last_reloaded: latest?.reloaded ?? null,
		last_initiator: latest?.initiator ?? null,
		subscriptions: subscriptions
	};
};
