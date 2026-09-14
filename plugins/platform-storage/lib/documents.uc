

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let validate_policy, load_policy, load_evidence, write_evidence;

const validate_evidence = context.use("models.evidence").validate;
const validate_policy_model = context.use("models.policy").validate;
const POLICY_PATH = context.use("platform.paths").POLICY_PATH;
const read_json = context.use("platform.storage").read_json;
const EVIDENCE_PATH = context.use("platform.paths").EVIDENCE_PATH;
const mkdir = context.use("platform.storage").mkdir;
const write_json_atomic = context.use("platform.storage").write_json_atomic;

validate_policy = function(policy) {
	const validation = validate_policy_model(policy);
	if (validation.ok && policy.evidence.path != EVIDENCE_PATH) {
		return { ok: false, errors: ["evidence.path must match the platform evidence path"] };
	}
	return validation;
};

load_policy = function(path) {
	const policy = read_json(path ?? POLICY_PATH);
	return validate_policy(policy).ok ? policy : null;
};

load_evidence = function() {
	const evidence = read_json(EVIDENCE_PATH);
	const validation = validate_evidence(evidence);
	return validation.ok ? evidence : null;
};

write_evidence = function(store) {
	return mkdir(replace(EVIDENCE_PATH, /\/[^/]+$/, "")) && write_json_atomic(EVIDENCE_PATH, store);
};

return { validate_policy, load_policy, load_evidence, write_evidence };
};
