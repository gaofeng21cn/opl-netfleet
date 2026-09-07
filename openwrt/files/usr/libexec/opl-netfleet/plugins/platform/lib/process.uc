return function(context) {
	function shell_quote(value) {
		return `'${replace(`${value}`, "'", "'\\''")}'`;
	}
	function run_owner(action, detail) {
		const suffix = detail == null ? "" : ` ${shell_quote(detail)}`;
		// The calling host owns the mutation lock for this complete operation.
		return system(`ucode /usr/libexec/opl-netfleet/main.uc ${shell_quote(action)}${suffix} >/dev/null 2>&1`) == 0;
	}
	return { shell_quote, run_owner };
};
