import * as fs from "fs";
import * as package_model from "./packages.uc";

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let capture, parsed, directory, fail, error_code, version_valid, product_packages, installed, package_world, recovery_world, restore_world, feed, newer, available, update_process, progress, get, local_stage, start, run_command, refresh_index, archive, private_paths, input_identity, same_inputs, probe_ok, service_running, stop_services, recovery_stop, restore_services, rollback, recover, journal, upgrade, command;

const gateway = context.use("mihomo.gateway");
const dashboard_resource = context.use("dashboard.control").resource;
const operation = context.use("events.operation");
const proxies = context.use("mihomo.controller").proxies;
const select = context.use("mihomo.controller").select;
const controller_version = context.use("mihomo.controller").controller_version;
const private_file = context.use("platform.files").private_file;
const private_directory = context.use("platform.files").private_directory;
const atomic_json = context.use("platform.files").atomic_json;
const KIND = context.use("platform.runtime").KIND;
const RUN_DIR = context.use("platform.runtime").RUN_DIR;
const ROOT_DIR = context.use("platform.runtime").ROOT_DIR;
const SERVICE = context.use("platform.runtime").SERVICE;
const read_json = context.use("platform.storage").read_json;
const q = context.use("platform.process").shell_quote;
const api_secret = context.use("platform.credentials").api_secret;
const sha256 = context.use("platform.storage").sha256;

const ROOT = "/etc/opl-netfleet/package-transactions";
const PENDING = `${ROOT}/pending.json`;
const CACHE = `${ROOT}/checked.json`;
const REQUEST = `${ROOT}/request.json`;
const REPOSITORY = "/etc/apk/repositories.d/opl-netfleet.list";
const UPDATE_SERVICE = "opl-netfleet-update";
const RECOVERY_SERVICE = "opl-netfleet-update-recovery";
const MAIN = "/usr/libexec/opl-netfleet/main.uc";
const UPGRADE_STATE = "/tmp/opl-netfleet-package-upgrade-state";
const PACKAGES = ["opl-netfleet", "luci-app-netfleet", "mihomo-meta"];
const COMPATIBILITY_PACKAGE = "opl-netfleet-https-compat";
const DEPENDENCIES = ["ucode", "ucode-mod-fs", "ucode-mod-uci", "ucode-mod-ubus", "ucode-mod-uloop", "yq", "curl", "ca-bundle", "flock", "unzip", "ip-full", "nftables-json", "kmod-nft-socket", "kmod-nft-tproxy"];

