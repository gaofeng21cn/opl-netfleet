

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let load_manifest;

const fail = context.use("events.output").fail;
const MANIFEST_PATH = context.use("mihomo.backend").MANIFEST_PATH;
const read_json = context.use("platform.storage").read_json;

load_manifest = function() {
	const manifest = read_json(MANIFEST_PATH);
	if (manifest == null) {
		fail("runtime", "staged_manifest_missing", MANIFEST_PATH);
	}
	return manifest;
};

return { load_manifest };
};
