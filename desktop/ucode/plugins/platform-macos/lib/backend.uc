const rpc = global.__netfleetDesktopOwner.rpc;
return function(context) {
	const storage = context.use('mihomo.profile-storage');
	function running() { return rpc('core.status').running == true; }
	function cleanup_state() {
		const core = rpc('core.status'), network = rpc('network.status');
		return { ok: core.running == false && network.clean == true, mihomo_stopped: core.running == false,
			service_stopped: core.running == false, network_restored: network.clean == true };
	}
	function stop() { const result = rpc('core.stop'); const readback = cleanup_state(); return { ok: result.ok == true && readback.ok, requested: true, readback }; }
	function lan_runtime_state() {
		const state = rpc('network.status');
		return { scope: 'local-mac', mode: state.mode, transparent_proxy_ready: state.ready == true,
			dns_ready: state.dns_ready == true, dashboard_lan_ready: false, allow_lan: false,
			interception_active: state.mode == 'tun' && state.ready == true };
	}
	return { ...storage, running, cleanup_state, stop, lan_runtime_state,
		restart: () => rpc('core.start').ok == true, update_subscription: id => rpc('subscription.update', { id }).ok == true };
};
