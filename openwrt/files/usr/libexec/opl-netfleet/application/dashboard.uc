import { cursor } from "uci";
import * as fs from "fs";
import { UCI_PACKAGE, RUN_DIR, ROOT_DIR, KIND, API } from "../adapters/runtime.uc";
import { read_yaml, read_json, api_secret, sha256, shell_quote as q } from "../adapters/uci.uc";
import { private_file, private_directory, atomic_json } from "../adapters/native.uc";
import { controller_version } from "../adapters/mihomo.uc";
import { bundled_version } from "../adapters/dashboard_version.uc";
import { API_VERSION } from "../core/extensions.uc";

export const extension = {
	id: "zashboard", label: "Zashboard", api_version: API_VERSION, kind: "resource",
	package: "opl-netfleet", dependencies: ["curl", "ca-bundle", "unzip"],
	permission_class: "dashboard_resources", ui: ["components", "dashboard"],
	commands: {
		"dashboard-get": { method: "get", access: "read", backends: ["native-mihomo", "nikki-mihomo"] },
		"dashboard-check": { method: "check", access: "write", backends: ["native-mihomo"] },
		"dashboard-update": { method: "update", access: "write", backends: ["native-mihomo"] }
	}
};

export function inspection(state) {
	return { available: state?.available ?? false, installed_version: state?.installed_version ?? null, api_version: API_VERSION, error: null };
};

const CACHE_DIR = "/tmp/opl-netfleet-dashboard";
const CACHE = `${CACHE_DIR}/checked.json`;
const RELEASE = "https://api.github.com/repos/Zephyruso/zashboard/releases/latest";
const RELEASE_ROOT = "https://github.com/Zephyruso/zashboard/releases";
const ASSET = "dist-cdn-fonts.zip";
const STATE = `${ROOT_DIR}/dashboard.json`;
const MAX_ARCHIVE = 33554432;
const MAX_EXTRACTED = 134217728;

function capture(command) {
	const pipe = fs.popen(command + " 2>/dev/null");
	if (pipe == null) return null;
	const text = pipe.read("all");
	return pipe.close() == 0 ? trim(text) : null;
};
function shell(command) { return system(command + " >/dev/null 2>&1") == 0; };
function version_valid(value) { return type(value) == "string" && match(value, /^v[0-9]+\.[0-9]+\.[0-9]+$/); };
function error_code(error) {
	const code = trim(split(`${error}`, "\n")[0]);
	return match(code, /^dashboard_[a-z_]+$/) ? code : "dashboard_update_failed";
};
function cache_directory() { return fs.lstat(CACHE_DIR) == null ? fs.mkdir(CACHE_DIR, 0700) : private_directory(CACHE_DIR); };
function configuration() {
	const profile = read_yaml(`${RUN_DIR}/config.yaml`, true);
	const uci = cursor();
	const listen = profile?.["external-controller"] ?? uci.get(UCI_PACKAGE, "mixin", "api_listen");
	const endpoint = type(listen) == "string" ? match(listen, /:([0-9]+)$/) : null;
	const path = profile?.["external-ui"] ?? uci.get(UCI_PACKAGE, "mixin", "ui_path");
	const directory = type(path) == "string" && length(path) ? (substr(path, 0, 1) == "/" ? path : `${RUN_DIR}/${path}`) : null;
	return { port: endpoint == null ? null : int(endpoint[1]), directory: directory,
		secret: profile?.secret ?? uci.get(UCI_PACKAGE, "mixin", "api_secret") ?? "" };
};
function safe_directory(path) {
	if (type(path) != "string" || index(path, `${RUN_DIR}/`) != 0) return false;
	const relative = substr(path, length(RUN_DIR) + 1);
	if (!match(relative, /^[A-Za-z0-9_-]+(\/[A-Za-z0-9_-]+)*$/)) return false;
	let parent = RUN_DIR;
	if (fs.lstat(parent)?.type != "directory") return false;
	for (let segment in split(relative, "/")) {
		parent += `/${segment}`;
		const info = fs.lstat(parent);
		if (info != null && info.type != "directory") return false;
	}
	return true;
};
function installed(directory) {
	const value = private_file(STATE) ? read_json(STATE) : null;
	return value?.directory == directory && version_valid(value?.version) &&
		match(value?.index_sha256 ?? "", /^[a-f0-9]{64}$/) != null &&
		value.index_sha256 == sha256(`${directory}/index.html`) ? value : null;
};
function checked() { return private_file(CACHE) ? read_json(CACHE) : null; };

