import * as fs from "fs";

return function(context) {
	function shell_quote(value) {
		return `'${replace(`${value}`, "'", "'\\''")}'`;
	}
	function capture(command, seconds, input) {
		if (type(command) != 'string' || type(seconds) != 'int' || seconds < 1 || seconds > 300)
			die('process_capture_invalid');
		const directory = fs.mkdtemp('/tmp/netfleet-capture.XXXXXX');
		if (!directory) die('process_capture_unavailable');
		const output = directory + '/output', source = directory + '/input';
		let result, failure;
		try {
			if (input != null && fs.writefile(source, input) != length(input)) die('process_capture_unavailable');
			// fread(pipe) may stop at SIGCHLD from an unrelated uloop child.
			// waitpid retries EINTR; read a regular file only after the command exits.
			const bounded = 'umask 077; ulimit -f 4096 || exit 125; ' + command;
			const status = system(`timeout -k 1 ${seconds} /bin/sh -c ${shell_quote(bounded)}` +
				(input == null ? '' : ` <${shell_quote(source)}`) + ` >${shell_quote(output)} 2>/dev/null`);
			const size = fs.stat(output)?.size;
			result = { status, output: size != null && size <= 2097152 ? fs.readfile(output) : null };
		} catch (error) { failure = error; }
		fs.unlink(source); fs.unlink(output); fs.rmdir(directory);
		if (failure) die(failure.message);
		return result;
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
	return { shell_quote, capture, run_owner, run_owner_result, process_identity };
};
