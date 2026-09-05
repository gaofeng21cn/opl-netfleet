import * as fs from "fs";
import { cursor } from "uci";
import { read_json, read_yaml, sha256, shell_quote, POLICY_PATH } from "../adapters/uci.uc";
import { BASE, private_file, private_directory, write_private, atomic_json, core_service } from "../adapters/native.uc";
import { KIND } from "../adapters/runtime.uc";
import { cache_accepted } from "../core/subscription.uc";
import { valid_id, desired_source, userinfo, referenced, public_source } from "../core/subscriptions.uc";

const CONFIG = "/etc/config/netfleet";
const DIRECTORY = `${BASE}/subscriptions`;
const QUOTA_FIELDS = ["upload", "download", "total", "used", "avaliable", "expire"];
const METADATA = ["upload", "download", "total", "used", "avaliable", "expire", "update",
	"success", "last_attempt", "last_success", "last_result", "last_error"];

function native_selected() {
	return KIND == "native-mihomo";
};

function revision() { return fs.lstat(CONFIG) == null ? "absent" : sha256(CONFIG); };

function directory_ready() {
	if (fs.lstat(BASE) == null && !fs.mkdir(BASE, 0700)) return false;
	if (!private_directory(BASE)) return false;
	if (fs.lstat(DIRECTORY) == null && !fs.mkdir(DIRECTORY, 0700)) return false;
	return private_directory(DIRECTORY);
};

function cache_path(id) { return `${DIRECTORY}/${id}.yaml`; };

function config_ready() {
	if (fs.lstat(CONFIG) == null && !write_private(CONFIG, "")) return false;
	return private_file(CONFIG);
};

function commit(uci) {
	return uci.commit("netfleet") == true && fs.chmod(CONFIG, 0600) == true;
};

export function get() {
	if (!native_selected()) return { ok: true, result: { managed_by: "nikki", manage_externally: true, sources: [], revision: null } };
	if (fs.lstat(CONFIG) != null && !private_file(CONFIG)) return { ok: false, error: "unsafe_subscription_config" };
	const uci = cursor();
	const sources = [];
	uci.foreach("netfleet", "subscription", (source) => {
		const id = source[".name"];
		if (!valid_id(id)) return;
		const path = cache_path(id);
		const cached = private_file(path) ? read_yaml(path, true) : null;
		const present = cache_accepted(cached);
		push(sources, public_source(source, { present: present,
			digest: present ? sha256(path) : null, node_count: present ? length(cached.proxies) : null }));
	});
	return { ok: true, result: { managed_by: "netfleet", manage_externally: false, sources: sources, revision: revision() } };
};

// Mutating entrypoints run inside main.uc's existing global transaction lock.
export function set(path) {
	if (!native_selected()) return { ok: false, error: "subscriptions_managed_by_nikki" };
	if (!private_file(path) || fs.stat(path).size > 32768) return { ok: false, error: "private_input_file_required" };
	const input = read_json(path)?.request;
	if (type(input) != "object" || input.revision != revision()) return { ok: false, error: "subscription_revision_changed" };
	const service = core_service();
	if (!service.ok) return { ok: false, error: "procd_unavailable" };
	if (service.service != null) return { ok: false, error: "disable_before_subscription_edit" };
	if (!config_ready() || !directory_ready()) return { ok: false, error: "unsafe_subscription_storage" };
	const uci = cursor();
	const id = input.source?.id;
	if (!valid_id(id)) return { ok: false, error: "invalid_subscription_id" };
	const existing = uci.get_all("netfleet", id);
	if (existing != null && existing[".type"] != "subscription") return { ok: false, error: "section_id_in_use" };
	const desired = desired_source(input, existing);
	if (!desired.ok) return desired;
	const cached = cache_path(id);
	if (fs.lstat(cached) != null && !private_file(cached)) return { ok: false, error: "unsafe_subscription_cache" };
	if (desired.deleted && referenced(read_json(POLICY_PATH), id)) return { ok: false, error: "subscription_referenced_by_policy" };
	if (desired.deleted && existing == null) return { ok: false, error: "subscription_not_found" };
	const old_config = fs.readfile(CONFIG);
	if (desired.deleted) uci.delete("netfleet", id);
	else {
		if (existing == null) uci.set("netfleet", id, "subscription");
		for (let key in ["name", "url", "user_agent", "info_url", "prefer"])
			uci.set("netfleet", id, key, desired.source[key]);
		if (desired.source_changed) for (let key in METADATA) uci.delete("netfleet", id, key);
		else if ((existing?.info_url ?? "") != desired.source.info_url)
			for (let key in QUOTA_FIELDS) uci.delete("netfleet", id, key);
	}
	if (!commit(uci)) return { ok: false, error: "subscription_config_commit_failed" };
	if ((desired.deleted || desired.source_changed || existing == null) && fs.lstat(cached) != null && !fs.unlink(cached)) {
		write_private(CONFIG, old_config);
		return { ok: false, error: "subscription_cache_invalidation_failed" };
	}
	return get();
};

function curl_value(value) {
	return `"${replace(replace(value, "\\", "\\\\"), '"', '\\"')}"`;
};

