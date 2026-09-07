import * as fs from "fs";

return function(context) {
	function snapshot() {
		const uptime = split(trim(fs.readfile("/proc/uptime") ?? ""), /\s+/);
		const load = split(trim(fs.readfile("/proc/loadavg") ?? ""), /\s+/);
		const kernel = trim(fs.readfile("/proc/sys/kernel/osrelease") ?? "");
		if (!length(kernel) || !length(uptime) || length(load) < 3 ||
			!match(uptime[0], /^[0-9]+(\.[0-9]+)?$/))
			return { ok: false, error: "system_information_unavailable" };
		return { ok: true, result: { kernel, uptime_seconds: +uptime[0],
			load_average: map(slice(load, 0, 3), value => +value) } };
	};
	return { snapshot };
};
