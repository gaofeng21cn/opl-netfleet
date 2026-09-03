import { popen } from "fs";
import { mkdir, read_json, shell_quote, write_text } from "./uci.uc";

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

export function nikki_netfleet_lines(group_names) {
	const process = popen("tail -n 512 /var/log/nikki/core.log 2>/dev/null");
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
