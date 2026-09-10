const rpc = global.__netfleetDesktopOwner.rpc;
return function(context) {
	function service_state(name) {
		return name == 'opl-netfleet-compat' ? { installed: false, enabled: false, running: false } : rpc('scheduler.state');
	}
	function set_service_state(desired, name) {
		if (name == 'opl-netfleet-compat') return { ok: desired?.running != true, readback: service_state(name) };
		const result = rpc('scheduler.set', desired);
		return { ok: result.ok == true, readback: service_state(name) };
	}
	return { SERVICE_NAME: 'opl-netfleet', service_state, set_service_state };
};
