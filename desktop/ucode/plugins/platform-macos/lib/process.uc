const shell_quote = global.__netfleetDesktopOwner.shell_quote;
const process_identity = global.__netfleetDesktopOwner.process_identity;
const invoke = global.__netfleetDesktopOwner.invoke;
return function(context) {
	function run_owner(action, detail) { return invoke(detail == null ? [action] : [action, detail])?.ok == true; }
	function run_owner_result(argv) {
		const result = invoke(argv);
		return { ok: result?.ok == true, state: result?.result?.state ?? null, error: result?.error ?? null };
	}
	return { shell_quote, process_identity, run_owner, run_owner_result };
};
