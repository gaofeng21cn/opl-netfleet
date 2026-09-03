#!/usr/bin/ucode

import { read_json, current_profile, nikki_enabled, api_secret, shell_quote, POLICY_PATH } from "./adapters/uci.uc";
import { running, lan_runtime_state } from "./adapters/nikki.uc";
import { controller_ready } from "./adapters/mihomo.uc";
import { validate, automation, guard_probe_url } from "./core/policy.uc";
import { is_active } from "./core/activation.uc";

const MAIN = "/usr/libexec/opl-netfleet/main.uc";
const LOCK = "/var/lock/opl-netfleet-deploy.lock";

function settings() {
	const policy = read_json(POLICY_PATH);
	if (policy == null || !validate(policy).ok) return null;
	return {
		automation: automation(policy),
		dns_probe_url: guard_probe_url(policy)
	};
};

function runtime_controller_ready() {
	const secret = api_secret();
	return type(secret) == "string" && length(secret) > 0 && controller_ready(secret, 2);
};

function run_owner(action, detail) {
	const suffix = detail == null ? "" : ` ${shell_quote(detail)}`;
	const command = `(flock -n 9 || exit 75; ` +
		`ucode ${shell_quote(MAIN)} ${action}${suffix} 9>&- >/dev/null 2>&1) ` +
		`9>${shell_quote(LOCK)}`;
	return system(command) == 0;
};

let unhealthy_since = null;
let next_selection_at = null;
let next_refresh_at = null;

for (;;) {
	const settings_value = settings();
	const now = int(time());
	if (settings_value == null || settings_value.automation.enabled != true) {
		unhealthy_since = null;
		next_selection_at = null;
		next_refresh_at = null;
		system("sleep 30");
		continue;
	}
	const config = settings_value.automation;
	if (next_selection_at == null) next_selection_at = now + config.selection_interval_seconds;
	if (config.subscription_refresh_enabled == true && next_refresh_at == null) {
		next_refresh_at = now + config.subscription_refresh_interval_seconds;
	}
	if (config.subscription_refresh_enabled != true) {
		next_refresh_at = null;
	} else if (now >= next_refresh_at && run_owner("refresh", "scheduled")) {
		next_refresh_at = now + config.subscription_refresh_interval_seconds;
		// A changed active subscription already executes the same automatic round.
		// Move the independent selection deadline forward after a completed refresh.
		next_selection_at = now + config.selection_interval_seconds;
	}

	const owned = is_active(current_profile());
	const runtime_ready = owned && nikki_enabled() == true && running() && runtime_controller_ready();
	const lan_runtime = runtime_ready ? lan_runtime_state(settings_value.dns_probe_url) : null;
	const healthy = runtime_ready && lan_runtime?.transparent_proxy_ready == true &&
		lan_runtime?.dns_ready == true;
	if (!owned) {
		unhealthy_since = null;
	} else if (healthy) {
		unhealthy_since = null;
		if (now >= next_selection_at) {
			run_owner("maintain", "scheduled");
			next_selection_at = now + config.selection_interval_seconds;
		}
	} else {
		if (unhealthy_since == null) unhealthy_since = now;
		if (now - unhealthy_since >= config.runtime_grace_seconds) {
			let reason = "runtime_unavailable";
			if (runtime_ready && lan_runtime?.transparent_proxy_ready == false) {
				reason = "lan_ingress_unavailable";
			} else if (runtime_ready && lan_runtime?.dns_ready == false) {
				reason = "dns_ingress_unavailable";
			}
			if (run_owner("recover", reason)) unhealthy_since = null;
		}
	}
	system(`sleep ${config.poll_interval_seconds}`);
}
