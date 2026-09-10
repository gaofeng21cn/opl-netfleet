const rpc = global.__netfleetDesktopOwner.rpc;
return function(context) {
	const model = context.use('models.subscriptions');
	function subscription_exists(id) { return rpc('state.get').subscriptions?.[id] != null; }
	function subscription_display_name(id) { return rpc('state.get').subscriptions?.[id]?.name ?? id; }
	function subscription_options() {
		const sources = rpc('state.get').subscriptions ?? {};
		return map(sort(keys(sources)), id => ({ ref: `subscription:${id}`, display_name: sources[id].name ?? id }));
	}
	function subscription_quota(id) {
		const source = rpc('state.get').subscriptions?.[id];
		// Existing caches retain their last known quota until the next real refresh.
		if (!exists(source ?? {}, 'subscriptionUserinfo')) return source?.quota ?? { state: 'unknown' };
		const values = model.userinfo(`Subscription-Userinfo: ${source.subscriptionUserinfo ?? ''}`);
		let expires_at = null;
		if (values?.expire > 0 && values.expire <= 253402300799) {
			const date = gmtime(values.expire);
			expires_at = sprintf('%04d-%02d-%02dT%02d:%02d:%02d.000Z', date.year, date.mon, date.mday, date.hour, date.min, date.sec);
		}
		return model.quota_state({ available: values?.avaliable, total: values?.total, used: values?.used, expires_at });
	}
	function update_result(id) { return rpc('subscription.update', { id }); }
	return { subscription_exists, subscription_display_name, subscription_options, subscription_quota, update_result };
};
