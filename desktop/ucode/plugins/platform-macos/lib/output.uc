const respond = global.__netfleetDesktopOwner.respond;
return function(context) {
	const finish = context.use('events.operation').finish;
	let capture_failure;
	function ok(action, result) {
		if (index(['refresh', 'subscriptions-refresh', 'select'], action) >= 0) finish(result?.ok != false, null, result);
		respond({ ok: true, action, result });
	}
	function fail(action, error, detail) {
		const value = { ok: false, action, error, detail: detail ?? null };
		if (capture_failure != null) capture_failure(value);
		finish(false, error, detail);
		respond(value); die(error);
	}
	function capture(callback) {
		const previous = capture_failure;
		let failure, result;
		capture_failure = value => { failure = value; die(value.error); };
		try { result = { ok: true, result: callback() }; }
		catch (error) { result = failure ?? { ok: false, error: 'unexpected_error', detail: `${error}` }; }
		capture_failure = previous; return result;
	}
	return { ok, fail, capture };
};