capture = function(command) {
	const pipe = fs.popen(command + " 2>/dev/null");
	if (pipe == null) return null;
	const text = pipe.read("all");
	return pipe.close() == 0 ? trim(text) : null;
};
parsed = function(command) { try { return json(capture(command)); } catch (error) { return null; } };
directory = function(path) { return fs.lstat(path) == null ? fs.mkdir(path, 0700) : private_directory(path); };
fail = function(code) { die(code); };
error_code = function(error) {
	const code = trim(split(`${error}`, "\n")[0]);
	return match(code, /^[a-z][a-z0-9_]+$/) ? code : "component_operation_failed";
};
version_valid = function(value) { return type(value) == "string" && length(value) < 80 && match(value, /^[A-Za-z0-9][A-Za-z0-9._+~:-]*$/); };
product_packages = function() {
	const declared = context.system?.product_packages;
	if (type(declared) != "array" || !length(declared)) fail("product_package_manifest_missing");
	const result = [PACKAGES[0], PACKAGES[1]];
	for (let name in declared) {
		if (name != "opl-netfleet-kernel" && !match(name ?? "", /^opl-netfleet-plugin-[a-z][a-z0-9-]*$/))
			fail("product_package_manifest_invalid");
		if (index(result, name) < 0) push(result, name);
	}
	return result;
};
installed = function() {
	const rows = parsed("apk --no-network query --from installed --format json --fields name,version '*'");
	if (type(rows) != "array" || !length(rows)) return null;
	const result = {};
	for (let row in rows) if (version_valid(row.version)) result[row.name] = row.version;
	return result;
};
package_world = function() {
	const text = fs.readfile("/etc/apk/world");
	if (text == null) fail("package_world_unavailable");
	const result = {};
	for (let line in split(text, "\n")) {
		const constraint = trim(line);
		if (!length(constraint)) continue;
		const name = match(constraint, /^([a-z0-9][a-z0-9+_.-]*)([@<>=~]|$)/)?.[1];
		if (name == null) fail("package_world_invalid");
		result[name] = constraint;
	}
	return result;
};
recovery_world = function(names, before) {
	// Reconcile stale checksum roots left by an older installer copying world
	// after APK replacement. Never restore a checksum that is not installed.
	const identities = {};
	for (let record in split(fs.readfile("/lib/apk/db/installed") ?? "", "\n\n")) {
		const name = match(record, /(^|\n)P:([^\n]+)/)?.[2];
		const digest = match(record, /(^|\n)C:([^\n]+)/)?.[2];
		if (name != null && digest != null) identities[name] = digest;
	}
	const result = { ...before };
	for (let name in names) {
		const pin = `${name}><`;
		if (index(before[name] ?? "", pin) != 0) continue;
		if (identities[name] == null) fail("package_world_identity_unavailable");
		if (before[name] != `${pin}${identities[name]}`) result[name] = name;
	}
	return result;
};
restore_world = function(names, before, work, rollback, changed, candidates) {
	// Explicit upgrades move exact-version pins to the selected candidate. Range and
	// repository constraints remain intact; rollback restores the previous intent.
	const expected = {};
	for (let name in names) {
		const updating = !rollback && (changed == null || index(changed, name) >= 0);
		expected[name] = updating && index(before[name] ?? "", `${name}><`) == 0 ? name : before[name];
		if (updating && candidates?.[name] != null && index(before[name] ?? "", `${name}=`) == 0)
			expected[name] = `${name}=${candidates[name]}`;
	}
	const roots = filter(names, name => expected[name] != null);
	if (length(roots) && !run_command(`apk --no-network --repositories-file /dev/null add ${join(" ", map(roots, name => q(expected[name])))}`, work)) return false;
	const dependencies = filter(names, name => expected[name] == null);
	if (length(dependencies) && !run_command(`apk --no-network --repositories-file /dev/null del ${join(" ", map(dependencies, q))}`, work)) return false;
	const after = package_world();
	for (let name in names) if (after[name] != expected[name]) return false;
	for (let name in keys(before)) if (index(names, name) < 0 && after[name] != before[name]) return false;
	for (let name in keys(after)) if (index(names, name) < 0 && before[name] != after[name]) return false;
	return true;
};
feed = function() {
	const lines = split(fs.readfile(REPOSITORY) ?? "", "\n");
	for (let line in lines) {
		line = trim(line);
		if (match(line, /^https?:\/\/[^[:space:]@]+\/packages\.adb$/)) return line;
	}
	return null;
};
newer = function(candidate, current) {
	return version_valid(candidate) && version_valid(current) && capture(`apk version --test ${q(current)} ${q(candidate)}`) == "<";
};
available = function(url) {
	const managed = [...product_packages(), PACKAGES[2], COMPATIBILITY_PACKAGE];
	const rows = parsed(`apk --no-network query --from none -X ${q(url)} --format json --fields name,version ${join(" ", map(managed, q))}`);
	if (type(rows) != "array") return null;
	const result = {};
	for (let row in rows) if (index(managed, row.name) >= 0 && version_valid(row.version) &&
		(result[row.name] == null || newer(row.version, result[row.name]))) result[row.name] = row.version;
	return result;
};
function plugin_catalog() {
	const rows = parsed("apk --no-network query --from repositories --all-matches --format json --fields name,version,description,depends,repositories 'opl-netfleet-plugin-*'");
	const result = {};
	for (let row in rows ?? []) {
		if (!match(row.name ?? "", /^opl-netfleet-plugin-[a-z][a-z0-9-]*$/) || !version_valid(row.version)) continue;
		if (result[row.name] == null || newer(row.version, result[row.name].version)) result[row.name] = row;
	}
	return result;
}
function plugin_packages(versions, product, catalog) {
	const names = sort(keys(catalog ?? {}));
	for (let name in keys(versions ?? {})) if (match(name, /^opl-netfleet-plugin-[a-z][a-z0-9-]*$/) && index(names, name) < 0) push(names, name);
	return map(filter(names, name => index(product, name) < 0), name => ({
		name, id: substr(name, length("opl-netfleet-plugin-")), description: catalog?.[name]?.description,
		installed_version: versions?.[name] ?? null, available_version: catalog?.[name]?.version ?? null,
		update_available: newer(catalog?.[name]?.version, versions?.[name]), dependencies: catalog?.[name]?.depends ?? []
	}));
}
function plugin_plan(request, work, preview) {
	if (type(request) != "object") fail("invalid_plugin_package_request");
	const versions = installed();
	if (versions == null) fail("package_manager_unavailable");
	if (!match(request.name ?? "", /^opl-netfleet-plugin-[a-z][a-z0-9-]*$/) || index(product_packages(), request.name) >= 0)
		fail("plugin_package_protected");
	if (request.action != "remove" && !version_valid(request.version)) fail("invalid_plugin_package_request");
	if (request.action == "remove") {
		const id = substr(request.name, length("opl-netfleet-plugin-"));
		if (context.system.enabled?.[id] == true) fail("plugin_disable_before_remove");
		const row = filter(context.inventory(versions), item => item.id == id && item.kind == "plugin")[0];
		if (row == null) fail("plugin_not_installed");
		if (row.runtime == "process") {
			if (!directory(ROOT)) fail("unsafe_update_directory");
			const path = capture(`mktemp ${q(`${ROOT}/plugin-state.XXXXXX`)}`);
			if (path == null || !private_file(path)) fail("update_state_write_failed");
			if (!atomic_json(path, { request: { id, action: "get", revision: row.revision } })) fail("update_state_write_failed");
			const state = parsed(`ucode ${q(MAIN)} plugin-read ${q(path)}`);
			fs.unlink(path);
			if (state?.ok != true || state.result?.loaded != false) fail("plugin_disable_before_remove");
		}
		for (let name, binding in context.system.bindings ?? {}) if (binding == id) fail("plugin_package_required");
	}
	const argument = request.action == "remove" ? `del ${q(request.name)}` : `add ${q(`${request.name}=${request.version}`)}`;
	const output = capture(`LC_ALL=C apk --no-network --simulate ${argument}`);
	if (output == null) fail("plugin_dependencies_unavailable");
	const plan = package_model.validate(package_model.changes(output), preview ? { ...request, confirm: true } : request, versions, product_packages());
	if (!preview && sprintf("%J", request.plan) != sprintf("%J", plan)) fail("candidate_changed");
	return plan;
}
update_process = function() {
	const data = parsed(`ubus call service list '${sprintf('%J', { name: UPDATE_SERVICE })}'`);
	return data?.[UPDATE_SERVICE]?.instances?.update;
};
progress = function() {
	const state = operation.get("packages");
	const request = private_file(REQUEST) ? read_json(REQUEST) : null;
	const process = update_process();
	const pending = private_file(PENDING) ? read_json(PENDING) : null;
	if (pending && process?.running != true) {
		const recovering = service_running(RECOVERY_SERVICE);
		return { id: pending.id, kind: "packages", state: recovering ? "running" : "interrupted", phase: "rolling_back", error: recovering ? null : "previous_update_incomplete", recovery: "required" };
	}
	if (request != null && state?.id != request.id) {
		const terminal = private_file(`${ROOT}/${request.id}/journal.json`) ? read_json(`${ROOT}/${request.id}/journal.json`) : null;
		if (index(["complete", "rolled_back"], terminal?.phase) >= 0)
			return { id: request.id, kind: "packages", state: terminal.phase == "complete" ? "succeeded" : "failed", phase: "verifying",
				started_at: request.started_at, updated_at: terminal.finished_at ?? null, finished_at: terminal.finished_at ?? null,
				error: terminal.phase == "complete" ? null : terminal.error ?? "update_interrupted_rolled_back", recovery: terminal.phase == "rolled_back" ? "restored" : null,
				can_cancel: false, write_started: terminal.write_started == true };
		const running = process?.running == true;
		return { id: request.id, kind: "packages", state: running ? "queued" : "interrupted", phase: "preparing", started_at: request.started_at,
			updated_at: request.started_at, finished_at: null, completed: 0, total: null, subject: request.component, error: running ? null : "operation_interrupted",
			can_cancel: running && request.action != "check", cancel_requested: fs.lstat(`${ROOT}/${request.id}/cancel.json`) != null, write_started: false };
	}
	const journal = request ? read_json(`${ROOT}/${request.id}/journal.json`) : null;
	return state == null ? null : { ...state,
		can_cancel: state.id == request?.id && request.action != "check" && process?.running == true && index(["running", "queued"], state.state) >= 0 && !journal?.write_started &&
			index(["installing", "verifying", "rolling_back"], state.phase) < 0,
		cancel_requested: request != null && fs.lstat(`${ROOT}/${request.id}/cancel.json`) != null,
		write_started: journal?.write_started == true };
};

