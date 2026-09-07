import { popen, writefile, readfile, stat } from "fs";
import { cursor } from "uci";

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let shell_quote, read_yaml, read_json, sha256, file_mtime, sha256_text, device_name, write_text, write_json_atomic, mkdir, write_evidence, current_profile, backend_enabled, set_backend_enabled, subscription_exists, subscription_display_name, subscription_options, api_secret, proxy_authentication, upstream_ready, set_profile, quantity, subscription_quota;

const quota_reset_day = context.use("models.subscriptions").quota_reset_day;
const UCI_PACKAGE = context.use("platform.runtime").UCI_PACKAGE;

const POLICY_PATH = "/etc/opl-netfleet/policy.json";
const EVIDENCE_PATH = "/etc/opl-netfleet/evidence.json";

shell_quote = function(value) {
	return `'${replace(`${value}`, "'", "'\\''")}'`;
};

read_yaml = function(path, quiet) {
	// Native artifacts retain .yaml paths for Mihomo but contain validated JSON.
	const source = readfile(path);
	if (source == null) return null;
	try { return json(source); } catch (error) {}
	const process = popen(`yq -M -p yaml -o json ${shell_quote(path)}${quiet ? " 2>/dev/null" : ""}`);
	if (!process) {
		return null;
	}
	let result = null;
	try {
		result = json(process);
	} catch (error) {
		result = null;
	}
	if (process.close() != 0) return null;
	return result;
};

read_json = function(path) {
	if (stat(path)?.type != "file") return null;
	try { return json(readfile(path)); } catch (error) { return null; }
};

sha256 = function(path) {
	const process = popen(`sha256sum ${shell_quote(path)}`);
	if (!process) {
		return null;
	}
	const line = process.read("line");
	process.close();
	if (!line) {
		return null;
	}
	return split(trim(line), " ")[0];
};

file_mtime = function(path) {
	if (system(`test -f ${shell_quote(path)}`) != 0) {
		return null;
	}
	const process = popen(`date -r ${shell_quote(path)} +%s 2>/dev/null`);
	if (!process) {
		return null;
	}
	const line = process.read("line");
	process.close();
	const value = line ? int(trim(line)) : 0;
	return value > 0 ? value : null;
};

sha256_text = function(value) {
	const process = popen(`printf '%s' ${shell_quote(value)} | sha256sum`);
	if (!process) return null;
	const line = process.read("line");
	process.close();
	return line ? split(trim(line), " ")[0] : null;
};

device_name = function() {
	try {
		const value = cursor().get("system", "@system[0]", "hostname");
		return type(value) == "string" && length(trim(value)) > 0 ? trim(value) : "OpenWrt";
	} catch (error) {
		return "OpenWrt";
	}
};

write_text = function(path, content) {
	return writefile(path, content) != 0;
};

write_json_atomic = function(path, value) {
	const content = sprintf("%J", value);
	const temporary = `${path}.tmp`;
	if (content == null || !write_text(temporary, content) || read_json(temporary) == null) {
		system(`rm -f ${shell_quote(temporary)}`);
		return false;
	}
	const digest = sha256(temporary);
	if (digest == null || system(`mv -f ${shell_quote(temporary)} ${shell_quote(path)}`) != 0 ||
		sha256(path) != digest) {
		system(`rm -f ${shell_quote(temporary)}`);
		return false;
	}
	return true;
};

mkdir = function(path) {
	return system(`mkdir -p ${shell_quote(path)}`) == 0;
};

write_evidence = function(store) {
	const content = sprintf("%J", store);
	const directory = "/etc/opl-netfleet";
	const temporary = `${EVIDENCE_PATH}.tmp`;
	if (content == null || !mkdir(directory) || !write_text(temporary, content)) {
		return false;
	}
	if (system(`mv -f ${shell_quote(temporary)} ${shell_quote(EVIDENCE_PATH)}`) != 0) {
		return false;
	}
	return true;
};

current_profile = function() {
	try {
		const uci = cursor();
		return uci.get(UCI_PACKAGE, "config", "profile");
	} catch (error) {
		return null;
	}
};

backend_enabled = function() {
	try {
		const uci = cursor();
		return `${uci.get(UCI_PACKAGE, "config", "enabled") ?? "0"}` == "1";
	} catch (error) {
		return null;
	}
};

set_backend_enabled = function(enabled) {
	const value = enabled == true ? "1" : "0";
	if (system(`uci set ${UCI_PACKAGE}.config.enabled=${shell_quote(value)}`) != 0) {
		return false;
	}
	return system(`uci commit ${UCI_PACKAGE}`) == 0 && backend_enabled() == (enabled == true);
};

subscription_exists = function(section) {
	const uci = cursor();
	return uci.get(UCI_PACKAGE, section) == "subscription";
};

subscription_display_name = function(section) {
	const uci = cursor();
	const value = uci.get(UCI_PACKAGE, section, "name");
	if (type(value) == "string" && length(trim(value)) > 0) {
		return trim(value);
	}
	return section;
};

