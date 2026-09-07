return function(context) {
// Bind the service functions before assigning closures that may reference them.
let settings, runtime_controller_ready, tick;

const load_policy = context.use("platform.documents").load_policy;
const current_profile = context.use("platform.profile").current_profile;
const backend_enabled = context.use("platform.profile").backend_enabled;
const api_secret = context.use("platform.credentials").api_secret;
const run_owner = context.use("platform.process").run_owner;
const running = context.use("mihomo.backend").running;
const lan_runtime_state = context.use("mihomo.backend").lan_runtime_state;
const controller_ready = context.use("mihomo.controller").controller_ready;
const automation = context.use("models.policy").automation;
const guard_probe_url = context.use("models.policy").guard_probe_url;
const is_active = context.use("models.activation").is_active;
const pending_recovery = context.use("recovery.state").pending;

settings = function() {
	const policy = load_policy();
	if (policy == null) return null;
	return { policy: policy, automation: automation(policy), dns_probe_url: guard_probe_url(policy) };
};

runtime_controller_ready = function() {
	const secret = api_secret();
	return type(secret) == "string" && length(secret) > 0 && controller_ready(secret, 2);
};

tick = function(previous) {
	let unhealthy_since = previous?.unhealthy_since ?? null;
	let next_selection_at = previous?.next_selection_at ?? null;
	let next_refresh_at = previous?.next_refresh_at ?? null;
	let was_runtime_ready = previous?.was_runtime_ready == true;
	function result(delay) {
		return { state: { unhealthy_since: unhealthy_since, next_selection_at: next_selection_at,
			next_refresh_at: next_refresh_at, was_runtime_ready: was_runtime_ready }, delay_ms: delay };
	};
	const settings_value = settings();
	const now = int(time());
	if (settings_value == null || settings_value.policy.main.enabled != true) {
		unhealthy_since = null;
		next_selection_at = null;
		next_refresh_at = null;
		was_runtime_ready = false;
		return result(30000);
	}
	const config = settings_value.automation;
	if (next_selection_at == null) next_selection_at = now + config.selection_interval_seconds;
	if (config.subscription_refresh_enabled == true && next_refresh_at == null)
		next_refresh_at = now + config.subscription_refresh_interval_seconds;
	if (config.subscription_refresh_enabled != true) {
		next_refresh_at = null;
	} else if (now >= next_refresh_at && run_owner("refresh", "scheduled")) {
		next_refresh_at = now + config.subscription_refresh_interval_seconds;
		next_selection_at = now + config.selection_interval_seconds;
	}
	const owned = is_active(current_profile());
	const recovery = pending_recovery(settings_value.policy);
	if (!owned && recovery != null && now >= recovery.retry_at) {
		run_owner("resume", "supervisor");
		return result(config.poll_interval_seconds * 1000);
	}
	const runtime_ready = owned && backend_enabled() == true && running() && runtime_controller_ready();
	const lan_runtime = runtime_ready ? lan_runtime_state(settings_value.dns_probe_url) : null;
	const healthy = runtime_ready && lan_runtime?.transparent_proxy_ready == true && lan_runtime?.dns_ready == true;
	if (healthy && !was_runtime_ready) next_selection_at = now;
	was_runtime_ready = healthy;
	if (!owned) {
		unhealthy_since = null;
	} else if (healthy) {
		unhealthy_since = null;
		if (config.enabled == true && now >= next_selection_at) {
			run_owner("maintain", "scheduled");
			next_selection_at = now + config.selection_interval_seconds;
		}
	} else {
		if (unhealthy_since == null) unhealthy_since = now;
		if (now - unhealthy_since >= config.runtime_grace_seconds) {
			let reason = "runtime_unavailable";
			if (runtime_ready && lan_runtime?.transparent_proxy_ready == false) reason = "lan_ingress_unavailable";
			else if (runtime_ready && lan_runtime?.dns_ready == false) reason = "dns_ingress_unavailable";
			if (run_owner("recover", reason)) unhealthy_since = null;
		}
	}
	return result(config.poll_interval_seconds * 1000);
};

return { tick };
};
