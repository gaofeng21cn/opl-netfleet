#!/usr/bin/ucode

import * as fs from "fs";
import { read_json, shell_quote as q, api_secret, sha256 } from "../adapters/uci.uc";
import { private_file, private_directory, atomic_json } from "../adapters/native.uc";
import { KIND, RUN_DIR, ROOT_DIR, SERVICE } from "../adapters/runtime.uc";
import { proxies, select, controller_version } from "../adapters/mihomo.uc";
import * as operation from "./operation.uc";
import { resource as dashboard_resource } from "./dashboard.uc";

const ROOT = "/tmp/opl-netfleet-components";
const CACHE = `${ROOT}/checked.json`;
const REQUEST = `${ROOT}/request.json`;
const REPOSITORY = "/etc/apk/repositories.d/opl-netfleet.list";
const UPDATE_SERVICE = "opl-netfleet-update";
const MAIN = "/usr/libexec/opl-netfleet/main.uc";
const UPGRADE_STATE = "/tmp/opl-netfleet-package-upgrade-state";
const PACKAGES = ["opl-netfleet", "luci-app-netfleet", "mihomo-meta"];
const DEPENDENCIES = ["ucode", "ucode-mod-fs", "ucode-mod-uci", "ucode-mod-ubus", "ucode-mod-uloop", "yq", "curl", "ca-bundle", "flock", "unzip", "ip-full", "nftables-json", "kmod-nft-socket", "kmod-nft-tproxy"];

