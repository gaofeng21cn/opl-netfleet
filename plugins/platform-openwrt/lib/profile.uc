import { cursor } from "uci";

return function(context) {
	const UCI_PACKAGE = context.use("platform.runtime").UCI_PACKAGE;
	const shell_quote = context.use("platform.process").shell_quote;
	function current_profile() {
		try { return cursor().get(UCI_PACKAGE, "config", "profile"); }
		catch (error) { return null; }
	}
	function backend_enabled() {
		try { return `${cursor().get(UCI_PACKAGE, "config", "enabled") ?? "0"}` == "1"; }
		catch (error) { return null; }
	}
	function set_backend_enabled(enabled) {
		const value = enabled == true ? "1" : "0";
		if (system(`uci set ${UCI_PACKAGE}.config.enabled=${shell_quote(value)}`) != 0) return false;
		return system(`uci commit ${UCI_PACKAGE}`) == 0 && backend_enabled() == (enabled == true);
	}
	function set_profile(profile) {
		if (system(`uci set ${UCI_PACKAGE}.config.profile=${shell_quote(profile)}`) != 0) return false;
		return system(`uci commit ${UCI_PACKAGE}`) == 0 && current_profile() == profile;
	}
	return { current_profile, backend_enabled, set_backend_enabled, set_profile };
};
