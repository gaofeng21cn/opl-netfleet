import * as fs from "fs";
import { shell_quote as q, write_private } from "./io.uc";

export const API_VERSION = 1;
const LIMIT = 65536;

function fail(error) { return { ok: false, error: error }; };

function execute(found, action, params, work) {
	const request = `${work}/request.json`, status_path = `${work}/exit`;
	let result = fail("plugin_no_response");
	try {
		if (!write_private(request, sprintf("%J", { request: { api_version: API_VERSION, id: found.manifest.id, action: action, params: params ?? {} } })))
			return fail("plugin_request_unavailable");
		// Bound stdout without restricting files owned by the plugin.
		const command = `{ ${q(found.entry)} ${q(action)} ${q(request)} 2>/dev/null; printf '%s' "$?" >${q(status_path)}; } | head -c ${LIMIT + 1}`;
		const pipe = fs.popen(`timeout -k 2 30 sh -c ${q(command)} 2>/dev/null`);
		if (pipe == null) return fail("plugin_no_response");
		const content = pipe.read("all");
		const status = pipe.close();
		if (status == 124 || status == 137) return fail("plugin_timeout");
		if (type(content) != "string" || length(content) > LIMIT) return fail("plugin_response_invalid");
		let response;
		try { response = json(content); } catch (error) { return fail("plugin_response_invalid"); }
		if (type(response) != "object" || type(response.ok) != "bool") return fail("plugin_response_invalid");
		if (status != 0 || trim(fs.readfile(status_path) ?? "") != "0" || response.ok != true) return fail("plugin_action_failed");
		if (type(response.result) != "object") return fail("plugin_response_invalid");
		if (action == "get" && (type(response.result.loaded) != "bool" || type(response.result.ready) != "bool")) return fail("plugin_status_invalid");
		result = { ok: true, result: response.result };
	} catch (error) { result = fail("plugin_execution_failed"); }
	return result;
};

export function invoke(found, action, params) {
	const work = fs.mkdtemp("/tmp/opl-netfleet-plugin.XXXXXX");
	if (work == null) return fail("plugin_request_unavailable");
	if (!fs.chmod(work, 0700)) { fs.rmdir(work); return fail("plugin_request_unavailable"); }
	const result = execute(found, action, params, work);
	fs.unlink(`${work}/request.json`); fs.unlink(`${work}/exit`); fs.rmdir(work);
	return result;
};

export function lifecycle(found, action, params) {
	if (action == "reload") {
		const stopped = lifecycle(found, "unload", params);
		if (!stopped.ok) return stopped;
		return lifecycle(found, "load", params);
	}
	const applied = invoke(found, action, params);
	if (index(["load", "unload"], action) < 0) return applied;
	const observed = invoke(found, "get", {});
	if (applied.ok && observed.ok && observed.result.loaded == (action == "load") &&
		(action != "load" || observed.result.ready)) return observed;
	if (action == "unload") return fail("plugin_unload_unconfirmed");
	const rollback = invoke(found, "unload", {});
	const restored = invoke(found, "get", {});
	return fail(rollback.ok && restored.ok && restored.result.loaded == false ? "plugin_load_failed_rolled_back" : "plugin_rollback_unconfirmed");
};

export function dispatch(input, found) {
	if (index(["get", "load", "unload", "reload"], input.action) < 0) {
		const state = invoke(found, "get", {});
		if (!state.ok || !state.result.loaded || !state.result.ready) return fail("plugin_not_loaded");
	}
	const result = lifecycle(found, input.action, input.params);
	return result.ok ? { ok: true, result: { ...result.result, id: found.manifest.id, revision: found.revision } } : result;
};
