

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let service_state, set_service_state;



const SERVICE_NAME = "opl-netfleet";

service_state = function(name) {
	name ??= SERVICE_NAME;
	if (index([SERVICE_NAME, "opl-netfleet-compat"], name) < 0) die("unsupported_service");
	const instance = name == SERVICE_NAME ? "supervisor" : "engine";
	const init = `/etc/init.d/${name}`;
	const installed = system(`test -x '${init}'`) == 0;
	const enabled = installed && system(`'${init}' enabled >/dev/null 2>&1`) == 0;
	const running = installed && system(
		`ubus call service list '{"name":"${name}"}' 2>/dev/null | ` +
		`jsonfilter -e '@["${name}"].instances.${instance}.running' 2>/dev/null | grep -qx true`
	) == 0;
	return { installed: installed, enabled: enabled, running: running };
};

set_service_state = function(desired, name) {
	name ??= SERVICE_NAME;
	const before = service_state(name);
	const init = `/etc/init.d/${name}`;
	if (!before.installed) return { ok: false, error: "service_unavailable", readback: before };
	let ok = true;
	if (desired?.enabled == true && !before.enabled) ok = system(`'${init}' enable >/dev/null 2>&1`) == 0 && ok;
	if (desired?.running == true && !before.running) ok = system(`'${init}' start >/dev/null 2>&1`) == 0 && ok;
	if (desired?.running != true && before.running) ok = system(`'${init}' stop >/dev/null 2>&1`) == 0 && ok;
	if (desired?.enabled != true && before.enabled) ok = system(`'${init}' disable >/dev/null 2>&1`) == 0 && ok;
	let readback = null;
	for (let attempt = 0; attempt < 20; attempt++) {
		readback = service_state(name);
		if (readback.enabled == (desired?.enabled == true) &&
			readback.running == (desired?.running == true)) break;
		if (attempt < 19) system("sleep 1");
	}
	return {
		ok: ok && readback.enabled == (desired?.enabled == true) && readback.running == (desired?.running == true),
		readback: readback
	};
};

return { SERVICE_NAME, service_state, set_service_state };
};
