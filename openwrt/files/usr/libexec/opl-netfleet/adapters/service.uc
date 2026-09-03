export const SERVICE_NAME = "opl-netfleet";

export function service_state() {
	const init = `/etc/init.d/${SERVICE_NAME}`;
	const installed = system(`test -x '${init}'`) == 0;
	const enabled = installed && system(`'${init}' enabled >/dev/null 2>&1`) == 0;
	const running = installed && system(
		`ubus call service list '{"name":"${SERVICE_NAME}"}' 2>/dev/null | ` +
		`jsonfilter -e '@["${SERVICE_NAME}"].instances.supervisor.running' 2>/dev/null | grep -qx true`
	) == 0;
	return { installed: installed, enabled: enabled, running: running };
};

export function set_service_state(desired) {
	const init = `/etc/init.d/${SERVICE_NAME}`;
	if (system(`test -x '${init}'`) != 0) return { ok: false, error: "service_unavailable", readback: service_state() };
	let ok = true;
	if (desired?.enabled == true) ok = system(`'${init}' enable >/dev/null 2>&1`) == 0 && ok;
	if (desired?.running == true) ok = system(`'${init}' start >/dev/null 2>&1`) == 0 && ok;
	if (desired?.running != true) ok = system(`'${init}' stop >/dev/null 2>&1`) == 0 && ok;
	if (desired?.enabled != true) ok = system(`'${init}' disable >/dev/null 2>&1`) == 0 && ok;
	let readback = null;
	for (let attempt = 0; attempt < 20; attempt++) {
		readback = service_state();
		if (readback.enabled == (desired?.enabled == true) &&
			readback.running == (desired?.running == true)) break;
		if (attempt < 19) system("sleep 1");
	}
	return {
		ok: ok && readback.enabled == (desired?.enabled == true) && readback.running == (desired?.running == true),
		readback: readback
	};
};
