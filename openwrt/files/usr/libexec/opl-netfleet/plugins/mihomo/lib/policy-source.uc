

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let bundle_id, resolve, load;

const resolve_profile = context.use("mihomo.backend").resolve_profile;
const read_json = context.use("platform.storage").read_json;
const read_yaml = context.use("platform.storage").read_yaml;

const POLICY_SOURCE_DIR = context.use("platform.paths").POLICY_SOURCE_DIR;

bundle_id = function(reference) {
	const parts = split(reference ?? "", ":");
	if (length(parts) != 2 || parts[0] != "bundle" ||
		!match(parts[1], /^[A-Za-z0-9][A-Za-z0-9_-]*$/)) {
		return null;
	}
	return parts[1];
};

resolve = function(source) {
	if (source?.kind == "profile") {
		return resolve_profile(source.ref);
	}
	if (source?.kind == "bundle") {
		const id = bundle_id(source.ref);
		return id == null ? null : `${POLICY_SOURCE_DIR}/${id}.json`;
	}
	return null;
};

load = function(source) {
	const path = resolve(source);
	if (path == null) {
		return null;
	}
	return source.kind == "bundle" ? read_json(path) : read_yaml(path);
};

return { POLICY_SOURCE_DIR, resolve, load };
};
