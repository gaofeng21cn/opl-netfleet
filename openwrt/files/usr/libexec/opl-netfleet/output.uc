export function ok(action, data) {
	print({ ok: true, action: action, result: data });
};

export function fail(action, error, detail) {
	print({ ok: false, action: action, error: error, detail: detail ?? null });
	exit(1);
};
