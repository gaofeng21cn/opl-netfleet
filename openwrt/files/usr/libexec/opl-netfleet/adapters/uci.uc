import { popen, writefile } from "fs";
import { cursor } from "uci";

export const POLICY_PATH = "/etc/opl-netfleet/policy.json";
export const EVIDENCE_PATH = "/etc/opl-netfleet/evidence.json";

export function shell_quote(value) {
	return `'${replace(`${value}`, "'", "'\\''")}'`;
};

export function read_yaml(path) {
	if (system("command -v yq >/dev/null 2>&1") != 0 ||
		system("yq --version >/dev/null 2>&1") != 0) {
		return null;
	}
	const process = popen(`yq -M -p yaml -o json ${shell_quote(path)}`);
	if (!process) {
		return null;
	}
	let result = null;
	try {
		result = json(process);
	} catch (error) {
		result = null;
	}
	process.close();
	return result;
};

export function read_json(path) {
	if (system(`test -f ${shell_quote(path)}`) != 0) {
		return null;
	}
	const process = popen(`cat ${shell_quote(path)}`);
	if (!process) {
		return null;
	}
	let result = null;
	try {
		result = json(process);
	} catch (error) {
		result = null;
	}
	process.close();
	return result;
};

export function sha256(path) {
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

export function sha256_text(value) {
	const process = popen(`printf '%s' ${shell_quote(value)} | sha256sum`);
	if (!process) return null;
	const line = process.read("line");
	process.close();
	return line ? split(trim(line), " ")[0] : null;
};

export function device_name() {
	try {
		const value = cursor().get("system", "@system[0]", "hostname");
		return type(value) == "string" && length(trim(value)) > 0 ? trim(value) : "OpenWrt";
	} catch (error) {
		return "OpenWrt";
	}
};

export function write_text(path, content) {
	return writefile(path, content) != 0;
};

export function write_json_atomic(path, value) {
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

export function mkdir(path) {
	return system(`mkdir -p ${shell_quote(path)}`) == 0;
};

export function write_evidence(store) {
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

export function current_profile() {
	try {
		const uci = cursor();
		return uci.get("nikki", "config", "profile");
	} catch (error) {
		return null;
	}
};

export function nikki_enabled() {
	try {
		const uci = cursor();
		return `${uci.get("nikki", "config", "enabled") ?? "0"}` == "1";
	} catch (error) {
		return null;
	}
};

export function set_nikki_enabled(enabled) {
	const value = enabled == true ? "1" : "0";
	if (system(`uci set nikki.config.enabled=${shell_quote(value)}`) != 0) {
		return false;
	}
	return system("uci commit nikki") == 0 && nikki_enabled() == (enabled == true);
};

export function subscription_exists(section) {
	const uci = cursor();
	return uci.get("nikki", section) == "subscription";
};

export function subscription_display_name(section) {
	const uci = cursor();
	const value = uci.get("nikki", section, "name");
	if (type(value) == "string" && length(trim(value)) > 0) {
		return trim(value);
	}
	return section;
};

export function subscription_options() {
	const result = [];
	const uci = cursor();
	uci.foreach("nikki", "subscription", (section) => {
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

export function api_secret() {
	const uci = cursor();
	return uci.get("nikki", "mixin", "api_secret");
};

export function proxy_authentication() {
	const uci = cursor();
	const enabled = uci.get("nikki", "mixin", "authentication");
	if (`${enabled ?? ""}` != "1") {
		return null;
	}
	const username = uci.get("nikki", "@authentication[0]", "username");
	const password = uci.get("nikki", "@authentication[0]", "password");
	if (type(username) != "string" || type(password) != "string" ||
		length(username) == 0 || length(password) == 0) {
		return null;
	}
	return { username: username, password: password };
};

export function upstream_ready() {
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

export function set_profile(profile) {
	if (system(`uci set nikki.config.profile=${shell_quote(profile)}`) != 0) {
		return false;
	}
	return system("uci commit nikki") == 0;
};

function quantity(value) {
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

export function subscription_quota(section, config) {
	const uci = cursor();
	const available_field = config?.available_field ?? "avaliable";
	const total_field = config?.total_field ?? "total";
	const used_field = config?.used_field ?? "used";
	const expiry_field = config?.expiry_field ?? "expire";
	const expiry_raw = uci.get("nikki", section, expiry_field);
	const expires_at = type(expiry_raw) == "string" &&
		match(trim(expiry_raw), /^[0-9]{4}-[0-9]{2}-[0-9]{2}([ T][0-9]{2}:[0-9]{2}:[0-9]{2})?$/) ?
		trim(expiry_raw) : null;
	const result = { state: "unknown" };
	if (expires_at != null) result.expires_at = expires_at;
	let available_raw = uci.get("nikki", section, available_field);
	if (available_raw == null && available_field != "available") {
		available_raw = uci.get("nikki", section, "available");
	}
	const available = quantity(available_raw);
	if (available != null) {
		result.state = available <= 0 ? "exhausted" : "available";
		if (available > 0) result.remaining_bytes = available;
		return result;
	}
	const total = quantity(uci.get("nikki", section, total_field));
	const used = quantity(uci.get("nikki", section, used_field));
	if (total != null && used != null) {
		const remaining = total - used;
		result.state = remaining <= 0 ? "exhausted" : "available";
		if (remaining > 0) result.remaining_bytes = remaining;
	}
	return result;
};
