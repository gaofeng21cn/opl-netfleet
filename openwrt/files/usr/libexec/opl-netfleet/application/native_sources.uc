import * as fs from "fs";
import { read_json, read_yaml, sha256, shell_quote } from "../adapters/uci.uc";
import { cache_accepted } from "../core/subscription.uc";
import { validate, valid_id, project } from "../core/native_sources.uc";
import { ok, fail } from "../output.uc";
import { BASE, CACHE, LOCK, private_file, private_directory, write_private, atomic_json, core_service } from "../adapters/native.uc";

const CONFIG = `${BASE}/sources.json`;

function source_identity(source, scratch) {
	// Credentials go through a private file, never a shell argument or log.
	const path = `${scratch}/identity.json`;
	if (!write_private(path, sprintf("%J", { url: source.url, user_agent: source.user_agent ?? "NetFleet" })))
		return null;
	return sha256(path);
};

function load_cache(id) {
	const path = `${CACHE}/${id}.json`;
	return private_file(path) ? read_json(path) : null;
};

function projection(config, scratch) {
	const sources = [];
	for (let source in config.sources) {
		const identity = source_identity(source, scratch);
		if (identity == null) return { ok: false, error: "source_identity_failed" };
		push(sources, project(source, identity, load_cache(source.id)));
	}
	return { ok: true, result: { stage: "prepared_sources", data_plane_changed: false, sources: sources } };
};

function curl_value(value) {
	return `"${replace(replace(value, "\\", "\\\\"), '"', '\\"')}"`;
};

function download(source, scratch) {
	const request = `${scratch}/request.conf`;
	const body = `${scratch}/response`;
	if (!write_private(request, `url = ${curl_value(source.url)}\nuser-agent = ${curl_value(source.user_agent ?? "NetFleet")}\n`))
		return { error: "request_prepare_failed" };
	// -q disables ~/.curlrc; HTTPS and explicit direct transport also apply to redirects.
	const command = `curl -q --config ${shell_quote(request)} --noproxy '*' --proxy '' ` +
		`--cacert /etc/ssl/certs/ca-certificates.crt ` +
		`--proto '=https' --proto-redir '=https' --location --max-redirs 3 --fail --silent ` +
		`--connect-timeout 10 --max-time 60 --max-filesize 8388608 --output ${shell_quote(body)} 2>/dev/null`;
	if (system(command) != 0) return { error: "download_failed" };
	const info = fs.stat(body);
	if (info == null || info.size == 0 || info.size > 8388608) return { error: "invalid_download_size" };
	const parsed = read_yaml(body, true);
	if (!cache_accepted(parsed)) return { error: "invalid_subscription" };
	const nodes = { proxies: parsed.proxies };
	if (!write_private(`${scratch}/nodes.json`, sprintf("%J", nodes)) ||
		!write_private(`${scratch}/validation.json`, sprintf("%J", {
			proxies: nodes.proxies, "proxy-groups": [], rules: ["MATCH,DIRECT"],
			mode: "rule", ipv6: false, "log-level": "silent"
		}))) return { error: "candidate_write_failed" };
	if (system(`SAFE_PATHS='' mihomo -t -d ${shell_quote(scratch)} -f ${shell_quote(`${scratch}/validation.json`)} >/dev/null 2>&1`) != 0)
		return { error: "invalid_mihomo_nodes" };
	const digest = sha256(`${scratch}/nodes.json`);
	return digest == null ? { error: "candidate_digest_failed" } : { nodes: nodes.proxies, digest: digest };
};

function refresh(config, requested, scratch) {
	if (requested != null && (!valid_id(requested) ||
		length(filter(config.sources, source => source.id == requested && source.enabled)) != 1))
		return { ok: false, error: "enabled_source_not_found" };
	if (system("command -v curl >/dev/null 2>&1 && command -v mihomo >/dev/null 2>&1 && yq --version >/dev/null 2>&1") != 0)
		return { ok: false, error: "source_dependencies_unavailable" };
	let failed = 0;
	for (let source in config.sources) {
		if (!source.enabled || (requested != null && source.id != requested)) continue;
		const identity = source_identity(source, scratch);
		if (identity == null) return { ok: false, error: "source_identity_failed" };
		const path = `${CACHE}/${source.id}.json`;
		if (fs.lstat(path) != null && !private_file(path))
			return { ok: false, error: "unsafe_cache_file" };
		const old = load_cache(source.id);
		const candidate = download(source, scratch);
		const now = int(time());
		const cache = old ?? { schema_version: 1 };
		cache.attempt = { source_sha256: identity, at: now, result: "failed", error: candidate.error ?? null };
		if (candidate.error == null) {
			const changed = cache.source_sha256 != identity || cache.content_sha256 != candidate.digest;
			cache.proxies = candidate.nodes;
			cache.source_sha256 = identity;
			cache.content_sha256 = candidate.digest;
			cache.last_success = now;
			if (changed) cache.last_changed = now;
			cache.attempt.result = changed ? "updated" : "unchanged";
		} else failed++;
		if (!atomic_json(path, cache)) return { ok: false, error: "cache_commit_failed" };
	}
	const result = projection(config, scratch);
	if (!result.ok) return result;
	result.result.failed_count = failed;
	return failed == 0 ? result : { ok: false, error: "source_refresh_failed", detail: result.result };
};

