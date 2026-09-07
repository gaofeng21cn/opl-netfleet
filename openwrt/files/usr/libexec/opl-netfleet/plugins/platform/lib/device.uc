import { popen } from "fs";
import { cursor } from "uci";

return function(context) {
	function device_name() {
		try {
			const value = cursor().get("system", "@system[0]", "hostname");
			return type(value) == "string" && length(trim(value)) > 0 ? trim(value) : "OpenWrt";
		} catch (error) { return "OpenWrt"; }
	}
	function upstream_ready() {
		const process = popen("ubus call network.interface.wan status 2>/dev/null");
		if (!process) return false;
		let status = null;
		try { status = json(process); } catch (error) {}
		process.close();
		return status?.up == true && system("ip -4 route show default 2>/dev/null | grep -q '^default '") == 0;
	}
	return { device_name, upstream_ready };
};
