import { unlink, stat } from "fs";
import { read_json, current_profile } from "./uci.uc";
import { atomic_json } from "./native.uc";
import { KIND } from "./runtime.uc";
import { is_active } from "../core/activation.uc";

export const PATH = "/etc/opl-netfleet/recovery.json";

export function pending(policy) {
	const value = read_json(PATH);
	const profile = current_profile();
	if (policy?.main?.enabled != true || value?.backend != KIND ||
		value?.profile != policy?.recovery_profile?.ref ||
		(!is_active(profile) && profile != value.profile) ||
		type(value.reason) != "string" || type(value.requested_at) != "int" ||
		type(value.retry_at) != "int") return null;
	return value;
};

export function clear() { return stat(PATH) == null || unlink(PATH); };

export function request(policy, reason) {
	const previous = pending(policy);
	const now = int(time());
	return atomic_json(PATH, { backend: KIND, profile: policy.recovery_profile.ref,
		reason: reason, requested_at: previous?.requested_at ?? now,
		retry_at: previous?.retry_at ?? now + 300 });
};

export function defer(policy) {
	const value = pending(policy);
	return value != null && atomic_json(PATH, { ...value, retry_at: int(time()) + 300 });
};
