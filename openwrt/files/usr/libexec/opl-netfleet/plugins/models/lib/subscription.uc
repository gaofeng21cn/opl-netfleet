

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let sorted_names, enabled_sections, referenced_sections, quota_config, cache_accepted, evaluate_entry, summarize, public_results, unavailable_results, history_update, refresh_due_at, public_quota, project;



sorted_names = function(object) {
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

enabled_sections = function(policy) {
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

referenced_sections = function(policy, profile) {
	const result = enabled_sections(policy);
	const refs = [policy?.policy_source?.kind == "profile" ? policy.policy_source.ref : null,
		policy?.recovery_profile?.ref, profile];
	for (let i = 0; i < length(refs); i++) {
		const matched = type(refs[i]) == "string" ? match(refs[i], /^subscription:([A-Za-z0-9_]+)$/) : null;
		if (matched != null && index(result, matched[1]) < 0) push(result, matched[1]);
	}
	return result;
};

quota_config = function(policy, section) {
	const names = sorted_names(policy?.providers ?? {});
	for (let i = 0; i < length(names); i++) {
		const provider = policy.providers[names[i]];
		if (provider?.enabled == true && provider?.section == section) {
			return provider.quota ?? null;
		}
	}
	return null;
};

cache_accepted = function(parsed) {
	return type(parsed) == "object" && type(parsed.proxies) == "array" && length(parsed.proxies) > 0;
};

evaluate_entry = function(input) {
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

summarize = function(outcomes) {
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

public_results = function(outcomes) {
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

unavailable_results = function(sections) {
	const result = [];
	const names = sections ?? [];
	for (let i = 0; i < length(names); i++) {
		push(result, { section: names[i], result: "failed", digest: null });
	}
	return result;
};

history_update = function(previous, event, full) {
	const state = previous == null ? { schema_version: 1, subscriptions: {} } : json(sprintf("%J", previous));
	if (event?.action != "refresh" || type(event.at) != "int" || event.at <= 0) return state;
	if (full == true) {
		state.latest = event;
		if (event.ok == true) state.last_success_at = event.at;
	}
	const accepted = index(["rollback_restored", "rollback_failed"], event.reason) < 0;
	for (let item in event.subscriptions ?? []) {
		if (type(item.section) != "string") continue;
		const old = state.subscriptions[item.section];
		state.subscriptions[item.section] = {
			last_attempt: event.at,
			last_result: accepted ? item.result : event.reason,
			last_success: accepted && index(["updated", "unchanged"], item.result) >= 0 ? event.at : old?.last_success ?? null
		};
	}
	return state;
};

refresh_due_at = function(history, interval) {
	const attempt = history?.latest;
	if (type(attempt?.at) == "int" && attempt.ok != true) return attempt.at + 300;
	const success = history?.last_success_at;
	return type(success) == "int" ? success + interval : null;
};

public_quota = function(quota) {
	const result = { state: quota?.state ?? "unknown" };
	if (type(quota?.reset_day) == "int" && quota.reset_day >= 1 && quota.reset_day <= 31 && quota.reset_day_source == "manual") {
		result.reset_day = quota.reset_day;
		result.reset_day_source = "manual";
	}
	if (type(quota?.remaining_bytes) == "int" && quota.remaining_bytes > 0) {
		result.remaining_bytes = quota.remaining_bytes;
	}
	if (type(quota?.expires_at) == "string" && length(quota.expires_at) > 0) {
		result.expires_at = quota.expires_at;
	}
	return result;
};

project = function(automation, facts, history) {
	const latest = history?.latest;
	const by_section = history?.subscriptions ?? {};
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
		last_success_at: history?.last_success_at ?? null,
		next_run_at: automation?.subscription_refresh_enabled == true ? refresh_due_at(history, automation.subscription_refresh_interval_seconds) : null,
		last_result: latest?.reason ?? null,
		last_ok: latest?.ok ?? null,
		last_changed_count: latest?.changed_count ?? null,
		last_failed_count: latest?.failed_count ?? null,
		last_reloaded: latest?.reloaded ?? null,
		last_initiator: latest?.initiator ?? null,
		subscriptions: subscriptions
	};
};

return { enabled_sections, referenced_sections, quota_config, cache_accepted, evaluate_entry, summarize, public_results, unavailable_results, history_update, refresh_due_at, project };
};
