const rpc = global.__netfleetDesktopOwner.rpc;
return function(context) {
	return { device_name: () => rpc('network.status').device_name ?? 'Mac', upstream_ready: () => rpc('network.status').upstream_ready == true };
};
