

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let require_protected_probes, protected_probes_after_restart, protected_probes_bounded, command_probe;

const fail = context.use("events.output").fail;
const ok = context.use("events.output").ok;
const protected_probes = context.use("mihomo.controller").protected_probes;
const load_policy = context.use("platform.documents").load_policy;
const POLICY_PATH = context.use("platform.paths").POLICY_PATH;

require_protected_probes = function(policy, action) {
	const result = protected_probes(policy);
	if (!result.ok) {
		fail(action, result.error, result);
	}
	return result;
};

protected_probes_after_restart = function(policy) {
	let result = null;
	// Nikki restart can leave the data plane unavailable briefly on slower
	// targets.  Keep the total probe window bounded; a failed probe is never a
	// reason to restart Nikki again from this helper.
	for (let attempt = 0; attempt < 4; attempt++) {
		result = protected_probes(policy, 4);
		if (result.ok || attempt == 3) {
			return result;
		}
		sleep(1000);
	}
	return result;
};

protected_probes_bounded = function(policy, attempts, limit_seconds) {
	let max_attempts = type(attempts) == "int" ? attempts : 2;
	if (max_attempts < 1) max_attempts = 1;
	if (max_attempts > 4) max_attempts = 4;
	let result = null;
	for (let attempt = 0; attempt < max_attempts; attempt++) {
		result = protected_probes(policy, limit_seconds);
		if (result?.ok == true) return result;
		const status = result?.actual_status;
		const transient = result?.error == "protected_probe_failed" &&
			(status == null || status == "" || index(["000", "502", "503", "504"], `${status}`) >= 0);
		if (!transient || attempt + 1 >= max_attempts) {
			return result;
		}
		sleep(1000);
	}
	return result;
};

command_probe = function(argv) {
	const policy = load_policy();
	if (policy == null) fail(argv[0], "policy_unreadable", POLICY_PATH);
	const result = protected_probes_after_restart(policy);
	if (!result.ok) fail("probe", result.error, result);
	ok("probe", result);
};

return { require_protected_probes, protected_probes_after_restart, protected_probes_bounded, command_probe };
};