function execute(action, argument, scratch) {
	if (fs.lstat(BASE) != null && !private_directory(BASE)) return { ok: false, error: "unsafe_native_directory" };
	if (fs.lstat(CONFIG) != null && !private_file(CONFIG)) return { ok: false, error: "unsafe_source_config" };
	if (fs.lstat(CACHE) != null && !private_directory(CACHE)) return { ok: false, error: "unsafe_cache_directory" };
	const config = fs.lstat(CONFIG) == null ? { schema_version: 1, sources: [] } : read_json(CONFIG);
	if (!validate(config).ok) return { ok: false, error: "source_config_unreadable" };
	if (action == "native-sources-get") return projection(config, scratch);
	const runtime = core_service();
	if (!runtime.ok) return { ok: false, error: "procd_unavailable" };
	if (runtime.service != null) return { ok: false, error: "native_core_registered" };
	if (action == "native-sources-set") {
		if (!private_file(argument) || fs.stat(argument).size > 1048576)
			return { ok: false, error: "private_input_file_required" };
		const desired = read_json(argument);
		const checked = validate(desired);
		if (!checked.ok) return checked;
		if (fs.lstat("/etc/opl-netfleet") == null && !fs.mkdir("/etc/opl-netfleet", 0755))
			return { ok: false, error: "native_directory_create_failed" };
		if (fs.lstat(BASE) == null && !fs.mkdir(BASE, 0700)) return { ok: false, error: "native_directory_create_failed" };
		if (fs.lstat(CACHE) == null && !fs.mkdir(CACHE, 0700)) return { ok: false, error: "cache_directory_create_failed" };
		if (!private_directory(CACHE)) return { ok: false, error: "unsafe_cache_directory" };
		if (!atomic_json(CONFIG, desired)) return { ok: false, error: "source_config_commit_failed" };
		for (let previous in config.sources) {
			if (length(filter(desired.sources, source => source.id == previous.id)) == 0) {
				const path = `${CACHE}/${previous.id}.json`;
				if (fs.lstat(path) != null && !fs.unlink(path)) return { ok: false, error: "removed_source_cache_cleanup_failed" };
			}
		}
		return projection(desired, scratch);
	}
	if (!private_directory(CACHE)) return { ok: false, error: "native_sources_not_configured" };
	return refresh(config, argument, scratch);
};

export function get_state() {
	const scratch = fs.mkdtemp("/tmp/opl-netfleet-native.XXXXXX");
	if (scratch == null) return { ok: false, error: "scratch_directory_failed" };
	let result;
	try { result = execute("native-sources-get", null, scratch); }
	catch (error) { result = { ok: false, error: "native_source_operation_failed" }; }
	for (let name in fs.lsdir(scratch) ?? []) fs.unlink(`${scratch}/${name}`);
	fs.rmdir(scratch);
	return result;
};

export function run(action, argument) {
	if (system("test \"$(id -u)\" = 0") != 0) fail(action, "root_required");
	let lock = null;
	if (action != "native-sources-get") {
		lock = fs.open(LOCK, "a", 0600);
		if (lock == null || lock.lock("xn") != true) {
			if (lock != null) lock.close();
			fail(action, "mutation_busy");
		}
	}
	const scratch = fs.mkdtemp("/tmp/opl-netfleet-native.XXXXXX");
	let result = { ok: false, error: "scratch_directory_failed" };
	if (scratch != null) {
		try { result = execute(action, argument, scratch); }
		catch (error) { result = { ok: false, error: "native_source_operation_failed" }; }
		for (let name in fs.lsdir(scratch) ?? []) fs.unlink(`${scratch}/${name}`);
		fs.rmdir(scratch);
	}
	if (lock != null) lock.close();
	if (!result.ok) fail(action, result.error, result.detail ?? { source_index: result.source_index ?? null });
	ok(action, result.result);
};
