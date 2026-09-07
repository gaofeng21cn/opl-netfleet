import { cursor } from "uci";

return function(context) {
	const UCI_PACKAGE = context.use("platform.runtime").UCI_PACKAGE;
	function api_secret() { return cursor().get(UCI_PACKAGE, "mixin", "api_secret"); }
	function proxy_authentication() {
		const uci = cursor();
		if (`${uci.get(UCI_PACKAGE, "mixin", "authentication") ?? ""}` != "1") return null;
		const username = uci.get(UCI_PACKAGE, "@authentication[0]", "username");
		const password = uci.get(UCI_PACKAGE, "@authentication[0]", "password");
		if (type(username) != "string" || type(password) != "string" || !length(username) || !length(password)) return null;
		return { username, password };
	}
	return { api_secret, proxy_authentication };
};