function capture(command) {
	const pipe = fs.popen(command + " 2>/dev/null");
	if (pipe == null) return null;
	const text = pipe.read("all");
	return pipe.close() == 0 ? trim(text) : null;
};
function parsed(command) { try { return json(capture(command)); } catch (error) { return null; } };
function directory(path) { return fs.lstat(path) == null ? fs.mkdir(path, 0700) : private_directory(path); };
function fail(code) { die(code); };
function error_code(error) {
	const code = trim(split(`${error}`, "\n")[0]);
	return match(code, /^[a-z][a-z0-9_]+$/) ? code : "component_operation_failed";
};
function version_valid(value) { return type(value) == "string" && length(value) < 80 && match(value, /^[A-Za-z0-9][A-Za-z0-9._+~:-]*$/); };
function installed() {
	const rows = parsed("apk --no-network query --from installed --format json --fields name,version '*'");
	if (type(rows) != "array" || !length(rows)) return null;
	const result = {};
	for (let row in rows) if (version_valid(row.version)) result[row.name] = row.version;
	return result;
};
function feed() {
	const lines = split(fs.readfile(REPOSITORY) ?? "", "\n");
	for (let line in lines) {
		line = trim(line);
		if (match(line, /^https?:\/\/[^[:space:]@]+\/packages\.adb$/)) return line;
	}
	return null;
};
function newer(candidate, current) {
	return version_valid(candidate) && version_valid(current) && capture(`apk version --test ${q(current)} ${q(candidate)}`) == "<";
};
function available(url) {
	const rows = parsed(`apk --no-network query --from none -X ${q(url)} --format json --fields name,version ${join(" ", PACKAGES)}`);
	if (type(rows) != "array") return null;
	const result = {};
	for (let row in rows) if (index(PACKAGES, row.name) >= 0 && version_valid(row.version) &&
		(result[row.name] == null || newer(row.version, result[row.name]))) result[row.name] = row.version;
	return result;
};
function update_process() {
	const data = parsed(`ubus call service list '${sprintf('%J', { name: UPDATE_SERVICE })}'`);
	return data?.[UPDATE_SERVICE]?.instances?.update;
};
function progress() {
	const state = operation.get("packages");
	const request = private_file(REQUEST) ? read_json(REQUEST) : null;
	const process = update_process();
	if (request != null && state?.id != request.id) {
		const running = process?.running == true;
		return { id: request.id, kind: "packages", state: running ? "queued" : "interrupted", phase: "preparing", started_at: request.started_at,
			updated_at: request.started_at, finished_at: null, completed: 0, total: null, subject: request.component, error: running ? null : "operation_interrupted" };
	}
	return state;
};
function get() {
	const versions = installed();
	const url = feed();
	const checked = private_file(CACHE) ? read_json(CACHE) : null;
	const cache = checked?.feed == url ? checked : null;
	const candidates = cache?.versions ?? {};
	const running = controller_version(api_secret(), 2);
	const binary = capture("mihomo -v");
	const binary_version = match(binary ?? "", /^Mihomo[[:space:]]+([^[:space:]]+)/)?.[1] ?? null;
	const rows = [];
	for (let item in [["netfleet", "NetFleet", PACKAGES[0]], ["luci", "LuCI 界面", PACKAGES[1]], ["mihomo", "Mihomo", PACKAGES[2]]]) {
		const current = versions?.[item[2]] ?? null;
		const candidate = candidates[item[2]] ?? null;
		const managed = versions != null && current != null && (item[0] != "mihomo" || KIND == "native-mihomo");
		push(rows, { id: item[0], label: item[1], installed_version: current ?? (item[0] == "mihomo" ? binary_version : null),
			running_version: item[0] == "mihomo" ? running : null, available_version: candidate,
			update_available: managed && newer(candidate, current), managed: managed,
			reason: !managed ? (item[0] == "mihomo" ? "core_managed_externally" : "package_not_installed") : null });
	}
	return { supported: versions != null, backend: KIND, architecture: capture("apk --print-arch"),
		feed: { configured: url != null, url: url, checked_at: cache?.checked_at, error: cache?.error }, components: rows,
		dashboard: dashboard_resource(),
		dependencies: map(DEPENDENCIES, name => ({ id: name, label: name, installed_version: versions?.[name], available: versions?.[name] != null })) };
};
function start(action, component, version) {
	if (!directory(ROOT)) fail("unsafe_update_directory");
	if (update_process()?.running == true) fail("mutation_busy");
	if (feed() == null) fail("feed_not_configured");
	if (action == "update" && (index(["netfleet", "mihomo"], component) < 0 || !version_valid(version))) fail("invalid_component_request");
	if (action == "update" && fs.lstat(UPGRADE_STATE) != null) fail("previous_update_incomplete");
	// Only the latest completed transaction is retained; unfinished recovery is never removed.
	const previous = private_file(REQUEST) ? read_json(REQUEST) : null;
	if (previous && match(previous.id ?? "", /^[a-f0-9]{32}$/)) {
		const oldwork = `${ROOT}/${previous.id}`;
		const state = operation.get("packages");
		const safe = state?.id == previous.id && (state.state == "succeeded" ||
			state.state == "failed" && match(state.error ?? "", /_rolled_back$/));
		if (!safe && fs.lstat(`${oldwork}/before.json`) != null) fail("previous_update_incomplete");
		if (private_directory(oldwork))
			system(`rm -rf ${q(oldwork)}`);
	}
	const id = replace(capture("cat /proc/sys/kernel/random/uuid"), "-", "");
	if (!match(id ?? "", /^[a-f0-9]{32}$/)) fail("update_identity_unavailable");
	const request = { id: id, action: action, component: component, version: version, started_at: time(), feed: feed() };
	// Keep the executing code independent of packages that will replace themselves.
	const work = `${ROOT}/${id}`;
	if (!directory(work) || system(`cp -R /usr/libexec/opl-netfleet ${q(`${work}/code`)}`) != 0 || !atomic_json(REQUEST, request) || !atomic_json(`${work}/request.json`, request)) fail("update_stage_failed");
	const service = { name: UPDATE_SERVICE, instances: { update: {
		command: ["/usr/bin/flock", "-w", "10", "/var/lock/opl-netfleet-deploy.lock", "/usr/bin/ucode", `${work}/code/application/components.uc`, "run", `${work}/request.json`],
		term_timeout: 30, stdout: false, stderr: false
	} } };
	if (capture(`ubus call service add ${q(sprintf("%J", service))}`) == null) fail("update_start_failed");
	return { operation: progress() };
};
function run_command(command, work) {
	return system(`${command} >>${q(`${work}/log`)} 2>&1`) == 0;
};
function refresh_index(request, work) {
	operation.update("checking");
	const success = run_command(`apk --timeout 30 --repositories-file ${q(REPOSITORY)} update`, work);
	const values = success ? available(request.feed) : null;
	const checked = { feed: request.feed, checked_at: time(), versions: values ?? {}, error: values == null ? "feed_check_failed" : null };
	if (!atomic_json(CACHE, checked)) fail("update_state_write_failed");
	if (values == null) fail("feed_check_failed");
	return values;
};
function archive(name, version, path, work, fallback_version, source) {
	const target = `${path}/${name}-${version}.apk`;
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
	if (!run_command(`apk --no-network verify ${q(target)}`, work)) return null;
	const metadata = parsed(`apk adbdump --format json ${q(target)}`);
	const architecture = trim(fs.readfile("/etc/apk/arch") ?? "") || capture("apk --print-arch");
	if (metadata?.info?.name != name || metadata.info.version != version ||
		index(["noarch", architecture], metadata.info.arch) < 0) return null;
	return target;
};
function private_paths() {
	return filter(["/etc/config/netfleet", "/etc/opl-netfleet/policy.json", "/etc/opl-netfleet/backend.json",
		`${ROOT_DIR}/profiles`, `${ROOT_DIR}/subscriptions`, `${ROOT_DIR}/mixin.json`, `${ROOT_DIR}/mixin.yaml`,
		...(KIND == "nikki-mihomo" ? ["/etc/config/nikki"] : [])], path => fs.lstat(path) != null);
};
function input_identity(paths) {
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
function same_inputs(before) {
	return sprintf("%J", input_identity(before.paths)) == sprintf("%J", before.inputs);
};
function probe_ok() {
	const value = parsed(`ucode ${q(MAIN)} probe`);
	return value?.ok == true && value.result?.ok == true;
};
function service_running(name) {
	const services = parsed(`ubus call service list ${q(sprintf("%J", { name: name }))}`);
	for (let key, instance in services?.[name]?.instances ?? {}) if (instance.running == true) return true;
	return false;
};
function stop_services(work) {
	if (!run_command("/etc/init.d/opl-netfleet stop", work) || !run_command(`/etc/init.d/${SERVICE} stop`, work)) return false;
	for (let attempt = 0; attempt < 20; attempt++) {
		if (!service_running("opl-netfleet") && !service_running(SERVICE)) {
			return KIND != "native-mihomo" || parsed("ucode /usr/libexec/opl-netfleet/application/native_gateway.uc status")?.result?.clean == true;
		}
		system("sleep 1");
	}
	return false;
};
function restore_services(before, work) {
	if (before.core && !run_command(`/etc/init.d/${SERVICE} start`, work)) return false;
	if (before.core) {
		let ready = false;
		for (let attempt = 0; attempt < 20; attempt++) {
			if (controller_version(api_secret(), 2) != null) { ready = true; break; }
			system("sleep 1");
		}
		if (!ready) return false;
		const secret = api_secret();
		const current = proxies(secret, 2)?.proxies ?? {};
		for (let name, choice in before.selections) {
			if (index(current[name]?.all ?? [], choice) < 0 || !select(secret, name, choice)) return false;
		}
		const restored = proxies(secret, 2)?.proxies ?? {};
		for (let name, choice in before.selections) if (restored[name]?.now != choice) return false;
	}
	if (before.supervisor && !run_command("/etc/init.d/opl-netfleet start", work)) return false;
	const status = parsed(`ucode ${q(MAIN)} status`)?.result;
	if (before.unconfigured) return !before.core && same_inputs(before);
	if (status == null || status.active != before.active) return false;
	if (before.core && (status.runtime?.controller_available != true ||
		(KIND == "native-mihomo" && (status.runtime?.lan_runtime?.dns_ready != true || status.runtime?.lan_runtime?.transparent_proxy_ready != true)))) return false;
	return same_inputs(before) && (!before.core || probe_ok());
};
function upgrade(request, work, candidates) {
	const names = request.component == "netfleet" ? [PACKAGES[0], PACKAGES[1]] : [PACKAGES[2]];
	const versions = installed();
	if (versions == null) fail("package_manager_unavailable");
	if (fs.lstat(UPGRADE_STATE) != null) fail("previous_update_incomplete");
	if (request.component == "mihomo" && (KIND != "native-mihomo" || versions[PACKAGES[2]] == null)) fail("core_managed_externally");
	for (let name in names) if (candidates[name] != request.version) fail("candidate_changed");
	if (!length(filter(names, name => newer(candidates[name], versions[name])))) return;
	const olddir = `${work}/old`, nextdir = `${work}/new`;
	if (!directory(olddir) || !directory(nextdir)) fail("update_stage_failed");
	const old = [], next = [];
	const build = read_json("/usr/share/opl-netfleet/build.json");
	operation.update("downloading", { total: length(names) * 2, completed: 0 });
	for (let name in names) {
		if (versions[name] == null) fail("package_not_installed");
		const rollback = archive(name, versions[name], olddir, work, build?.version, null);
		if (rollback == null) fail("rollback_package_unavailable");
		push(old, rollback);
		operation.update("downloading", { completed: length(old) + length(next) });
		const candidate = archive(name, candidates[name], nextdir, work, null, request.feed);
		if (candidate == null) fail("candidate_download_failed");
		push(next, candidate);
		operation.update("downloading", { completed: length(old) + length(next) });
	}
	operation.update("validating");
	// Only installed dependencies and the explicitly downloaded packages may participate.
	if (!run_command(`apk --no-network --repositories-file /dev/null --simulate add ${join(" ", map(next, q))}`, work)) fail("package_validation_failed");
	if (request.component == "mihomo") {
		const bytes = parsed(`apk adbdump --format json ${q(next[0])}`)?.info?.["installed-size"];
		for (let location in ["/usr/libexec", work]) {
			const available_kb = capture(`df -Pk ${q(location)} | awk 'NR == 2 { print $4 }'`);
			if (type(bytes) != "int" || bytes <= 0 || !match(available_kb ?? "", /^[0-9]+$/) || int(available_kb) * 1024 < bytes)
				fail("insufficient_update_space");
		}
	}
	const before_status = parsed(`ucode ${q(MAIN)} status`)?.result;
	const unconfigured = fs.lstat("/etc/opl-netfleet/policy.json") == null && !service_running(SERVICE);
	if (before_status == null && !unconfigured) fail("runtime_readback_failed");
	const paths = private_paths();
	const before = { active: before_status?.active ?? false, unconfigured: unconfigured, core: service_running(SERVICE), supervisor: service_running("opl-netfleet"), selections: {}, paths: paths, inputs: input_identity(paths) };
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
	if (!atomic_json(`${work}/before.json`, before) || !run_command(`tar -cf ${q(`${work}/private.tar`)} -C / ${join(" ", map(paths, path => q(substr(path, 1))))}`, work)) fail("update_state_write_failed");
	let error = null;
	let install_started = false;
	try {
		operation.update("installing");
		if (!stop_services(work)) fail("runtime_stop_failed");
		install_started = true;
		if (!run_command(`apk --no-network --repositories-file /dev/null add ${join(" ", map(next, q))}`, work)) fail("package_install_failed");
		operation.update("verifying");
		const after = installed();
		for (let name in names) if (after?.[name] != candidates[name]) fail("package_identity_mismatch");
		if (!same_inputs(before)) fail("private_configuration_changed");
		if (!restore_services(before, work)) fail("runtime_verification_failed");
	} catch (failure) { error = error_code(failure); }
	if (error == null) return;
	operation.update("rolling_back");
	if (!stop_services(work)) fail("rollback_stop_failed");
	// A pre-existing marker was rejected before mutation; only our install could create it.
	if (install_started) fs.unlink(UPGRADE_STATE);
	if (!run_command(`tar -xf ${q(`${work}/private.tar`)} -C /`, work)) fail("rollback_configuration_failed");
	if (install_started && !run_command(`apk --no-network --repositories-file /dev/null add ${join(" ", map(old, q))}`, work)) fail("rollback_install_failed");
	const restored = installed();
	for (let name in names) if (restored?.[name] != versions[name]) fail("rollback_identity_mismatch");
	if (!restore_services(before, work)) fail("rollback_runtime_failed");
	fail(`${error}_rolled_back`);
};

let response;
try {
	if (ARGV[0] == "get") response = { ok: true, result: get() };
	else if (ARGV[0] == "operation") response = { ok: true, result: { subscription: operation.get("subscription"), packages: progress() } };
	else if (ARGV[0] == "check" || ARGV[0] == "update") response = { ok: true, result: start(ARGV[0], ARGV[1], ARGV[2]) };
	else if (ARGV[0] == "run") {
		const request = private_file(ARGV[1]) ? read_json(ARGV[1]) : null;
		if (request == null || !match(request.id ?? "", /^[a-f0-9]{32}$/) || ARGV[1] != `${ROOT}/${request.id}/request.json` ||
			index(["check", "update"], request.action) < 0 || request.feed != feed()) fail("update_request_changed");
		const work = `${ROOT}/${request.id}`;
		operation.begin("packages", "checking", { id: request.id, subject: request.component ?? "feed" });
		const candidates = refresh_index(request, work);
		if (request.action == "update") upgrade(request, work, candidates);
		operation.finish(true, null, null);
		response = { ok: true };
	} else response = { ok: false, error: "unknown_component_action" };
} catch (error) {
	const reason = error_code(error);
	if (ARGV[0] == "run") operation.finish(false, reason,
		match(reason, /_rolled_back$/) ? { rollback: { ok: true } } :
		match(reason, /^rollback_(stop|configuration|install|identity|runtime)_/) ? { rollback: { ok: false } } : null);
	response = { ok: false, error: reason };
}
printf("%J\n", response);
exit(response.ok ? 0 : 1);