export function resource() {
	const config = configuration();
	const current = installed(config.directory);
	const version = current?.version ?? bundled_version(config.directory);
	const candidate = checked();
	const safe = safe_directory(config.directory);
	const supported = KIND == "native-mihomo" && safe && shell("command -v unzip");
	return { id: "zashboard", label: "Zashboard", available: fs.stat(`${config.directory}/index.html`)?.type == "file",
		managed: supported, installed_version: version,
		available_version: candidate?.version ?? null,
		update_available: supported && version_valid(candidate?.version) && candidate.version != version,
		checked_at: candidate?.checked_at ?? null, error: candidate?.error ?? null,
		reason: KIND != "native-mihomo" ? "dashboard_managed_externally" : !safe ? "dashboard_path_unmanaged" :
			!supported ? "dashboard_unpacker_unavailable" : null,
		release_url: version_valid(candidate?.version) ? `${RELEASE_ROOT}/tag/${candidate.version}` : null };
};

export function get() {
	const config = configuration();
	return { ok: true, result: {
		available: config.port > 0 && config.port <= 65535 && config.directory != null && fs.stat(`${config.directory}/index.html`)?.type == "file",
		protocol: "http", port: config.port, path: "/ui/", secret: config.secret
	} };
};

export function check() {
	if (KIND != "native-mihomo") return { ok: false, error: "dashboard_managed_externally" };
	if (!cache_directory()) return { ok: false, error: "dashboard_state_unavailable" };
	let metadata = null;
	try { metadata = json(capture(`curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 --max-filesize 1048576 ${q(RELEASE)}`)); } catch (error) {}
	const version = metadata?.tag_name;
	const asset = filter(type(metadata?.assets) == "array" ? metadata.assets : [], item => item?.name == ASSET)[0];
	const valid = version_valid(version) && metadata?.draft == false && metadata?.prerelease == false &&
		asset?.browser_download_url == `${RELEASE_ROOT}/download/${version}/${ASSET}` &&
		type(asset?.size) == "int" && asset.size > 0 && asset.size <= MAX_ARCHIVE &&
		match(asset?.digest ?? "", /^sha256:[a-f0-9]{64}$/) != null;
	const result = valid ? { version: version, url: asset.browser_download_url, size: asset.size,
		sha256: substr(asset.digest, 7), checked_at: int(time()), error: null } :
		{ checked_at: int(time()), error: "dashboard_release_check_failed" };
	if (!atomic_json(CACHE, result)) return { ok: false, error: "dashboard_state_unavailable" };
	return { ok: valid, ...(valid ? {} : { error: result.error }), result: resource() };
};

