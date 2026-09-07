return function(context) {
	const reader = context.use("host-info.reader");
	function inspect(argv) {
		if (length(argv) != 1) return { ok: false, error: "unexpected_arguments" };
		return reader.snapshot();
	};
	return { inspect };
};
