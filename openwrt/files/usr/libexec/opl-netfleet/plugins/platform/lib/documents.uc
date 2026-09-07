

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let load_policy, load_evidence;

const validate_evidence = context.use("models.evidence").validate;
const validate_policy = context.use("models.policy").validate;
const POLICY_PATH = context.use("platform.uci").POLICY_PATH;
const read_json = context.use("platform.uci").read_json;
const EVIDENCE_PATH = context.use("platform.uci").EVIDENCE_PATH;

load_policy = function(path) {
	const source = path ?? POLICY_PATH;
	const policy = read_json(source);
	if (policy == null) {
		return null;
	}
	const validation = validate_policy(policy);
	if (!validation.ok) {
		return null;
	}
	return policy;
};

load_evidence = function() {
	const evidence = read_json(EVIDENCE_PATH);
	const validation = validate_evidence(evidence);
	return validation.ok ? evidence : null;
};

return { load_policy, load_evidence };
};