subscription_options = function() {
	const result = [];
	const uci = cursor();
	uci.foreach(UCI_PACKAGE, "subscription", (section) => {
		const name = section?.[".name"];
		if (type(name) != "string" || !match(name, /^[A-Za-z0-9_]+$/)) return;
		const display = type(section?.name) == "string" && length(trim(section.name)) > 0 ? trim(section.name) : name;
		push(result, { ref: `subscription:${name}`, display_name: display });
	});
	for (let i = 1; i < length(result); i++) {
		for (let j = i; j > 0 && result[j].display_name < result[j - 1].display_name; j--) {
			const previous = result[j - 1];
			result[j - 1] = result[j];
			result[j] = previous;
		}
	}
	return result;
};

api_secret = function() {
	const uci = cursor();
	return uci.get(UCI_PACKAGE, "mixin", "api_secret");
};

proxy_authentication = function() {
	const uci = cursor();
	const enabled = uci.get(UCI_PACKAGE, "mixin", "authentication");
	if (`${enabled ?? ""}` != "1") {
		return null;
	}
	const username = uci.get(UCI_PACKAGE, "@authentication[0]", "username");
	const password = uci.get(UCI_PACKAGE, "@authentication[0]", "password");
	if (type(username) != "string" || type(password) != "string" ||
		length(username) == 0 || length(password) == 0) {
		return null;
	}
	return { username: username, password: password };
};

upstream_ready = function() {
	const process = popen("ubus call network.interface.wan status 2>/dev/null");
	if (!process) {
		return false;
	}
	let status = null;
	try {
		status = json(process);
	} catch (error) {
		status = null;
	}
	process.close();
	if (status?.up != true) {
		return false;
	}
	return system("ip -4 route show default 2>/dev/null | grep -q '^default '") == 0;
};

set_profile = function(profile) {
	if (system(`uci set ${UCI_PACKAGE}.config.profile=${shell_quote(profile)}`) != 0) {
		return false;
	}
	return system(`uci commit ${UCI_PACKAGE}`) == 0;
};

quantity = function(value) {
	if (type(value) != "string") {
		return null;
	}
	const text = lc(trim(value));
	const parts = split(text, " ");
	if (length(parts) == 0 || parts[0] == "" || index(text, "unlimited") >= 0) {
		return null;
	}
	const number_parts = split(parts[0], ".");
	const whole = int(number_parts[0] ?? "0");
	let fraction = 0;
	if (length(number_parts) > 1) {
		const raw = number_parts[1];
		fraction = int(substr(`${raw}000`, 0, 3));
	}
	const scaled = whole * 1000 + fraction;
	let multiplier = 1;
	const unit = parts[1] ?? "b";
	if (unit == "kb" || unit == "kib") {
		multiplier = 1024;
	} else if (unit == "mb" || unit == "mib") {
		multiplier = 1024 * 1024;
	} else if (unit == "gb" || unit == "gib") {
		multiplier = 1024 * 1024 * 1024;
	} else if (unit == "tb" || unit == "tib") {
		multiplier = 1024 * 1024 * 1024 * 1024;
	}
	return int((scaled * multiplier) / 1000);
};

subscription_quota = function(section, config) {
	const uci = cursor();
	const available_field = config?.available_field ?? "avaliable";
	const total_field = config?.total_field ?? "total";
	const used_field = config?.used_field ?? "used";
	const expiry_field = config?.expiry_field ?? "expire";
	const expiry_raw = uci.get(UCI_PACKAGE, section, expiry_field);
	const expires_at = type(expiry_raw) == "string" &&
		match(trim(expiry_raw), /^[0-9]{4}-[0-9]{2}-[0-9]{2}([ T][0-9]{2}:[0-9]{2}:[0-9]{2})?$/) ?
		trim(expiry_raw) : null;
	const result = { state: "unknown" };
	const reset_day = quota_reset_day(uci.get(UCI_PACKAGE, section, "quota_reset_day"));
	if (reset_day != null) {
		result.reset_day = reset_day;
		result.reset_day_source = "manual";
	}
	if (expires_at != null) result.expires_at = expires_at;
	let available_raw = uci.get(UCI_PACKAGE, section, available_field);
	if (available_raw == null && available_field != "available") {
		available_raw = uci.get(UCI_PACKAGE, section, "available");
	}
	const available = quantity(available_raw);
	if (available != null) {
		result.state = available <= 0 ? "exhausted" : "available";
		if (available > 0) result.remaining_bytes = available;
		return result;
	}
	const total = quantity(uci.get(UCI_PACKAGE, section, total_field));
	const used = quantity(uci.get(UCI_PACKAGE, section, used_field));
	if (total != null && used != null) {
		const remaining = total - used;
		result.state = remaining <= 0 ? "exhausted" : "available";
		if (remaining > 0) result.remaining_bytes = remaining;
	}
	return result;
};

return { POLICY_PATH, EVIDENCE_PATH, shell_quote, read_yaml, read_json, sha256, file_mtime, sha256_text, device_name, write_text, write_json_atomic, mkdir, write_evidence, current_profile, backend_enabled, set_backend_enabled, subscription_exists, subscription_display_name, subscription_options, api_secret, proxy_authentication, upstream_ready, set_profile, subscription_quota };
};
