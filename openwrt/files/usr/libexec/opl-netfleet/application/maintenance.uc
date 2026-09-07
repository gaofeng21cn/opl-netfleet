import * as fs from "fs";
import { cursor } from "uci";
import { read_json, read_yaml, sha256, sha256_text, shell_quote as q, current_profile, api_secret, POLICY_PATH, EVIDENCE_PATH } from "../adapters/uci.uc";
import { BASE, private_file, private_directory, write_private, atomic_json } from "../adapters/native.uc";
import { KIND, RUN_DIR, SERVICE, LOG_PATH } from "../adapters/runtime.uc";
import { COMPILED_PROFILE, ARTIFACT_PATH, MANIFEST_PATH, stop, resolve_profile, prepare_provider_links, remove_provider_links } from "../adapters/backend.uc";
import { proxies, select, controller_version } from "../adapters/mihomo.uc";
import { service_state, set_service_state } from "../adapters/service.uc";
import { validate as validate_policy } from "../core/policy.uc";
import { load as load_providers } from "./providers.uc";
import { BACKUP_FORMAT, MAX_PROFILE_BYTES, MAX_BACKUP_BYTES, profile_id, file_path, profile_referenced, validate_backup, redact_line } from "../core/maintenance.uc";

const ROOT = "/etc/opl-netfleet";
const CONFIG = "/etc/config/netfleet";
const PROFILES = `${BASE}/profiles`;
const MAIN = "/usr/libexec/opl-netfleet/main.uc";
const GATEWAY = "/usr/libexec/opl-netfleet/application/native_gateway.uc";

