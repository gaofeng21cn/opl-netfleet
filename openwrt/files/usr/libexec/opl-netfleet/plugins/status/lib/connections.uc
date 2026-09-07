

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let connections_action, command_connections;

const fail = context.use("events.output").fail;
const ok = context.use("events.output").ok;
const current_connections = context.use("mihomo.controller").connections;
const api_secret = context.use("platform.uci").api_secret;

connections_action = function() {
	const secret = api_secret();
	const result = secret ? current_connections(secret, 3) : null;
	if (result == null) fail("connections", "mihomo_connections_unavailable", null);
	ok("connections", result);
};

command_connections = function(argv) {
	connections_action();
};

return { connections_action, command_connections };
};
