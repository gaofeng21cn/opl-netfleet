const rpc = global.__netfleetDesktopOwner.rpc;
const shell_quote = global.__netfleetDesktopOwner.shell_quote;
const process_identity = global.__netfleetDesktopOwner.process_identity;
const invoke = global.__netfleetDesktopOwner.invoke;
return function(context) {
	const state = getenv('NETFLEET_STATE_DIR');
	const config = rpc('state.get');
	function service_state(name) {
		return rpc('scheduler.state');
	}
	function set_service_state(desired, name) {
		const result = rpc('scheduler.set', desired);
		return { ok: result.ok == true, readback: service_state(name) };
	}
	function run_owner(action, detail) { return invoke(detail == null ? [action] : [action, detail])?.ok == true; }
	function run_owner_result(argv) {
		const result = invoke(argv);
		return { ok: result?.ok == true, state: result?.result?.state ?? null, error: result?.error ?? null };
	}
	function capture_json() { return null; }
	return {
		KIND: 'native-mihomo', PLATFORM: 'macos', ROOT_DIR: `${state}/backend`, RUN_DIR: `${state}/backend/run`,
		SERVICE: 'opl-netfleet-desktop', STATE_DIR: state, LOG_PATH: `${state}/core.log`,
		SUBSCRIPTION_CONFIG_PATH: null, API: `http://127.0.0.1:${config.ports.controller}`,
		metadata: () => ({ id: 'native-mihomo', platform: 'macos', display_name: 'NetFleet + Mihomo',
			features: { config_apply: true, rule_refresh: false } }),
		environment: () => ({ backend: 'native-mihomo', platform: 'macos' }),
		api_secret: () => rpc('state.get').controllerSecret, proxy_authentication: () => null,
		device_name: () => rpc('network.status').device_name ?? 'Mac',
		upstream_ready: () => rpc('network.status').upstream_ready == true,
		current_profile: () => rpc('state.get').profile,
		backend_enabled: () => rpc('state.get').enabled == true,
		set_backend_enabled: enabled => rpc('state.patch', { enabled: enabled == true }).ok == true,
		set_profile: profile => rpc('state.patch', { profile }).ok == true,
		SERVICE_NAME: 'opl-netfleet', service_state, set_service_state,
		shell_quote, capture_json, process_identity, run_owner, run_owner_result
	};
};
