const rpc = global.__netfleetDesktopOwner.rpc;
return function(context) {
	const state = getenv('NETFLEET_STATE_DIR');
	const config = rpc('state.get');
	return { KIND: 'native-mihomo', PLATFORM: 'macos', ROOT_DIR: `${state}/backend`, RUN_DIR: `${state}/backend/run`,
		SERVICE: 'opl-netfleet-desktop', STATE_DIR: state, LOG_PATH: `${state}/core.log`,
		SUBSCRIPTION_CONFIG_PATH: null, API: `http://127.0.0.1:${config.ports.controller}`,
		metadata: () => ({ id: 'native-mihomo', platform: 'macos', display_name: 'NetFleet + Mihomo · macOS' }),
		environment: () => ({ backend: 'native-mihomo', platform: 'macos' }) };
};
