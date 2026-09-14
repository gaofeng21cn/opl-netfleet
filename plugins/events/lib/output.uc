

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let ok, fail;
let capture_failure = null;

const finish = context.use("events.operation").finish;

ok = function(action, data) {
	if (action == "refresh" || action == "subscriptions-refresh" || action == "select") {
		const result = data?.result ?? data;
		finish(result?.ok != false, null, result);
	}
	print({ ok: true, action: action, result: data });
};

fail = function(action, error, detail) {
	if (capture_failure != null) capture_failure({ ok: false, action, error, detail: detail ?? null });
	finish(false, error, detail);
	print({ ok: false, action: action, error: error, detail: detail ?? null });
	exit(1);
};

// Plugin actions must return failures to their transaction owner before exiting.
function capture(callback) {
	const previous = capture_failure;
	let failure = null;
	capture_failure = value => { failure = value; die(value.error); };
	let result;
	try { result = { ok: true, result: callback() }; }
	catch (error) { result = failure ?? { ok: false, error: "unexpected_error", detail: `${error}` }; }
	capture_failure = previous;
	return result;
};

return { ok, fail, capture };
};
