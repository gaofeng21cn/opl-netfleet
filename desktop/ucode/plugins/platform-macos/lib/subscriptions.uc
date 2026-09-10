const rpc = global.__netfleetDesktopOwner.rpc;
return function(context) {
	function subscription_exists(id) { return rpc('state.get').subscriptions?.[id] != null; }
	function subscription_display_name(id) { return rpc('state.get').subscriptions?.[id]?.name ?? id; }
	function subscription_options() {
		const sources = rpc('state.get').subscriptions ?? {};
		return map(sort(keys(sources)), id => ({ ref: `subscription:${id}`, display_name: sources[id].name ?? id }));
	}
	function subscription_quota(id) { return rpc('state.get').subscriptions?.[id]?.quota ?? { state: 'unknown' }; }
	function update_result(id) { return rpc('subscription.update', { id }); }
	return { subscription_exists, subscription_display_name, subscription_options, subscription_quota, update_result };
};