function failure(error, result) { return { ok: false, error: error, result: result }; };
function capture(command) {
	const pipe = fs.popen(command + " 2>/dev/null");
	if (pipe == null) return null;
	const value = pipe.read("all");
	return pipe.close() == 0 ? value : null;
};
function parsed(command) { try { return json(capture(command)); } catch (error) { return null; } };
function shell(command) { return system(command + " >/dev/null 2>&1") == 0; };
function gateway() { return parsed(`ucode ${q(GATEWAY)} status`)?.result; };
function native_ready() { return KIND == "native-mihomo" && private_directory(BASE) && private_file(CONFIG); };
function directory(path) {
	const info = fs.lstat(path);
	return info == null ? fs.mkdir(path, 0700) : info.type == "directory" && info.uid == 0 && (info.mode & 022) == 0;
};
function parent(path) { return join("/", slice(split(path, "/"), 0, -1)); };
function prepare_directory(path) {
	if (path == ROOT) return fs.lstat(ROOT)?.type == "directory";
	return index(path, `${ROOT}/`) == 0 && prepare_directory(parent(path)) && directory(path);
};
function readable_input(path) {
	const relative = index(path, `${ROOT}/`) == 0 ? substr(path, length(ROOT) + 1) : null;
	const public_resource = relative != null && file_path(relative) &&
		(match(relative, /^policy-sources\//) ||
		 match(relative, /^native\/(run\/)?(rulesets|geodata)\//) ||
		 match(relative, /^native\/(run\/)?providers\/rule\//) ||
		 match(relative, /\.(mrs|mmdb|dat)$/));
	if (!public_resource) return private_file(path);
	const info = fs.lstat(path);
	return info?.type == "file" && info.uid == 0 && (info.mode & 022) == 0;
};
function safe_target(path) {
	return prepare_directory(parent(path)) && (fs.lstat(path) == null || readable_input(path));
};
function profile_entries() {
	const policy = read_json(POLICY_PATH), selected = current_profile(), entries = [];
	for (let id in sort(fs.lsdir(PROFILES) ?? [])) {
		if (!profile_id(id)) continue;
		const path = `${PROFILES}/${id}`, info = fs.lstat(path);
		if (!private_file(path)) continue;
		const referenced = profile_referenced(id, policy, selected);
		push(entries, { id: id, ref: `file:${id}`, format: match(id, /\.json$/) ? "json" : "yaml",
			size_bytes: info.size, modified_at: info.mtime, referenced: referenced, editable: !referenced });
	}
	return entries;
};
function revision() {
	const parts = [sha256(CONFIG), sha256(POLICY_PATH), fs.lstat(`${BASE}/mixin.json`) == null ? null : sha256(`${BASE}/mixin.json`)];
	for (let profile in profile_entries()) push(parts, [profile.id, sha256(`${PROFILES}/${profile.id}`)]);
	return sha256_text(sprintf("%J", parts));
};
function input(path, maximum) {
	if (!native_ready()) return failure("native_management_unavailable");
	if (!private_file(path) || fs.stat(path).size > maximum) return failure("private_input_file_required");
	let request = read_json(path)?.request;
	if (type(request) == "object" && request.upload_id != null) {
		if (length(keys(request)) != 1 || !match(request.upload_id ?? "", /^[a-f0-9]{32}$/))
			return failure("invalid_upload_id");
		const upload = `/tmp/opl-netfleet-upload.${request.upload_id}.json`;
		if (!private_file(upload)) return failure("private_upload_required");
		let text = null;
		if (fs.stat(upload).size <= maximum) text = fs.readfile(upload);
		if (!fs.unlink(upload)) return failure("upload_cleanup_failed");
		if (text == null) return failure("upload_too_large");
		try { request = json(text)?.request; } catch (error) { return failure("invalid_maintenance_request"); }
		if (request?.upload_id != null) return failure("invalid_upload_id");
	}
	if (type(request) != "object") return failure("invalid_maintenance_request");
	if (request.revision != revision()) return failure("maintenance_revision_changed");
	return { ok: true, request: request };
};

export function get() {
	if (!native_ready()) return { ok: true, result: { supported: false, reason: "native_management_unavailable", revision: null, profiles: [], core: { running: false, actions: [] } } };
	const state = gateway(), version = state?.core_running ? controller_version(api_secret(), 2) : null;
	return { ok: true, result: { supported: true, revision: revision(), profiles: profile_entries(),
		core: { running: state?.core_running == true, controller_available: version != null, running_version: version,
			actions: `${cursor().get("netfleet", "config", "enabled") ?? "0"}` == "1" ? ["restart", "reload"] : [] },
		backup: { format: BACKUP_FORMAT, contains_credentials: true, maximum_bytes: MAX_BACKUP_BYTES } } };
};

export function profile_get(id) {
	if (!native_ready()) return failure("native_management_unavailable");
	if (!profile_id(id) || !private_file(`${PROFILES}/${id}`)) return failure("profile_not_found");
	const profile = filter(profile_entries(), item => item.id == id)[0];
	if (profile.size_bytes > MAX_PROFILE_BYTES) return failure("profile_too_large");
	return { ok: true, result: { revision: revision(), profile: { ...profile, content: fs.readfile(`${PROFILES}/${id}`) } } };
};

function validation_paths(value, work) {
	if (type(value) == "string" && index(value, `${ROOT}/`) == 0) {
		const relative = substr(value, length(ROOT) + 1);
		if (file_path(relative)) return `${work}/inputs/${relative}`;
	}
	if (type(value) == "array") return map(value, item => validation_paths(item, work));
	if (type(value) != "object") return value;
	const result = {};
	for (let key, item in value) result[key] = validation_paths(item, work);
	return result;
};
function test_candidate(path, work) {
	const value = validation_paths(read_yaml(path, true), work);
	if (type(value) != "object") return false;
	const validation = `${work}/validation.json`;
	return write_private(validation, sprintf("%J", value)) &&
		shell(`SAFE_PATHS=${q(`${work}/inputs`)} timeout -s KILL 45 mihomo -t -d ${q(`${work}/inputs/native/run`)} -f ${q(validation)}`);
};
function stage_input(work, relative, content) {
	const path = `${work}/inputs/${relative}`;
	return shell(`mkdir -p ${q(parent(path))}`) && write_private(path, content);
};

function collect_files() {
	const paths = [];
	function visit(relative) {
		const path = `${ROOT}/${relative}`, info = fs.lstat(path);
		if (info == null) return;
		if (info.type == "directory") {
			for (let name in sort(fs.lsdir(path) ?? [])) visit(`${relative}/${name}`);
		} else if (file_path(relative)) {
			// Credentials stay private; packaged baselines and public rule data may be 0644.
			if (!readable_input(path)) die("unsafe_backup_input");
			push(paths, relative);
		}
	};
	for (let name in ["policy-sources", "native/profiles", "native/subscriptions", "native/mixin.json", "native/providers", "native/rulesets", "native/geodata", "native/certs",
		"native/run/providers", "native/run/rulesets", "native/run/geodata", "native/run/certs"]) visit(name);
	for (let name in ["geoip.dat", "geosite.dat", "country.mmdb", "GeoIP.dat", "GeoSite.dat", "Country.mmdb", "ASN.mmdb"]) visit(`native/run/${name}`);
	return paths;
};

export function profile_save(path) {
	const checked = input(path, MAX_PROFILE_BYTES + 32768);
	if (!checked.ok) return checked;
	const request = checked.request, id = request.id;
	if (!profile_id(id)) return failure("invalid_profile_id");
	if (type(request.content) != "string" || !length(trim(request.content)) || length(request.content) > MAX_PROFILE_BYTES || index(request.content, "\u0000") >= 0)
		return failure("invalid_profile_content");
	if (profile_referenced(id, read_json(POLICY_PATH), current_profile())) return failure("profile_is_referenced");
	const target = `${PROFILES}/${id}`;
	if (!safe_target(target)) return failure("unsafe_profile_storage");
	const work = fs.mkdtemp(`${PROFILES}/.validate.XXXXXX`);
	if (work == null) return failure("profile_stage_failed");
	const temporary = `${work}/${id}`;
	let valid = false;
	try {
		valid = shell(`mkdir -p ${q(`${work}/inputs/native/run`)}`);
		for (let relative in collect_files()) {
			if (!valid) break;
			valid = stage_input(work, relative, fs.readfile(`${ROOT}/${relative}`));
		}
		valid = valid && write_private(temporary, request.content) && test_candidate(temporary, work);
	} catch (error) {}
	if (valid) valid = fs.rename(temporary, target);
	shell(`rm -rf ${q(work)}`);
	return valid ? get() : failure("profile_validation_failed");
};

export function profile_delete(path) {
	const checked = input(path, 32768);
	if (!checked.ok) return checked;
	const id = checked.request.id;
	if (!profile_id(id) || !private_file(`${PROFILES}/${id}`)) return failure("profile_not_found");
	if (profile_referenced(id, read_json(POLICY_PATH), current_profile())) return failure("profile_is_referenced");
	return fs.unlink(`${PROFILES}/${id}`) ? get() : failure("profile_delete_failed");
};

function sections() {
	const result = [], uci = cursor();
	uci.foreach("netfleet", null, (section) => {
		const options = {};
		for (let key, value in section) if (substr(key, 0, 1) != ".") options[key] = value;
		push(result, { name: section[".name"], type: section[".type"], options: options });
	});
	return result;
};

export function backup_export() {
	if (!native_ready()) return failure("native_management_unavailable");
	try {
		const backup = { format: BACKUP_FORMAT, created_at: int(time()), policy: read_json(POLICY_PATH), sections: sections(), files: [] };
		let bytes = 0;
		for (let relative in collect_files()) {
			const path = `${ROOT}/${relative}`;
			if (fs.stat(path).size > MAX_PROFILE_BYTES) return failure("backup_too_large");
			const content = b64enc(fs.readfile(path));
			bytes += length(content);
			if (bytes > MAX_BACKUP_BYTES) return failure("backup_too_large");
			push(backup.files, { path: relative, encoding: "base64", content: content });
		}
		const checked = validate_backup(backup);
		if (!checked.ok) return checked;
		if (length(sprintf("%J", backup)) > MAX_BACKUP_BYTES) return failure("backup_too_large");
		return { ok: true, result: { filename: "netfleet-backup.json", backup: backup } };
	} catch (error) { return failure("backup_export_failed"); }
};

function snapshot(work, paths, allow_unhealthy) {
	const state = gateway();
	if (state == null || state.core_running != true && state.clean != true) return null;
	const before = { files: [], profile: current_profile(), core: state.core_running == true,
		enabled: cursor().get("netfleet", "config", "enabled"), supervisor: service_state(), selections: {} };
	if (before.core) {
		const current = proxies(api_secret(), 2)?.proxies;
		if (current == null && !allow_unhealthy) return null;
		for (let name, value in current ?? {}) if (value.type == "Selector" && value.now != null) before.selections[name] = value.now;
	}
	for (let path in paths) {
		if (length(filter(before.files, entry => entry.path == path))) continue;
		const info = fs.lstat(path), backup = `${work}/before-${length(before.files)}`;
		// Generated rollback files can be 0644; they are never added to exports.
		const generated = index([EVIDENCE_PATH, ARTIFACT_PATH, MANIFEST_PATH], path) >= 0 &&
			info?.type == "file" && info.uid == 0 && (info.mode & 022) == 0;
		if (info != null && !readable_input(path) && !generated) return null;
		if (info != null && (!shell(`cp -p ${q(path)} ${q(backup)}`) || sha256(backup) != sha256(path))) return null;
		push(before.files, { path: path, present: info != null, backup: backup, digest: info == null ? null : sha256(path) });
	}
	return atomic_json(`${work}/before.json`, before) ? before : null;
};
function wait_runtime() {
	for (let i = 0; i < 20; i++) {
		if (gateway()?.ready == true) return true;
		if (i < 19) system("sleep 1");
	}
	return false;
};
function restore_choices(before, exact) {
	const secret = api_secret(), current = proxies(secret, 2)?.proxies;
	if (current == null) return false;
	for (let name, choice in before.selections) {
		if (current[name] == null && !exact) continue;
		if (index(current[name]?.all ?? [], choice) < 0) { if (exact) return false; continue; }
		if (!select(secret, name, choice)) return false;
	}
	const after = proxies(secret, 2)?.proxies;
	if (after == null) return false;
	for (let name, choice in before.selections)
		if ((exact || index(current[name]?.all ?? [], choice) >= 0) && after[name]?.now != choice) return false;
	return true;
};
function owner(action, work) {
	const path = `${work}/owner-${action}.json`;
	const success = system(`ucode ${q(MAIN)} ${q(action)} luci >${q(path)} 2>/dev/null`) == 0;
	return success && read_json(path)?.ok == true;
};
function resume(before, work, exact) {
	if (before.core && (!shell(`/etc/init.d/${SERVICE} start`) || !wait_runtime() || !restore_choices(before, exact) || !owner("probe", work))) return false;
	if (!before.core && (gateway()?.core_running != false || gateway()?.clean != true)) return false;
	return current_profile() == before.profile && set_service_state(before.supervisor).ok;
};
function restore_snapshot(before, work) {
	if (!set_service_state({ ...before.supervisor, running: false }).ok || !stop().ok) return false;
	if (length(before.files)) {
		const changed = load_providers(read_json(POLICY_PATH));
		if (changed.ok && !remove_provider_links(changed.profiles)) return false;
	}
	for (let saved in before.files) {
		if (!saved.present) { if (fs.lstat(saved.path) != null && !fs.unlink(saved.path)) return false; continue; }
		const temporary = `${saved.path}.maintenance-restore`;
		if (fs.lstat(parent(saved.path))?.type != "directory" || fs.lstat(temporary) != null && !private_file(temporary) ||
			!shell(`cp -p ${q(saved.backup)} ${q(temporary)}`) ||
			sha256(temporary) != saved.digest || !fs.rename(temporary, saved.path)) return false;
	}
	if (length(before.files) && before.profile == COMPILED_PROFILE) {
		const restored = load_providers(read_json(POLICY_PATH));
		if (!restored.ok || !prepare_provider_links(restored.profiles)) return false;
	}
	return resume(before, work, true);
};
function clean_work(work) { return shell(`rm -rf ${q(work)}`); };
function stage_config(backup, before, work) {
	if (!write_private(`${work}/netfleet`, "\n")) return false;
	const uci = cursor(work);
	for (let section in backup.sections) {
		if (!uci.set("netfleet", section.name, section.type)) return false;
		for (let key, value in section.options) if (!uci.set("netfleet", section.name, key, value)) return false;
	}
	// A backup carries declarations, never authority to start a different runtime.
	uci.set("netfleet", "config", "profile", before.profile);
	uci.set("netfleet", "config", "enabled", before.enabled ?? "0");
	return uci.commit("netfleet") && fs.chmod(`${work}/netfleet`, 0600);
};

export function backup_restore(path) {
	const checked = input(path, MAX_BACKUP_BYTES + 32768);
	if (!checked.ok) return checked;
	const request = checked.request, backup = request.backup;
	if (request.confirm != true) return failure("explicit_confirmation_required");
	const validation = validate_backup(backup);
	if (!validation.ok) return validation;
	if (!validate_policy(backup.policy).ok) return failure("backup_policy_invalid");
	const work = fs.mkdtemp(`${ROOT}/.maintenance.XXXXXX`);
	if (work == null) return failure("maintenance_snapshot_failed");
	let before = null, changed = false, reason = null;
	try {
		const current_paths = map(collect_files(), relative => `${ROOT}/${relative}`);
		const next_paths = map(backup.files, file => `${ROOT}/${file.path}`);
		before = snapshot(work, [CONFIG, POLICY_PATH, EVIDENCE_PATH, ARTIFACT_PATH, MANIFEST_PATH, ...current_paths, ...next_paths]);
		if (before == null) die("maintenance_snapshot_failed");
		if (before.profile != COMPILED_PROFILE && index(next_paths, resolve_profile(before.profile)) < 0)
			die("selected_profile_missing_from_backup");
		if (!stage_config(backup, before, work)) die("backup_stage_failed");
		if (!shell(`mkdir -p ${q(`${work}/inputs/native/run`)}`)) die("backup_stage_failed");
		for (let file in backup.files) {
			const target = `${ROOT}/${file.path}`;
			if (!safe_target(target)) die("unsafe_backup_destination");
			if (!stage_input(work, file.path, b64dec(file.content))) die("backup_stage_failed");
		}
		for (let file in backup.files) {
			const staged = `${work}/inputs/${file.path}`;
			if (match(file.path, /^(policy-sources\/|native\/(profiles|subscriptions)\/)/) && !test_candidate(staged, work))
				die("backup_profile_invalid");
			if (file.path == "native/mixin.json" && type(read_json(staged)) != "object") die("backup_mixin_invalid");
		}
		if (request.revision != revision()) die("maintenance_revision_changed");
		changed = true;
		if (!set_service_state({ ...before.supervisor, running: false }).ok || !stop().ok) die("maintenance_stop_failed");
		for (let file in backup.files)
			if (!fs.rename(`${work}/inputs/${file.path}`, `${ROOT}/${file.path}`)) die("backup_install_failed");
		for (let old in current_paths) if (index(next_paths, old) < 0 && !fs.unlink(old)) die("backup_install_failed");
		if (!fs.rename(`${work}/netfleet`, CONFIG) || !atomic_json(POLICY_PATH, backup.policy)) die("backup_install_failed");
		if (before.profile == COMPILED_PROFILE) {
			const uci = cursor();
			uci.set("netfleet", "config", "profile", backup.policy.recovery_profile.ref);
			if (!uci.commit("netfleet") || !owner("compile", work)) die("backup_compile_failed");
			uci.set("netfleet", "config", "profile", before.profile);
			if (!uci.commit("netfleet") || !fs.chmod(CONFIG, 0600)) die("backup_profile_restore_failed");
		}
		if (!resume(before, work, false)) die("backup_runtime_verification_failed");
	} catch (error) {
		const code = trim(split(`${error}`, "\n")[0]);
		reason = match(code, /^[a-z][a-z0-9_]+$/) ? code : "backup_restore_failed";
	}
	if (reason == null) { clean_work(work); return { ok: true, result: { state: "restored", revision: revision(), runtime_preserved: true } }; }
	const restored = !changed || restore_snapshot(before, work);
	if (restored) clean_work(work);
	return failure(reason, { rollback: { ok: restored }, recovery: restored ? "restored" : "failed" });
};

export function core_action(path) {
	const checked = input(path, 32768);
	if (!checked.ok) return checked;
	const request = checked.request;
	if (request.confirm != true) return failure("explicit_confirmation_required");
	if (index(["restart", "reload"], request.action) < 0) return failure("invalid_core_action");
	if (`${cursor().get("netfleet", "config", "enabled") ?? "0"}` != "1") return failure("core_disabled");
	const work = fs.mkdtemp(`${ROOT}/.maintenance.XXXXXX`);
	if (work == null) return failure("maintenance_snapshot_failed");
	const before = snapshot(work, [], true);
	if (before == null) { clean_work(work); return failure("maintenance_snapshot_failed"); }
	let success = set_service_state({ ...before.supervisor, running: false }).ok &&
		shell(`/etc/init.d/${SERVICE} ${request.action}`) && wait_runtime() && restore_choices(before, true) && owner("probe", work);
	if (success) success = set_service_state(before.supervisor).ok;
	if (success) { clean_work(work); return { ok: true, result: { state: request.action == "restart" ? "restarted" : "reloaded", revision: revision(), runtime: gateway() } }; }
	const restored = restore_snapshot(before, work);
	if (!restored) stop();
	if (restored) clean_work(work);
	return failure("core_maintenance_failed", { rollback: { ok: restored }, recovery: restored ? "restored" : "failed" });
};

export function diagnostics() {
	if (!native_ready()) return { ok: true, result: { supported: false, core_running: false, controller_available: false, captured_at: int(time()), lines: [], truncated: false } };
	const secrets = [api_secret()];
	cursor().foreach("netfleet", null, (section) => {
		for (let key, value in section) if (match(key, /secret|password|token|url|authentication/i)) {
			if (type(value) == "array") for (let item in value) push(secrets, item);
			else if (type(value) == "string") push(secrets, value);
		}
	});
	const output = capture("logread -e 'opl-netfleet-core' | tail -n 120") ?? "";
	const file = fs.lstat(LOG_PATH)?.type == "file" ? capture(`tail -c 65536 ${q(LOG_PATH)} | tail -n 120`) ?? "" : "";
	const source = filter(split(output + "\n" + file, "\n"), line => length(trim(line)) > 0);
	const state = gateway();
	return { ok: true, result: { supported: true, core_running: state?.core_running == true,
		controller_available: state?.core_running == true && controller_version(api_secret(), 2) != null,
		captured_at: int(time()), lines: map(slice(source, -120), line => redact_line(line, secrets)), truncated: length(source) > 120 } };
};
