import * as fs from "fs";

return function(context) {
	function shell_quote(value) {
		return `'${replace(`${value}`, "'", "'\\''")}'`;
	}
	function run_owner(action, detail) {
		const suffix = detail == null ? "" : ` ${shell_quote(detail)}`;
		// The calling host owns the mutation lock for this complete operation.
		return system(`ucode /usr/libexec/opl-netfleet/main.uc ${shell_quote(action)}${suffix} >/dev/null 2>&1`) == 0;
	}
	function run_owner_result(argv, output, error_output) {
		const status = system(`ucode /usr/libexec/opl-netfleet/main.uc ${join(" ", map(argv, shell_quote))} >${shell_quote(output)} 2>${shell_quote(error_output)}`);
		let response = null;
		try { response = json(fs.readfile(output)); } catch (error) {}
		return { ok: status == 0 && response?.ok == true, state: response?.result?.state ?? null,
			error: response?.error ?? (status == 0 ? "selection_readback_failed" : "selection_failed") };
	}
	function process_identity(pid) {
		const source = fs.readfile(`/proc/${pid ?? "self"}/stat`);
		const fields = source == null ? null : match(source, /^([0-9]+) \(.*\) (.*)$/);
		if (fields == null) return null;
		const tail = split(trim(fields[2]), " ");
		return length(tail) > 19 ? { pid: int(fields[1]), started: tail[19], alive: tail[0] != "Z" && tail[0] != "X" } : null;
	}
	return { shell_quote, run_owner, run_owner_result, process_identity };
};
