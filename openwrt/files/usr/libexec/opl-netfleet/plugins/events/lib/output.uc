

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let ok, fail;

const finish = context.use("events.operation").finish;

ok = function(action, data) {
	if (action == "refresh" || action == "subscriptions-refresh" || action == "select") {
		const result = data?.result ?? data;
		finish(result?.ok != false, null, result);
	}
	print({ ok: true, action: action, result: data });
};

fail = function(action, error, detail) {
	finish(false, error, detail);
	print({ ok: false, action: action, error: error, detail: detail ?? null });
	exit(1);
};

return { ok, fail };
};
