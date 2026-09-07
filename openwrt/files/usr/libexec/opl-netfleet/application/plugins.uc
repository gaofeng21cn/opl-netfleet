import * as fs from "fs";
import { API_VERSION, valid_id, descriptor_error, action_access } from "../core/plugins.uc";
import { KIND } from "../adapters/runtime.uc";
import { sha256, shell_quote as q, read_json } from "../adapters/uci.uc";
import { private_file, write_private } from "../adapters/native.uc";

const ROOT = "/usr/libexec/opl-netfleet/plugins";
const LOCK = "/var/lock/opl-netfleet-deploy.lock";
const MAINTENANCE = "/var/run/opl-netfleet-plugin-maintenance";
const LIMIT = 65536;

function fail(error) { return { ok: false, error: error }; };
function trusted(path, kind) {
	const info = fs.lstat(path);
	return info?.type == kind && info.uid == 0 && (info.mode & 022) == 0;
};
function maintenance(id) {
	if (fs.lstat(MAINTENANCE) == null) return false;
	return !trusted(MAINTENANCE, "directory") || fs.lstat(`${MAINTENANCE}/${id}`) != null;
};
function replacing(id) { return fs.lstat(`${MAINTENANCE}/${id}/replacing`) != null; };
function inspect(id) {
	if (!valid_id(id)) return fail("plugin_id_invalid");
	const directory = `${ROOT}/${id}`, manifest_path = `${directory}/manifest.json`, entry = `${directory}/control`;
	if (fs.lstat(directory) == null) return fail("plugin_not_installed");
	if (!trusted(ROOT, "directory") || !trusted(directory, "directory") || !trusted(manifest_path, "file") ||
		!trusted(entry, "file") || !(fs.lstat(entry).mode & 0111)) return fail("plugin_files_unsafe");
	if (fs.lstat(manifest_path).size > 16384 || fs.lstat(entry).size > 1048576) return fail("plugin_files_too_large");
	const manifest = read_json(manifest_path);
	const error = descriptor_error(manifest, id);
	if (error != null) return fail(error);
	const manifest_sha = sha256(manifest_path), entry_sha = sha256(entry);
	if (manifest_sha == null || entry_sha == null) return fail("plugin_identity_unreadable");
	return { ok: true, manifest: manifest, entry: entry, revision: `${manifest_sha}:${entry_sha}` };
};

export function inventory(versions) {
	const rows = [];
	for (let id in sort(fs.lsdir(ROOT) ?? [])) {
		if (!valid_id(id)) continue;
		const found = inspect(id);
		if (!found.ok) { push(rows, { id: id, label: id, kind: "plugin", state: "invalid", reason: found.error }); continue; }
		const manifest = found.manifest;
		const dependencies = map(manifest.dependencies, name => ({ id: name, installed_version: versions?.[name] ?? null,
			available: versions == null ? null : versions[name] != null }));
		const reason = maintenance(id) ? "plugin_package_maintenance" : manifest.api_version != API_VERSION ? "plugin_api_incompatible" : index(manifest.backends, KIND) < 0 ?
			"plugin_backend_unsupported" : length(filter(dependencies, item => item.available == false)) ? "plugin_dependency_missing" : null;
		push(rows, { ...manifest, kind: "plugin", revision: found.revision, dependencies: dependencies,
			installed_version: versions?.[manifest.package] ?? null, state: reason == null ? "available" : "unavailable", reason: reason });
	}
	return rows;
};

