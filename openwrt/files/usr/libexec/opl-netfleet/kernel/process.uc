export const API_VERSION = 1;
const LIMIT = 65536;

function fail(error) { return { ok: false, error: error }; };

export function invoke(found, action, params, adapter) {
	let result = fail("plugin_no_response");
	try {
		const execution = adapter.invoke_process(found.entry, action,
			{ request: { api_version: API_VERSION, id: found.manifest.id, action: action, params: params ?? {} } }, LIMIT);
		if (!execution.ok) return execution;
		const content = execution.output;
		if (type(content) != "string" || length(content) > LIMIT) return fail("plugin_response_invalid");
		let response;
		try { response = json(content); } catch (error) { return fail("plugin_response_invalid"); }
		if (type(response) != "object" || type(response.ok) != "bool") return fail("plugin_response_invalid");
		if (execution.status != 0 || execution.exit_status != "0" || response.ok != true) return fail("plugin_action_failed");
		if (type(response.result) != "object") return fail("plugin_response_invalid");
		if (action == "get" && (type(response.result.loaded) != "bool" || type(response.result.ready) != "bool")) return fail("plugin_status_invalid");
		result = { ok: true, result: response.result };
	} catch (error) { result = fail("plugin_execution_failed"); }
	return result;
};

export function lifecycle(found, action, params, adapter) {
	if (action == "reload") {
		const stopped = lifecycle(found, "unload", params, adapter);
		if (!stopped.ok) return stopped;
		return lifecycle(found, "load", params, adapter);
	}
	const applied = invoke(found, action, params, adapter);
	if (index(["load", "unload"], action) < 0) return applied;
	const observed = invoke(found, "get", {}, adapter);
	if (applied.ok && observed.ok && observed.result.loaded == (action == "load") &&
		(action != "load" || observed.result.ready)) return observed;
	if (action == "unload") return fail("plugin_unload_unconfirmed");
	const rollback = invoke(found, "unload", {}, adapter);
	const restored = invoke(found, "get", {}, adapter);
	return fail(rollback.ok && restored.ok && restored.result.loaded == false ? "plugin_load_failed_rolled_back" : "plugin_rollback_unconfirmed");
};

export function dispatch(input, found, adapter) {
	if (index(["get", "load", "unload", "reload"], input.action) < 0) {
		const state = invoke(found, "get", {}, adapter);
		if (!state.ok || !state.result.loaded || !state.result.ready) return fail("plugin_not_loaded");
	}
	const result = lifecycle(found, input.action, input.params, adapter);
	return result.ok ? { ok: true, result: { ...result.result, id: found.manifest.id, revision: found.revision } } : result;
};
