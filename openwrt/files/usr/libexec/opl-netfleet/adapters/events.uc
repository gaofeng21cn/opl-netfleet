import { popen } from "fs";
import { mkdir, read_json, shell_quote, write_text } from "./uci.uc";
import { KIND, LOG_PATH, SERVICE } from "./runtime.uc";

export const EVENTS_PATH = "/var/lib/opl-netfleet/events.json";

export function read_events() {
	return read_json(EVENTS_PATH);
};

export function write_events(store) {
	const temporary = `${EVENTS_PATH}.tmp`;
	const content = sprintf("%J", store);
	if (content == null || !mkdir("/var/lib/opl-netfleet") || !write_text(temporary, content)) {
		return false;
	}
	return system(`mv -f ${shell_quote(temporary)} ${shell_quote(EVENTS_PATH)}`) == 0;
};

export function core_netfleet_lines(group_names) {
	// logread retries for 11 seconds when this OpenWrt installation has no logd.
	// Optional diagnostic logs must not block the durable event snapshot.
	if (KIND == "native-mihomo" && system("ubus -t 1 list log >/dev/null 2>&1") != 0) return [];
	const command = KIND == "native-mihomo" ? `logread -l 512 -e ${shell_quote(SERVICE)}` : `tail -n 512 ${shell_quote(LOG_PATH)}`;
	const process = popen(`${command} 2>/dev/null`);
	if (!process) return [];
	let result = [];
	for (;;) {
		const line = process.read("line");
		if (line == null) break;
		let relevant = index(line, "NETFLEET-") >= 0;
		for (let i = 0; !relevant && i < length(group_names ?? []); i++) {
			if (type(group_names[i]) == "string" && index(line, group_names[i]) >= 0) relevant = true;
		}
		if (relevant) push(result, trim(line));
	}
	process.close();
	if (length(result) > 128) result = slice(result, length(result) - 128);
	return result;
};