function execute(found, action, params, work) {
	const request = `${work}/request.json`, status_path = `${work}/exit`;
	let result = fail("plugin_no_response");
	try {
		if (!write_private(request, sprintf("%J", { request: { api_version: API_VERSION, id: found.manifest.id, action: action, params: params ?? {} } })))
			return fail("plugin_request_unavailable");
		// Limit the response pipe, not the plugin's own files or child processes.
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

function invoke(found, action, params) {
	const work = fs.mkdtemp("/tmp/opl-netfleet-plugin.XXXXXX");
	if (work == null) return fail("plugin_request_unavailable");
	if (!fs.chmod(work, 0700)) { fs.rmdir(work); return fail("plugin_request_unavailable"); }
	const result = execute(found, action, params, work);
	fs.unlink(`${work}/request.json`); fs.unlink(`${work}/exit`); fs.rmdir(work);
	return result;
};

function lifecycle(found, action, params) {
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
	return { ok: false, error: rollback.ok && restored.ok && restored.result.loaded == false ? "plugin_load_failed_rolled_back" : "plugin_rollback_unconfirmed" };
};

function request(path, access, drain) {
	if (!private_file(path) || fs.lstat(path).size > LIMIT) return fail("plugin_private_request_required");
	const input = read_json(path)?.request;
	if (type(input) != "object" || !valid_id(input.id) || type(input.action) != "string" ||
		(input.params != null && type(input.params) != "object")) return fail("plugin_request_invalid");
	if (drain && (input.action != "unload" || input.confirm != true || !trusted(MAINTENANCE, "directory") ||
		!trusted(`${MAINTENANCE}/${input.id}`, "directory"))) return fail("plugin_package_maintenance_required");
	if (replacing(input.id)) return drain ? { ok: true, result: { id: input.id, loaded: false, ready: false, state: "replacing" } } : fail("plugin_package_replacing");
	if (drain && input.revision == "absent" && fs.lstat(`${ROOT}/${input.id}/manifest.json`) == null && fs.lstat(`${ROOT}/${input.id}/control`) == null) {
		if (!write_private(`${MAINTENANCE}/${input.id}/replacing`, '{"revision":"absent"}')) return fail("plugin_package_marker_failed");
		return { ok: true, result: { id: input.id, loaded: false, ready: false, state: "replacing" } };
	}
	const found = inspect(input.id);
	if (!found.ok) return found;
	if (action_access(found.manifest, input.action) != access) return fail("plugin_action_not_allowed");
	if (access == "write" && (input.confirm != true || input.revision != found.revision)) return fail("plugin_confirmation_or_revision_required");
	if (input.action != "get" && input.action != "unload") {
		if (maintenance(input.id)) return fail("plugin_package_maintenance");
		if (found.manifest.api_version != API_VERSION) return fail("plugin_api_incompatible");
		if (index(found.manifest.backends, KIND) < 0) return fail("plugin_backend_unsupported");
		for (let name in found.manifest.dependencies)
			if (system(`apk --no-network info -e ${q(name)} >/dev/null 2>&1 || opkg status ${q(name)} 2>/dev/null | grep -q '^Status: .* installed$'`) != 0)
				return fail("plugin_dependency_missing");
	}
	if (index(["get", "load", "unload", "reload"], input.action) < 0) {
		const state = invoke(found, "get", {});
		if (!state.ok || !state.result.loaded || !state.result.ready) return fail("plugin_not_loaded");
	}
	const result = lifecycle(found, input.action, input.params);
	if (drain && result.ok) {
		if (!write_private(`${MAINTENANCE}/${input.id}/replacing`, sprintf("%J", { revision: found.revision }))) return fail("plugin_package_marker_failed");
		return { ok: true, result: { id: input.id, loaded: false, ready: false, state: "replacing" } };
	}
	return result.ok ? { ok: true, result: { ...result.result, id: input.id, revision: found.revision } } : result;
};

export function dispatch(action, path) {
	if (action == "plugins-list") return { ok: true, result: { plugins: inventory(null) } };
	if (index(["plugin-read", "plugin-call", "plugin-drain"], action) < 0) return null;
	// All entry points, including root CLI, serialize writes with the existing network owner.
	const lock = fs.open(LOCK, "ae", 0600);
	if (lock == null || !lock.lock(action == "plugin-read" ? "sn" : "xn")) { lock?.close(); return fail("mutation_busy"); }
	let result;
	try { result = request(path, action == "plugin-read" ? "read" : "write", action == "plugin-drain"); }
	catch (error) { result = fail("plugin_execution_failed"); }
	lock.close();
	return result;
};
