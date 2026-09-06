import { finish } from "./application/operation.uc";

export function ok(action, data) {
	if (action == "refresh" || action == "subscriptions-refresh") {
		const result = data?.result ?? data;
		finish(result?.ok != false, null, result);
	}
	print({ ok: true, action: action, result: data });
};

export function fail(action, error, detail) {
	finish(false, error, detail);
	print({ ok: false, action: action, error: error, detail: detail ?? null });
	exit(1);
};
