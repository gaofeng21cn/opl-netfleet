

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let require_protected_probes, protected_probes_after_restart, command_probe;

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
		system("sleep 1");
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

return { require_protected_probes, protected_probes_after_restart, command_probe };
};