function fetch(url, agent, scratch, name) {
	const request = `${scratch}/${name}.conf`;
	const body = `${scratch}/${name}.body`;
	const headers = `${scratch}/${name}.headers`;
	if (!write_private(request, `url = ${curl_value(url)}\nuser-agent = ${curl_value(agent)}\n`) ||
		!write_private(body, "") || !write_private(headers, "")) return { ok: false, error: "subscription_request_prepare_failed" };
	const command = `curl -q --config ${shell_quote(request)} --noproxy '*' --proxy '' ` +
		`--cacert /etc/ssl/certs/ca-certificates.crt --proto '=https,http' --proto-redir '=https,http' ` +
		`--location --max-redirs 3 --fail --silent --connect-timeout 10 --max-time 60 ` +
		`--max-filesize 8388608 --dump-header ${shell_quote(headers)} --output ${shell_quote(body)} 2>/dev/null`;
	if (system(command) != 0) return { ok: false, error: "subscription_download_failed" };
	return { ok: true, body: body, quota: userinfo(fs.readfile(headers)) };
};

function download(source, scratch) {
	const fetched = fetch(source.url, source.user_agent || "clash.meta", scratch, "subscription");
	if (!fetched.ok) return fetched;
	const info = fs.stat(fetched.body);
	if (info == null || info.size == 0 || info.size > 8388608) return { ok: false, error: "invalid_subscription_size" };
	const parsed = read_yaml(fetched.body, true);
	if (!cache_accepted(parsed)) return { ok: false, error: "invalid_subscription" };
	const validation = `${scratch}/validation.json`;
	if (!write_private(validation, sprintf("%J", parsed))) return { ok: false, error: "subscription_validation_write_failed" };
	if (system(`SAFE_PATHS='' mihomo -t -d ${shell_quote(scratch)} -f ${shell_quote(validation)} >/dev/null 2>&1`) != 0)
		return { ok: false, error: "subscription_mihomo_validation_failed" };
	let quota = fetched.quota;
	if (source.info_url) {
		const information = fetch(source.info_url, source.user_agent || "clash.meta", scratch, "information");
		if (information.ok && information.quota != null) quota = information.quota;
	}
	return { ok: true, parsed: parsed, digest: sha256(validation), quota: quota };
};

function do_update(id, scratch) {
	const uci = cursor();
	const source = uci.get_all("netfleet", id);
	if (source?.[".type"] != "subscription") return { ok: false, error: "subscription_not_found" };
	const checked = desired_source({ revision: "internal", source: { id: id } }, source);
	if (!checked.ok) return checked;
	const path = cache_path(id);
	if (fs.lstat(path) != null && !private_file(path)) return { ok: false, error: "unsafe_subscription_cache" };
	uci.set("netfleet", id, "last_attempt", `${int(time())}`);
	uci.set("netfleet", id, "last_result", "running");
	uci.delete("netfleet", id, "last_error");
	if (!commit(uci)) return { ok: false, error: "subscription_metadata_commit_failed" };
	const result = download(checked.source, scratch);
	const now = int(time());
	const old = fs.readfile(path);
	const changed = result.ok && (old == null || result.digest != sha256(path));
	if (result.ok && changed && !atomic_json(path, result.parsed)) {
		result.ok = false;
		result.error = "subscription_cache_commit_failed";
	}
	uci.set("netfleet", id, "success", result.ok ? "1" : "0");
	uci.set("netfleet", id, "last_result", result.ok ? (changed ? "updated" : "unchanged") : "failed");
	if (result.ok) {
		uci.set("netfleet", id, "last_success", `${now}`);
		uci.set("netfleet", id, "update", strftime("%Y-%m-%d %H:%M:%S", now));
		uci.delete("netfleet", id, "last_error");
		for (let key in QUOTA_FIELDS) {
			const value = result.quota?.[key];
			if (value == null || (key == "expire" && value == 0)) uci.delete("netfleet", id, key);
			else uci.set("netfleet", id, key, key == "expire" ? strftime("%Y-%m-%d %H:%M:%S", value) : `${value} B`);
		}
	} else uci.set("netfleet", id, "last_error", result.error);
	if (!commit(uci)) {
		if (changed) {
			if (old == null) fs.unlink(path);
			else write_private(path, old);
		}
		return { ok: false, error: "subscription_metadata_commit_failed" };
	}
	return result.ok ? { ok: true, changed: changed } : { ok: false, error: result.error };
};

export function update_result(id) {
	if (!native_selected()) return { ok: false, error: "subscriptions_managed_by_nikki" };
	if (!valid_id(id)) return { ok: false, error: "invalid_subscription_id" };
	if (!config_ready() || !directory_ready()) return { ok: false, error: "unsafe_subscription_storage" };
	const scratch = fs.mkdtemp("/tmp/opl-netfleet-subscription.XXXXXX");
	if (scratch == null) return { ok: false, error: "subscription_scratch_failed" };
	let result;
	try { result = do_update(id, scratch); }
	catch (error) { result = { ok: false, error: "subscription_update_failed" }; }
	// Mihomo validation may create private cache files in its temporary directory.
	system(`rm -rf ${shell_quote(scratch)}`);
	return result;
};

export function update(id) { return update_result(id).ok; };