function archive_valid(path) {
	// Let the platform's maintained ZIP implementation parse the archive. Inspect
	// its entry metadata before extraction to reject links and oversized resources.
	const listing = capture(`unzip -Z -l ${q(path)}`);
	const names = capture(`unzip -Z -1 ${q(path)}`);
	if (listing == null || names == null || length(names) > 262144) return false;
	const entries = split(names, "\n");
	if (!length(entries) || length(entries) > 2048 || index(entries, "dist/index.html") < 0) return false;
	for (let entry in entries) {
		if (length(entry) > 240 || !match(entry, /^dist\/[A-Za-z0-9_./@+-]*$/) ||
			index(split(entry, "/"), "..") >= 0 || index(split(entry, "/"), ".") >= 0) return false;
	}
	let count = 0, total = 0;
	for (let line in split(listing, "\n")) {
		const entry = match(line, /^([-dlbcps?])[rwxstST-]{9}[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+([0-9]+)[[:space:]]/);
		if (entry == null) continue;
		if (entry[1] != "-" && entry[1] != "d") return false;
		count++;
		total += int(entry[2]);
	}
	return count == length(entries) && total > 0 && total <= MAX_EXTRACTED ? total : 0;
};
function tree_valid(path, depth) {
	if (depth > 12 || fs.lstat(path)?.type != "directory") return false;
	for (let name in fs.lsdir(path) ?? []) {
		const child = `${path}/${name}`;
		const info = fs.lstat(child);
		if (info?.type == "directory") { if (!tree_valid(child, depth + 1)) return false; }
		else if (info?.type != "file") return false;
	}
	return true;
};
function remove_owned(path) { return fs.lstat(path) == null || fs.lstat(path)?.type == "directory" && shell(`rm -rf ${q(path)}`); };

export function update(version) {
	const config = configuration();
	const state = resource();
	if (!state.managed) return { ok: false, error: state.reason };
	const candidate = checked();
	if (!version_valid(version) || candidate?.version != version || candidate?.url != `${RELEASE_ROOT}/download/${version}/${ASSET}` ||
		!match(candidate?.sha256 ?? "", /^[a-f0-9]{64}$/) || type(candidate?.size) != "int" || candidate.size <= 0 || candidate.size > MAX_ARCHIVE)
		return { ok: false, error: "dashboard_candidate_changed" };
	const directory = config.directory;
	const stage = `${directory}.netfleet-stage`, previous = `${directory}.netfleet-previous`;
	if (fs.lstat(STATE) != null && !private_file(STATE)) return { ok: false, error: "dashboard_state_unavailable" };
	// Reconcile an interrupted replacement before starting a new one. The version
	// record is committed last, so its index digest distinguishes success from rollback.
	if (fs.lstat(previous) != null) {
		if (fs.lstat(previous)?.type != "directory") return { ok: false, error: "dashboard_recovery_failed" };
		if (installed(directory) != null) {
			if (!remove_owned(previous)) return { ok: false, error: "dashboard_recovery_failed" };
		} else if (!remove_owned(directory) || !fs.rename(previous, directory)) return { ok: false, error: "dashboard_recovery_failed" };
	}
	if (!remove_owned(stage)) return { ok: false, error: "dashboard_stage_unavailable" };
	if (installed(directory)?.version == version) return { ok: true, result: resource() };
	if (!cache_directory()) return { ok: false, error: "dashboard_state_unavailable" };
	const work = capture(`mktemp -d ${q(`${CACHE_DIR}/download.XXXXXX`)}`);
	if (work == null || index(work, `${CACHE_DIR}/download.`) != 0 || !private_directory(work)) return { ok: false, error: "dashboard_stage_unavailable" };
	const archive = `${work}/asset.zip`;
	const previous_state = private_file(STATE) ? read_json(STATE) : null;
	let moved = false, had_previous = false, error = null, recovery = null;
	try {
		if (!shell(`curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 90 --max-filesize ${MAX_ARCHIVE} -o ${q(archive)} ${q(candidate.url)}`)) die("dashboard_download_failed");
		if (fs.stat(archive)?.size != candidate.size || sha256(archive) != candidate.sha256) die("dashboard_asset_mismatch");
		const extracted_bytes = archive_valid(archive);
		if (!extracted_bytes) die("dashboard_archive_invalid");
		const segments = split(directory, "/");
		pop(segments);
		const parent = join("/", segments);
		const available = capture(`df -Pk ${q(RUN_DIR)} | awk 'NR == 2 { print $4 }'`);
		if (!match(available ?? "", /^[0-9]+$/) || int(available) * 1024 < extracted_bytes + 1048576) die("dashboard_insufficient_space");
		if (!shell(`mkdir -p ${q(parent)}`) || !safe_directory(directory) || !fs.mkdir(stage, 0700)) die("dashboard_stage_unavailable");
		if (!shell(`timeout 30 unzip -q ${q(archive)} -d ${q(stage)}`) || !tree_valid(`${stage}/dist`, 0) ||
			fs.stat(`${stage}/dist/index.html`)?.size <= 0) die("dashboard_unpack_failed");
		const index_digest = sha256(`${stage}/dist/index.html`);
		const was_running = controller_version(api_secret(), 2) != null;
		had_previous = fs.lstat(directory) != null;
		if (had_previous && !fs.rename(directory, previous)) die("dashboard_replace_failed");
		moved = true;
		if (!fs.rename(`${stage}/dist`, directory) || sha256(`${directory}/index.html`) != index_digest) die("dashboard_replace_failed");
		if (was_running && !shell(`curl -q -fsS --connect-timeout 2 --max-time 5 ${q(`${API}/ui/`)} -o ${q(`${work}/served.html`)}`)) die("dashboard_readback_failed");
		if (was_running && sha256(`${work}/served.html`) != index_digest) die("dashboard_readback_failed");
		if (!atomic_json(STATE, { version: version, directory: directory, index_sha256: index_digest,
			asset_sha256: candidate.sha256, installed_at: int(time()) })) die("dashboard_state_unavailable");
	} catch (failure) { error = error_code(failure); }
	if (error != null && moved) {
		const restored = remove_owned(directory) && (!had_previous || fs.rename(previous, directory)) &&
			(previous_state == null ? (fs.lstat(STATE) == null || fs.unlink(STATE)) : atomic_json(STATE, previous_state));
		recovery = { ok: restored };
		if (!restored) error = "dashboard_recovery_failed";
	}
	remove_owned(stage);
	remove_owned(work);
	if (error == null) remove_owned(previous);
	return { ok: error == null, ...(error == null ? {} : { error: error }), result: resource(), rollback: recovery };
};

export function dispatch(action, argument) {
	if (action == "get") return get();
	if (action == "check") return check();
	if (action == "update") return update(argument);
	return { ok: false, error: "extension_action_not_allowed" };
};