// The short transaction lock serializes cancellation with the first package write.
// It is independent of the network lock held by the durable update worker.
function cancel_update(id) {
	const request = private_file(REQUEST) ? read_json(REQUEST) : null;
	if (!match(id ?? "", /^[a-f0-9]{32}$/) || request?.id != id || request.action == "check") fail("update_operation_changed");
	const work = `${ROOT}/${id}`;
	if (!private_directory(work)) fail("unsafe_update_directory");
	if (fs.lstat(`${work}/control.lock`) != null && !private_file(`${work}/control.lock`)) fail("unsafe_update_directory");
	const lock = fs.open(`${work}/control.lock`, "ae", 0600);
	if (lock == null || !lock.lock("xn")) { lock?.close(); fail("update_transition_busy"); }
	let result;
	try {
		const state = read_json(`${work}/journal.json`);
		if (state?.write_started || index(["complete", "rolled_back", "installing", "recovering"], state?.phase) >= 0 || update_process()?.running != true)
			fail("update_cancel_unavailable");
		if (!atomic_json(`${work}/cancel.json`, { id })) fail("update_state_write_failed");
		result = { requested: true, id };
	} catch (error) { lock.close(); die(error_code(error)); }
	lock.close(); return result;
}
function cancellation(work) {
	if (private_file(`${work}/cancel.json`)) fail("update_cancelled");
}
function lifecycle(action, id) {
	const pipe = fs.popen(`NETFLEET_PACKAGE_RESTORE=1 ucode ${q(MAIN)} plugin-package-${action} ${q(id)} 2>/dev/null`);
	if (pipe == null) return null;
	let result;
	try { result = json(pipe.read("all")); } catch (error) {}
	const code = pipe.close();
	return code == 0 || result?.ok == false ? result : null;
}
function resume_resources(work) {
	const state = read_json(`${work}/journal.json`);
	let success = true;
	for (let id in reverse([...(state?.drained ?? [])])) {
		const result = lifecycle("resume", id);
		if (result?.ok != true) success = false;
	}
	return success;
}
function prepare_resources(work, names, versions, candidates) {
	const ids = [];
	for (let name in names) {
		if (versions[name] == candidates[name]) continue;
		if (versions[name] == null) continue;
		const id = name == "mihomo-meta" ? "mihomo" : name == COMPATIBILITY_PACKAGE ? "https-compat" :
			match(name, /^opl-netfleet-plugin-([a-z][a-z0-9-]*)$/)?.[1];
		if (id != null && index(ids, id) < 0) push(ids, id);
		if (name == "opl-netfleet-kernel") for (let item in context.inventory(versions))
			if (item.kind == "plugin" && match(item.id ?? "", /^[a-z][a-z0-9-]*$/) && index(ids, item.id) < 0) push(ids, item.id);
	}
	for (let id in ids) {
		cancellation(work);
		const state = read_json(`${work}/journal.json`);
		journal(work, { ...state, phase: "draining", drained: [...(state.drained ?? []), id] });
		operation.update("draining", { subject: id, total: 0, completed: 0 });
		let result;
		for (let attempt = 0; attempt < 3; attempt++) {
			result = lifecycle("drain", id);
			if (result?.ok || result?.error != "plugin_calls_draining") break;
			cancellation(work); system("sleep 1");
		}
		cancellation(work);
		if (result?.ok != true) fail(result?.error == "healthy_connections_still_draining" || result?.error == "plugin_calls_draining" ? "update_deferred" : "update_prepare_failed");
	}
}
get = function() {
	const versions = installed();
	const url = feed();
	const checked = private_file(CACHE) ? read_json(CACHE) : null;
	const cache = checked?.feed == url ? checked : null;
	const candidates = cache?.versions ?? {};
	const product = product_packages();
	const missing = filter(product, name => versions != null && versions[name] == null);
	const updates = filter(product, name => newer(candidates[name], versions?.[name]));
	const running = controller_version(api_secret(), 2);
	const binary = capture("mihomo -v");
	const binary_version = match(binary ?? "", /^Mihomo[[:space:]]+([^[:space:]]+)/)?.[1] ?? null;
	const rows = [];
	for (let item in [["netfleet", "NetFleet", PACKAGES[0]], ["luci", "LuCI 接入组件", PACKAGES[1]], ["mihomo", "Mihomo", PACKAGES[2]]]) {
		const current = versions?.[item[2]] ?? null;
		const candidate = candidates[item[2]] ?? null;
		const managed = versions != null && current != null && (item[0] != "mihomo" || KIND == "native-mihomo");
		const update = managed && (item[0] == "netfleet" ? length(updates) > 0 && version_valid(candidate) : newer(candidate, current));
		push(rows, { id: item[0], label: item[1], installed_version: current ?? (item[0] == "mihomo" ? binary_version : null),
			running_version: item[0] == "mihomo" ? running : null, available_version: update ? candidate : null,
			update_available: update, managed: managed,
			reason: !managed ? (item[0] == "mihomo" ? "core_managed_externally" : "package_not_installed") : null });
	}
	const dashboard = dashboard_resource();
	return { supported: versions != null, backend: KIND, architecture: capture("apk --print-arch"),
		feed: { configured: url != null, url: url, checked_at: cache?.checked_at, error: cache?.error }, components: rows,
		plugin_packages: plugin_packages(versions, product, cache?.plugin_catalog),
		dashboard: dashboard, extensions: context.inventory(versions),
		product: { packages: map(product, name => ({ name, installed_version: versions?.[name], available_version: candidates[name] })), missing, updates },
		dependencies: map(DEPENDENCIES, name => ({ id: name, label: name, installed_version: versions?.[name], available: versions?.[name] != null })) };
};
local_stage = function(path) {
	if (type(path) != "string" || !private_directory(path) || !private_file(`${path}/request.json`)) fail("unsafe_update_directory");
	const value = read_json(`${path}/request.json`);
	if (value?.schema != "opl-netfleet-plugin-install.v1" || type(value.packages) != "array" || !length(value.packages)) fail("invalid_plugin_install_request");
	const versions = installed(), managed = product_packages(), names = [], candidates = {};
	if (versions == null) fail("package_manager_unavailable");
	const expected = { old: [], new: [] };
	for (let item in value.packages) {
		const name = item.name;
		if (type(name) != "string" || (name != "luci-app-netfleet" && !match(name, /^opl-netfleet-plugin-[a-z][a-z0-9-]*$/)) || index(managed, name) < 0 || index(names, name) >= 0 ||
			!version_valid(item.version) || !version_valid(item.before_version)) fail("invalid_plugin_install_request");
		if (versions[name] != item.before_version) fail("installed_version_changed");
		if (newer(item.before_version, item.version)) fail("plugin_downgrade_rejected");
		push(names, name); candidates[name] = item.version;
		for (let kind in ["old", "new"]) {
			const version = kind == "old" ? item.before_version : item.version;
			const digest = kind == "old" ? item.before_sha256 : item.sha256;
			const file = `${name}-${version}.apk`;
			if (!match(digest ?? "", /^[a-f0-9]{64}$/) || !private_directory(`${path}/${kind}`) ||
				!private_file(`${path}/${kind}/${file}`) || sha256(`${path}/${kind}/${file}`) != digest) fail("plugin_archive_changed");
			if (archive(name, version, `${path}/${kind}`, path) == null) fail("plugin_archive_invalid");
			push(expected[kind], file);
		}
	}
	for (let kind in ["old", "new"])
		if (sprintf("%J", sort(fs.lsdir(`${path}/${kind}`) ?? [])) != sprintf("%J", sort(expected[kind]))) fail("unexpected_plugin_archive");
	return { names, candidates, packages: value.packages };
};
start = function(action, component, version) {
	if (!directory(ROOT)) fail("unsafe_update_directory");
	if (fs.lstat(PENDING) != null) fail("previous_update_incomplete");
	if (update_process()?.running == true) fail("mutation_busy");
	const staged = action == "install" ? local_stage(component) : null;
	const plugin = action == "plugin" && private_file(component) ? read_json(component)?.request : null;
	if (action == "plugin" && type(plugin) != "object") fail("invalid_plugin_package_request");
	if (plugin) plugin_plan(plugin);
	if (action != "install" && plugin?.action != "remove" && feed() == null) fail("feed_not_configured");
	if (action == "update" && (index(["netfleet", "mihomo"], component) < 0 || !version_valid(version))) fail("invalid_component_request");
	if (action != "check" && (fs.lstat(PENDING) != null || fs.lstat(UPGRADE_STATE) != null)) fail("previous_update_incomplete");
	// Only the latest completed transaction is retained; unfinished recovery is never removed.
	const previous = private_file(REQUEST) ? read_json(REQUEST) : null;
	if (previous && match(previous.id ?? "", /^[a-f0-9]{32}$/)) {
		const oldwork = `${ROOT}/${previous.id}`;
		const state = operation.get("packages");
		const terminal = private_file(`${oldwork}/journal.json`) ? read_json(`${oldwork}/journal.json`) : null;
		const safe = index(["complete", "rolled_back"], terminal?.phase) >= 0 || terminal == null ||
			state?.id == previous.id && (state.state == "succeeded" ||
			state.state == "failed" && match(state.error ?? "", /_rolled_back$/));
		if (!safe && fs.lstat(`${oldwork}/before.json`) != null) fail("previous_update_incomplete");
		if (private_directory(oldwork))
			system(`rm -rf ${q(oldwork)}`);
	}
	const id = replace(capture("cat /proc/sys/kernel/random/uuid"), "-", "");
	if (!match(id ?? "", /^[a-f0-9]{32}$/)) fail("update_identity_unavailable");
	const request = { id: id, action: action, plugin, component: staged || plugin ? "plugins" : component, version: version, started_at: time(), feed: staged ? null : feed(), packages: staged?.packages, names: staged?.names, candidates: staged?.candidates };
	// Keep the executing code independent of packages that will replace themselves.
	const work = `${ROOT}/${id}`;
	if (!directory(work) || system(`cp -R ${q(context.root)} ${q(`${work}/code`)}`) != 0 || !atomic_json(`${work}/code/system.json`, context.system) ||
		!atomic_json(`${work}/control-api.json`, { version: 1 }) || !atomic_json(REQUEST, request) || !atomic_json(`${work}/request.json`, request)) fail("update_stage_failed");
	if (staged) {
		for (let kind in ["old", "new"]) {
			if (!directory(`${work}/${kind}`)) fail("update_stage_failed");
			for (let file in fs.lsdir(`${component}/${kind}`))
				if (!run_command(`cp ${q(`${component}/${kind}/${file}`)} ${q(`${work}/${kind}/${file}`)}`, work)) fail("update_stage_failed");
		}
		if (!atomic_json(`${work}/request.json`, { ...request, schema: "opl-netfleet-plugin-install.v1" })) fail("update_state_write_failed");
		local_stage(work);
	}
	const service = { name: UPDATE_SERVICE, instances: { update: {
		command: ["/usr/bin/flock", "-w", "10", "/var/lock/opl-netfleet-deploy.lock", "/usr/bin/ucode", `${work}/code/main.uc`, "components-run", `${work}/request.json`],
		term_timeout: 30, stdout: false, stderr: false
	} } };
	if (capture(`ubus call service add ${q(sprintf("%J", service))}`) == null) fail("update_start_failed");
	return { operation: progress() };
};
run_command = function(command, work) {
	return system(`${command} >>${q(`${work}/log`)} 2>&1`) == 0;
};
refresh_index = function(request, work) {
	operation.update("checking");
	const success = run_command("apk --timeout 30 update", work);
	const values = success ? available(request.feed) : null;
	const checked = { feed: request.feed, checked_at: time(), versions: values ?? {}, plugin_catalog: success ? plugin_catalog() : {}, error: values == null ? "feed_check_failed" : null };
	if (!atomic_json(CACHE, checked)) fail("update_state_write_failed");
	if (values == null) fail("feed_check_failed");
	return values;
};
function archive_repository(path) { return replace(path, /[^/]+$/, "packages.adb"); }
function system_archive(name) { return type(name) == "string" && !match(name, /^(opl-netfleet|luci-app-netfleet)/); }
function archive_arguments(paths) {
	const result = [];
	for (let path in paths) {
		const repository = archive_repository(path);
		if (fs.stat(repository) == null) { push(result, q(path)); continue; }
		const info = parsed(`apk adbdump --format json ${q(path)}`)?.info;
		if (!system_archive(info?.name) || !version_valid(info.version)) fail("rollback_package_unavailable");
		push(result, `-X ${q(repository)} ${q(`${info.name}=${info.version}`)}`);
	}
	return join(" ", result);
}
function archive_valid(path, work) {
	if (run_command(`apk --no-network verify ${q(path)}`, work)) return true;
	const repository = archive_repository(path);
	if (fs.stat(repository) == null) return false;
	const info = parsed(`apk adbdump --format json ${q(path)}`)?.info;
	if (!system_archive(info?.name) || !version_valid(info.version)) return false;
	const rows = parsed(`apk --no-network query --from none -X ${q(repository)} --all-matches --format json --fields name,version ${q(info.name)}`);
	if (!length(filter(rows ?? [], row => row.name == info.name && row.version == info.version))) return false;
	// Repository fetch authenticates the index and every package data block, even
	// when the upstream archive has no individual signature. Never allow untrusted.
	return run_command(`(apk --no-network fetch --from none -X ${q(repository)} --all-matches --stdout ${q(info.name)} >/dev/null)`, work);
}
archive = function(name, version, path, work, fallback_version, source) {
	const target = `${path}/${name}-${version}.apk`;
	const cached = `${ROOT}/archives/${name}-${version}.apk`;
	if (fs.stat(target) == null && private_file(cached)) run_command(`cp ${q(cached)} ${q(target)}`, work);
	if (fs.stat(target) == null) {
		const from = source ? `--from none -X ${q(source)}` : "--from repositories";
		const rows = parsed(`apk --no-network query ${from} --all-matches --format json --fields name,version,repositories ${q(name)}`);
		const exact = filter(rows ?? [], row => row.name == name && row.version == version)[0];
		let fetched = false;
		// APK 3 fetch without --recursive matches names, not dependency constraints.
		for (let repository in exact?.repositories ?? []) {
			if (run_command(`apk --timeout 30 fetch --from none -X ${q(repository)} --all-matches --output ${q(path)} ${q(name)}`, work) && fs.stat(target) != null) {
				fetched = true;
				break;
			}
		}
		if (!fetched) {
			const release = match(fallback_version ?? "", /^([0-9]+\.[0-9]+\.[0-9]+)(-r[0-9]+)?$/)?.[1];
			if (source || name == "mihomo-meta" || release == null || !run_command(`curl -q -fsSL --connect-timeout 10 --max-time 90 -o ${q(target)} ${q(`https://github.com/gaofeng21cn/opl-netfleet/releases/download/v${release}/${name}-${version}.apk`)}`, work)) return null;
		}
	}
	const metadata = parsed(`apk adbdump --format json ${q(target)}`);
	const architecture = trim(fs.readfile("/etc/apk/arch") ?? "") || capture("apk --print-arch");
	if (metadata?.info?.name != name || metadata.info.version != version ||
		index(["noarch", architecture], metadata.info.arch) < 0) return null;
	if (run_command(`apk --no-network verify ${q(target)}`, work)) return target;
	// Only an existing third-party core may use signed-repository authentication.
	// Our candidates and our own packages must remain individually signed.
	if (source || !system_archive(name)) return null;
	const rows = parsed(`apk --no-network query --from repositories --all-matches --format json --fields name,version,repositories ${q(name)}`);
	const exact = filter(rows ?? [], row => row.name == name && row.version == version)[0];
	const retained = `${path}/repository-${name}`;
	if (!directory(retained) || !fs.rename(target, `${retained}/${name}-${version}.apk`)) return null;
	const retained_package = `${retained}/${name}-${version}.apk`;
	for (let repository in exact?.repositories ?? []) {
		if (!match(repository, /^https?:\/\/[^?#]+\/packages\.adb$/)) continue;
		if (run_command(`curl -q -fsSL --connect-timeout 10 --max-time 45 -o ${q(`${retained}/packages.adb`)} ${q(repository)}`, work) &&
			archive_valid(retained_package, work)) return retained_package;
	}
	return null;
};
private_paths = function() {
	return filter(["/etc/config/netfleet", "/etc/opl-netfleet/policy.json", "/etc/opl-netfleet/backend.json", "/etc/opl-netfleet/system.json",
		"/etc/opl-netfleet/plugins",
		`${ROOT_DIR}/profiles`, `${ROOT_DIR}/subscriptions`, `${ROOT_DIR}/mixin.json`, `${ROOT_DIR}/mixin.yaml`,
		...(KIND == "nikki-mihomo" ? ["/etc/config/nikki"] : [])], path => fs.lstat(path) != null);
};
input_identity = function(paths) {
	const entries = {};
	function visit(path) {
		const info = fs.lstat(path);
		if (info?.type == "directory") {
			for (let name in sort(fs.lsdir(path) ?? [])) visit(`${path}/${name}`);
		} else if (info?.type == "file") entries[path] = sha256(path);
		else if (info?.type == "link") entries[path] = `link:${fs.readlink(path)}`;
		else entries[path] = null;
	};
	for (let path in paths) visit(path);
	return entries;
};
same_inputs = function(before) {
	return sprintf("%J", input_identity(before.paths)) == sprintf("%J", before.inputs);
};
probe_ok = function() {
	const value = parsed(`ucode ${q(MAIN)} probe`);
	return value?.ok == true && value.result?.ok == true;
};
service_running = function(name) {
	const services = parsed(`ubus call service list ${q(sprintf("%J", { name: name }))}`);
	for (let key, instance in services?.[name]?.instances ?? {}) if (instance.running == true) return true;
	return false;
};
stop_services = function(work) {
	// A scheduler stop error must not prevent the data-plane owner from cleaning up.
	run_command("/etc/init.d/opl-netfleet stop", work);
	run_command(`/etc/init.d/${SERVICE} stop`, work);
	for (let attempt = 0; attempt < 20; attempt++) {
		if (!service_running("opl-netfleet") && !service_running(SERVICE)) {
			// The installed command is intentionally hidden while its plugin is
			// draining. Read cleanup through this transaction's retained owner.
			return KIND != "native-mihomo" || gateway.status()?.result?.clean == true;
		}
		system("sleep 1");
	}
	return false;
};
restore_services = function(before, work) {
	const deadline = time() + 45;
	if (before.core && !service_running(SERVICE) && !run_command(`NETFLEET_PACKAGE_RESTORE=1 /etc/init.d/${SERVICE} start`, work)) return false;
	if (before.core) {
		let ready = false;
		while (time() < deadline) {
			if (!same_inputs(before)) return false;
			const secret = api_secret();
			const current = controller_version(secret, 2) != null ? proxies(secret, 2)?.proxies : null;
			ready = current != null;
			for (let name, choice in before.selections) {
				if (index(current?.[name]?.all ?? [], choice) < 0) { ready = false; continue; }
				if (current[name].now != choice && !select(secret, name, choice)) ready = false;
			}
			const restored = ready ? proxies(secret, 2)?.proxies : null;
			for (let name, choice in before.selections) if (restored?.[name]?.now != choice) ready = false;
			if (ready) break;
			system("sleep 1");
		}
		if (!ready) return false;
	}
	if (before.supervisor && !service_running("opl-netfleet") && !run_command("NETFLEET_PACKAGE_RESTORE=1 /etc/init.d/opl-netfleet start", work)) return false;
	if (before.unconfigured) return !before.core && same_inputs(before);
	// Controller readiness precedes provider loading, gateway attachment and working DNS.
	while (time() < deadline) {
		if (!same_inputs(before)) return false;
		const status = parsed(`ucode ${q(MAIN)} status`)?.result;
		if (status != null && status.active == before.active && (!before.core ||
			(status.runtime?.controller_available == true && (KIND != "native-mihomo" ||
			(status.runtime?.lan_runtime?.dns_ready == true && status.runtime?.lan_runtime?.transparent_proxy_ready == true)) && probe_ok()))) return true;
		system("sleep 1");
	}
	return false;
};
rollback = function(before, work, names, versions, old, install_started, already_stopped) {
	const errors = [];
	function attempt(code, action) {
		try { if (action()) return true; } catch (error) {}
		push(errors, code);
		return false;
	}
	const stopped = already_stopped || attempt("rollback_stop_failed", () => before.scoped ? drain_scoped(work) : stop_services(work));
	if (stopped) {
		if (install_started) fs.unlink(UPGRADE_STATE);
		attempt("rollback_configuration_failed", () => run_command(`tar -xf ${q(`${work}/private.tar`)} -C /`, work));
		if (install_started) {
			const added = filter(names, name => versions[name] == null);
			if (length(added)) attempt("rollback_install_failed", () => run_command(`NETFLEET_PACKAGE_RESTORE=1 apk --preserve-env --no-network --repositories-file /dev/null del ${join(" ", map(added, q))}`, work));
			// Restore the known-good hook implementation before APK invokes it.
			// A failed candidate may have installed a core start hook that cannot
			// run, including while earlier dependency packages are rolling back.
			const hooks_restored = attempt("rollback_runtime_files_failed", () =>
				run_command(`tar -xf ${q(`${work}/runtime.tar`)} -C /`, work) &&
				sprintf("%J", input_identity(before.runtime_paths)) == sprintf("%J", before.runtime_inputs));
			if (hooks_restored && length(old)) attempt("rollback_install_failed", () => run_command(`NETFLEET_PACKAGE_RESTORE=1 apk --preserve-env --no-network --repositories-file /dev/null ${already_stopped ? "--force-reinstall " : ""}add ${archive_arguments(old)}`, work));
			attempt("rollback_world_failed", () => restore_world(names, before.world, work, true));
			attempt("rollback_runtime_files_failed", () => run_command(`tar -xf ${q(`${work}/runtime.tar`)} -C /`, work));
			attempt("rollback_runtime_failed", () => resume_resources(work));
		}
	}
	// APK may complete the requested change and still report earlier script failures.
	// Reconcile before deciding whether the old runtime can be restored.
	const restored = installed();
	const identity = restored != null && !length(filter(names, name => restored[name] != versions[name])) &&
		attempt("rollback_identity_mismatch", () => sprintf("%J", input_identity(before.runtime_paths)) == sprintf("%J", before.runtime_inputs));
	const inputs = attempt("rollback_configuration_failed", () => same_inputs(before));
	if (!identity) push(errors, "rollback_identity_mismatch");
	const runtime = identity && inputs && attempt("rollback_runtime_failed", () => restore_services(before, work));
	if (!runtime && !before.scoped) {
		attempt("rollback_stop_failed", () => stop_services(work));
	}
	atomic_json(`${work}/rollback.json`, { errors: errors, identity: identity, private_inputs: inputs, runtime_restored: runtime });
	return errors[0] ?? null;
};
function drain_scoped(work) {
	let ok = true;
	for (let id in read_json(`${work}/journal.json`)?.drained ?? []) if (lifecycle("drain", id)?.ok != true) ok = false;
	return ok;
}
function core_space_available(bytes, work) {
	for (let location in ["/usr/libexec", work]) {
		const available_kb = capture(`df -Pk ${q(location)} | awk 'NR == 2 { print $4 }'`);
		if (type(bytes) != "int" || bytes <= 0 || !match(available_kb ?? "", /^[0-9]+$/) || int(available_kb) * 1024 < bytes)
			return false;
	}
	return true;
}
upgrade = function(request, work, candidates) {
	const names = request.component == "plugins" ? request.names : request.component == "netfleet" ? product_packages() : [PACKAGES[2]];
	const versions = installed();
	if (versions == null) fail("package_manager_unavailable");
	if (request.component == "netfleet" && versions[COMPATIBILITY_PACKAGE] != null &&
		version_valid(candidates[COMPATIBILITY_PACKAGE])) push(names, COMPATIBILITY_PACKAGE);
	if (fs.lstat(UPGRADE_STATE) != null) fail("previous_update_incomplete");
	if (request.component == "mihomo" && (KIND != "native-mihomo" || versions[PACKAGES[2]] == null)) fail("core_managed_externally");
	if (request.component != "plugins" && candidates[request.component == "netfleet" ? PACKAGES[0] : PACKAGES[2]] != request.version)
		fail("candidate_changed");
	for (let name in names) {
		if (!version_valid(candidates[name]) && request.plugin?.action != "remove") fail("candidate_changed");
		// A plugin updated independently may be newer than the current product feed.
		if (newer(versions[name], candidates[name])) candidates[name] = versions[name];
	}
	if (!request.plugin && !length(filter(names, name => newer(candidates[name], versions[name])))) {
		journal(work, { phase: "complete", names, versions, candidates, no_change: true });
		return;
	}
	if (request.component == "mihomo") {
		const metadata = parsed(`apk --no-network query --from none -X ${q(request.feed)} --all-matches --format json --fields name,version,installed-size mihomo-meta`);
		const candidate = filter(metadata ?? [], row => row.name == PACKAGES[2] && row.version == candidates[PACKAGES[2]])[0];
		if (type(candidate?.["installed-size"]) != "int" || candidate["installed-size"] <= 0) fail("candidate_changed");
		if (!core_space_available(candidate["installed-size"], work)) fail("insufficient_update_space");
	}
	const space = capture(`df -Pk ${q(ROOT)} | awk 'NR == 2 { print $4 }'`);
	const footprint = capture(`du -sk ${q(`${work}/code`)} | awk '{print $1}'`);
	if (!match(space ?? "", /^[0-9]+$/) || !match(footprint ?? "", /^[0-9]+$/) || int(space) < int(footprint) * 3 + 8192) fail("insufficient_update_space");
	const olddir = `${work}/old`, nextdir = `${work}/new`;
	if (!directory(olddir) || !directory(nextdir)) fail("update_stage_failed");
	const old = [], next = [];
	const build = read_json("/usr/share/opl-netfleet/build.json");
	operation.update("downloading", { total: length(filter(names, name => versions[name] != null)) + length(filter(names, name => candidates[name] != null)), completed: 0 });
	for (let name in names) {
		cancellation(work);
		if (versions[name] == null && !request.plugin) fail("package_not_installed");
		const rollback = versions[name] == null ? null : archive(name, versions[name], olddir, work, build?.version, null);
		if (versions[name] != null && rollback == null) fail("rollback_package_unavailable");
		if (rollback != null) push(old, rollback);
		operation.update("downloading", { completed: length(old) + length(next) });
		if (candidates[name] == null) continue;
		const candidate = candidates[name] == versions[name] ? rollback :
			archive(name, candidates[name], nextdir, work, null, request.plugin ? null : request.feed);
		if (candidate == null) fail("candidate_download_failed");
		push(next, candidate);
		operation.update("downloading", { completed: length(old) + length(next) });
	}
	operation.update("validating");
	cancellation(work);
	if (length(old) && !run_command(`apk --no-network --repositories-file /dev/null --simulate add ${archive_arguments(old)}`, work)) fail("rollback_package_unavailable");
	// Only installed dependencies and the explicitly downloaded packages may participate.
	if (length(next) && !run_command(`apk --no-network --repositories-file /dev/null --simulate add ${archive_arguments(next)}`, work)) fail("package_validation_failed");
	if (request.component == "mihomo") {
		const bytes = parsed(`apk adbdump --format json ${q(next[0])}`)?.info?.["installed-size"];
		if (!core_space_available(bytes, work)) fail("insufficient_update_space");
	}
	const before_status = parsed(`ucode ${q(MAIN)} status`)?.result;
	const unconfigured = fs.lstat("/etc/opl-netfleet/policy.json") == null && !service_running(SERVICE);
	if (before_status == null && !unconfigured) fail("runtime_readback_failed");
	const paths = private_paths();
	const before = { backend: KIND, core_enabled: capture(`/etc/init.d/${SERVICE} enabled`) != null, supervisor_enabled: capture("/etc/init.d/opl-netfleet enabled") != null, active: before_status?.active ?? false, unconfigured: unconfigured, core: service_running(SERVICE), supervisor: service_running("opl-netfleet"), selections: {}, paths: paths, inputs: input_identity(paths), world: package_world() };
	before.scoped = request.plugin != null;
	before.original_world = before.world;
	before.world = recovery_world(names, before.world);
	before.runtime_paths = filter(["/usr/libexec/opl-netfleet", "/usr/libexec/opl-netfleet-plugin-package",
		"/usr/share/opl-netfleet", "/etc/init.d/opl-netfleet", "/etc/init.d/opl-netfleet-update-recovery", `/etc/init.d/${SERVICE}`,
		...(request.component == "mihomo" ? ["/usr/libexec/mihomo"] : [])], path => fs.lstat(path) != null);
	if (before.scoped) before.runtime_paths = filter([
		`/usr/libexec/opl-netfleet/plugins/${substr(request.plugin.name, length("opl-netfleet-plugin-"))}`,
		`/www/luci-static/resources/netfleet/plugins/${substr(request.plugin.name, length("opl-netfleet-plugin-"))}`
	], path => fs.lstat(path) != null);
	before.runtime_inputs = input_identity(before.runtime_paths);
	if (before.core) {
		const all = proxies(api_secret(), 2)?.proxies;
		if (all == null || !probe_ok()) fail("runtime_precondition_failed");
		for (let name, value in all) if (value.type == "Selector" && value.now != null) before.selections[name] = value.now;
	}
	if (request.component == "mihomo" && before.core) {
		const extracted = `${work}/extracted`;
		if (!directory(extracted) || !run_command(`apk extract --destination ${q(extracted)} ${q(next[0])}`, work) ||
			!run_command(`${q(`${extracted}/usr/libexec/mihomo`)} -t -d ${q(RUN_DIR)} -f ${q(`${RUN_DIR}/config.yaml`)}`, work)) fail("core_config_incompatible");
	}
	if (system("/etc/init.d/opl-netfleet-update-recovery enable >/dev/null 2>&1") != 0) fail("update_recovery_unavailable");
	if (!atomic_json(`${work}/before.json`, before) || !run_command(`tar -cf ${q(`${work}/private.tar`)} -C / ${join(" ", map(paths, path => q(substr(path, 1))))}`, work)) fail("update_state_write_failed");
	if (!run_command(`tar -cf ${q(`${work}/runtime.tar`)} -C / ${length(before.runtime_paths) ? join(" ", map(before.runtime_paths, path => q(substr(path, 1)))) : "-T /dev/null"}`, work)) fail("update_state_write_failed");
	journal(work, { phase: "prepared", write_started: false, drained: [], before, names, versions, candidates, old, next, inputs: input_identity([`${work}/private.tar`, `${work}/runtime.tar`, `${work}/code`, olddir, nextdir]) });
	if (!atomic_json(PENDING, { id: request.id }) || system("sync") != 0) fail("update_state_write_failed");
	let error = null;
	let install_started = false;
	try {
		if (request.plugin) {
			const fresh = plugin_plan(request.plugin, work);
			if (sprintf("%J", fresh) != sprintf("%J", { names, candidates })) fail("candidate_changed");
		}
		prepare_resources(work, names, versions, candidates);
		if (fs.lstat(`${work}/control.lock`) != null && !private_file(`${work}/control.lock`)) fail("unsafe_update_directory");
		const lock = fs.open(`${work}/control.lock`, "ae", 0600);
		if (lock == null || !lock.lock("x")) { lock?.close(); fail("update_transition_busy"); }
		try {
			cancellation(work);
			journal(work, { ...read_json(`${work}/journal.json`), phase: "installing", write_started: true });
		} catch (error) { lock.close(); die(error_code(error)); }
		lock.close();
		operation.update("installing", { subject: request.component, total: 0, completed: 0 });
		if (request.component != "plugins" && !stop_services(work)) fail("runtime_stop_failed");
		install_started = true;
		// Explicit package hooks may resume drained resource owners while pending
		// continues to block unrelated starts until this transaction is verified.
		// APK otherwise strips the restore flag from the hook environment.
		const replacing = request.plugin?.action == "remove" ? `del ${q(request.plugin.name)}` : `add ${archive_arguments(next)}`;
		if (!run_command(`NETFLEET_PACKAGE_RESTORE=1 apk --preserve-env --no-network --repositories-file /dev/null ${replacing}`, work)) fail("package_install_failed");
		const desired_world = { ...before.world };
		if (request.plugin?.action == "install") desired_world[request.plugin.name] = request.plugin.name;
		if (request.plugin?.action == "remove") delete desired_world[request.plugin.name];
		if (!restore_world(names, desired_world, work, false, filter(names, name => versions[name] != candidates[name]), candidates)) fail("package_world_restore_failed");
		if (request.plugin?.action == "remove") {
			if (lifecycle("remove", substr(request.plugin.name, length("opl-netfleet-plugin-")))?.ok != true) fail("update_resume_failed");
		} else if (!resume_resources(work)) fail("update_resume_failed");
		operation.update("verifying");
		const after = installed();
		for (let name in names) if (after?.[name] != candidates[name]) fail("package_identity_mismatch");
		if (request.plugin) for (let name in keys(versions)) if (index(names, name) < 0 && after?.[name] != versions[name]) fail("package_identity_mismatch");
		if (!same_inputs(before)) fail("private_configuration_changed");
		if (!restore_services(before, work)) fail("runtime_verification_failed");
	} catch (failure) { error = error_code(failure); }
	if (error == null) {
		// Keep installed signed plugin archives available when a feed advances.
		if (directory(`${ROOT}/archives`)) for (let path in next) {
			const name = replace(path, /^.*\//, "");
			if (match(name, /^opl-netfleet-plugin-/) && run_command(`cp ${q(path)} ${q(`${ROOT}/archives/${name}`)}`, work))
				fs.chmod(`${ROOT}/archives/${name}`, 0600);
		}
		journal(work, { ...read_json(`${work}/journal.json`), phase: "complete" }); fs.unlink(PENDING); system("sync"); return;
	}
	journal(work, { ...read_json(`${work}/journal.json`), failure_reason: error });
	operation.update("rolling_back");
	if (!install_started) {
		if (!resume_resources(work) || !same_inputs(before) || !restore_services(before, work)) fail("rollback_runtime_failed");
		journal(work, { ...read_json(`${work}/journal.json`), phase: "rolled_back", write_started: false, error: `${error}_rolled_back` });
		fs.unlink(PENDING); system("sync"); fail(`${error}_rolled_back`);
	}
	const recovery_error = rollback(before, work, names, versions, old, install_started);
	if (recovery_error != null) fail(recovery_error);
	journal(work, { ...read_json(`${work}/journal.json`), phase: "rolled_back", error: `${error}_rolled_back` });
	fs.unlink(PENDING); system("sync");
	fail(`${error}_rolled_back`);
};


journal = function(work, value) {
	if (index(["complete", "rolled_back"], value.phase) >= 0) value.finished_at = int(time());
	if (!atomic_json(`${work}/journal.json`, value) || system("sync") != 0) fail("update_state_write_failed");
};
recovery_stop = function(work) {
	if (KIND != "native-mihomo") return stop_services(work);
	// Use the retained owner, since installed init hooks may be partially replaced.
	if (gateway.cleanup()?.ok != true) return false;
	for (let name in ["opl-netfleet", SERVICE])
		if (parsed(`ubus call service list ${q(sprintf("%J", { name }))}`)?.[name] != null && !run_command(`ubus call service delete ${q(sprintf("%J", { name }))}`, work)) return false;
	for (let attempt = 0; attempt < 20; attempt++) {
		if (!service_running("opl-netfleet") && !service_running(SERVICE) &&
			capture("pidof mihomo") == null && gateway.status()?.result?.clean == true) return true;
		system("sleep 1");
	}
	return false;
};
recover = function() {
	if (fs.lstat(PENDING) == null) return { recovered: false };
	const pending = private_file(PENDING) ? read_json(PENDING) : null;
	if (!match(pending?.id ?? "", /^[a-f0-9]{32}$/)) fail("update_recovery_state_invalid");
	operation.begin("packages", "rolling_back", { id: pending.id, subject: "netfleet" });
	const work = `${ROOT}/${pending.id}`;
	const state = private_file(`${work}/journal.json`) ? read_json(`${work}/journal.json`) : null;
	if (!state || state.before?.backend != KIND || !private_directory(work) || type(state.inputs) != "object" ||
		index(["prepared", "draining", "installing", "recovering", "complete", "rolled_back"], state.phase) < 0) fail("update_recovery_state_invalid");
	for (let path, digest in state.inputs) if (index(path, `${work}/`) != 0 || sha256(path) != digest) fail("update_recovery_artifact_changed");
	const recovered_error = state.error ?? (state.failure_reason ? `${state.failure_reason}_rolled_back` : "update_interrupted_rolled_back");
	if (index(["complete", "rolled_back"], state.phase) >= 0) {
		const expected = state.phase == "complete" ? state.candidates : state.versions;
		const current = installed();
		if (type(expected) != "object" || type(state.names) != "array") fail("update_recovery_state_invalid");
		for (let name in state.names) if (current?.[name] != expected[name]) fail("rollback_identity_mismatch");
		if (!same_inputs(state.before) || !restore_services(state.before, work)) fail("rollback_runtime_failed");
		fs.unlink(PENDING); system("sync");
		operation.finish(state.phase == "complete", state.phase == "complete" ? null : recovered_error,
			state.phase == "rolled_back" ? { rollback: { ok: true } } : null);
		return { recovered: true };
	}
	const before = state.before, old = state.old, names = state.names, versions = state.versions;
	if (type(old) != "array" || type(names) != "array" || type(versions) != "object") fail("update_recovery_state_invalid");
	if (state.write_started == false) {
		const current = installed();
		if (length(filter(names, name => current?.[name] != versions[name])) || !same_inputs(before) ||
			!resume_resources(work) || !restore_services(before, work)) fail("rollback_runtime_failed");
		journal(work, { ...state, phase: "rolled_back" }); fs.unlink(PENDING); system("sync");
		operation.finish(false, recovered_error, { rollback: { ok: true } });
		return { recovered: true };
	}
	for (let path in old) if (index(path, `${work}/old/`) != 0 || !archive_valid(path, work)) fail("rollback_package_unavailable");
	journal(work, { ...state, phase: "recovering" });
	if (!(before.scoped ? drain_scoped(work) : recovery_stop(work))) fail("rollback_stop_failed");
	if (!run_command(`tar -xf ${q(`${work}/runtime.tar`)} -C /`, work) ||
		sprintf("%J", input_identity(before.runtime_paths)) != sprintf("%J", before.runtime_inputs)) fail("rollback_identity_mismatch");
	// The marker protects a kernel generation; only release it after restoring all old bytes.
	fs.unlink("/var/run/opl-netfleet-plugin-maintenance/.kernel");
	const recovery_error = rollback(before, work, names, versions, old, true, true);
	if (recovery_error != null) fail(recovery_error);
	if (!run_command(`/etc/init.d/${SERVICE} ${before.core_enabled ? "enable" : "disable"}`, work) ||
		!run_command(`/etc/init.d/opl-netfleet ${before.supervisor_enabled ? "enable" : "disable"}`, work)) fail("rollback_runtime_failed");
	journal(work, { ...state, phase: "rolled_back", error: recovered_error });
	fs.unlink(PENDING); system("sync"); operation.finish(false, recovered_error, { rollback: { ok: true } });
	return { recovered: true };
};

command = function(argv) {
	const ARGV = [substr(argv[0], 11), ...slice(argv, 1)];

let response;
try {
	if (ARGV[0] == "recover") response = { ok: true, result: recover() };
	else if (ARGV[0] == "cancel") response = { ok: true, result: cancel_update(ARGV[1]) };
	else if (ARGV[0] == "get") response = { ok: true, result: get() };
	else if (ARGV[0] == "plugin-plan") response = { ok: true, result: plugin_plan(private_file(ARGV[1]) ? read_json(ARGV[1])?.request : null, null, true) };
	else if (ARGV[0] == "operation") response = { ok: true, result: { mode: operation.get("mode"), configuration: operation.get("configuration"), subscription: operation.get("subscription"), selection: operation.get("selection"), packages: progress() } };
	else if (index(["install", "check", "update", "plugin"], ARGV[0]) >= 0) response = { ok: true, result: start(ARGV[0], ARGV[1], ARGV[2]) };
	else if (ARGV[0] == "run") {
		const request = private_file(ARGV[1]) ? read_json(ARGV[1]) : null;
		if (request == null || !match(request.id ?? "", /^[a-f0-9]{32}$/) || ARGV[1] != `${ROOT}/${request.id}/request.json` ||
			index(["check", "update", "install", "plugin"], request.action) < 0 || (request.action != "install" && request.feed != feed())) fail("update_request_changed");
		const work = `${ROOT}/${request.id}`;
		operation.begin("packages", "checking", { id: request.id, subject: request.component ?? "feed" });
		const staged = request.action == "install" ? local_stage(work) : null;
		if (staged) { request.component = "plugins"; request.names = staged.names; }
		let candidates = staged ? staged.candidates : request.plugin?.action == "remove" ? {} : refresh_index(request, work);
		if (request.plugin) {
			const plan = plugin_plan(request.plugin, work);
			request.names = plan.names; candidates = plan.candidates;
		}
		if (request.action != "check") upgrade(request, work, candidates);
		operation.finish(true, null, null);
		response = { ok: true };
	} else response = { ok: false, error: "unknown_component_action" };
} catch (error) {
	const reason = error_code(error);
	if (ARGV[0] == "run" || ARGV[0] == "recover") operation.finish(false, reason,
		match(reason, /_rolled_back$/) ? { rollback: { ok: true } } :
		match(reason, /^rollback_(stop|configuration|install|identity|runtime|world)_/) ? { rollback: { ok: false } } : null);
	response = { ok: false, error: reason };
}
printf("%J\n", response);
exit(response.ok ? 0 : 1);
};

return { get, command };
};
