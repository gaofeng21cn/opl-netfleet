import { unlink, stat } from "fs";

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let pending, clear, request, defer;

const is_active = context.use("models.activation").is_active;
const atomic_json = context.use("platform.files").atomic_json;
const KIND = context.use("platform.runtime").KIND;
const read_json = context.use("platform.storage").read_json;
const current_profile = context.use("platform.profile").current_profile;

const PATH = context.use("platform.paths").RECOVERY_PATH;

pending = function(policy) {
	const value = read_json(PATH);
	const profile = current_profile();
	if (policy?.main?.enabled != true || value?.backend != KIND ||
		value?.profile != policy?.recovery_profile?.ref ||
		(!is_active(profile) && profile != value.profile) ||
		type(value.reason) != "string" || type(value.requested_at) != "int" ||
		type(value.retry_at) != "int") return null;
	return value;
};

clear = function() { return stat(PATH) == null || unlink(PATH); };

request = function(policy, reason) {
	const previous = pending(policy);
	const now = int(time());
	return atomic_json(PATH, { backend: KIND, profile: policy.recovery_profile.ref,
		reason: reason, requested_at: previous?.requested_at ?? now,
		retry_at: previous?.retry_at ?? now + 300 });
};

defer = function(policy) {
	const value = pending(policy);
	return value != null && atomic_json(PATH, { ...value, retry_at: int(time()) + 300 });
};

return { PATH, pending, clear, request, defer };
};
