import * as fs from 'fs';

// loadfile() factories compile imports independently. Keep the dispatcher on the
// current VM, so every platform factory shares one command stack and held lock.
function owner() {
	if (global.__netfleetDesktopOwner == null) die('desktop_executor_unavailable');
	return global.__netfleetDesktopOwner;
}
export function shell_quote(value) { return `'${replace(`${value}`, "'", "'\\''")}'`; }
export function rpc(method, params) {
	const command = `node ${shell_quote(`${getenv('NETFLEET_DESKTOP_ROOT')}/runtime/rpc.mjs`)} ${shell_quote(method)} ${shell_quote(sprintf('%J', params ?? {}))}`;
	const pipe = fs.popen(command);
	if (pipe == null) die('desktop_owner_unavailable');
	let result;
	try { result = json(pipe.read('all')); } catch (error) { pipe.close(); die('desktop_owner_response_invalid'); }
	if (pipe.close() != 0) die(result?.error ?? 'desktop_owner_failed');
	return result;
}
export function respond(value) {
	const responses = owner().responses;
	if (!length(responses)) die('desktop_response_without_command');
	responses[length(responses) - 1] = value;
}
export function invoke(argv) {
	const dispatcher = owner(), responses = dispatcher.responses;
	push(responses, null);
	let result;
	try { result = dispatcher.executor(argv); } catch (error) { result = responses[length(responses) - 1] ?? { ok: false, error: error.message }; }
	const response = pop(responses);
	return response ?? result;
}
export function process_identity(pid) {
	if (pid == null || pid == 'self') {
		const self = fs.popen('printf "%s" "$PPID"');
		pid = int(self.read('all')); self.close();
	}
	if (type(pid) != 'int' || pid <= 0) return null;
	const pipe = fs.popen(`ps -p ${pid} -o pid= -o ppid= -o lstart= -o stat= 2>/dev/null`);
	const line = trim(pipe?.read('all') ?? '');
	if (pipe == null || pipe.close() != 0 || !length(line)) return null;
	const parts = match(line, /^([0-9]+)\s+([0-9]+)\s+(.+)\s+(\S+)$/);
	return parts == null ? null : { pid: int(parts[1]), parent: int(parts[2]), start: trim(parts[3]), started: trim(parts[3]), alive: index(parts[4], 'Z') < 0 };
}

export function set_executor(value) {
	if (global.__netfleetDesktopOwner != null) die('desktop_executor_already_initialized');
	global.__netfleetDesktopOwner = { executor: value, responses: [], rpc, shell_quote, process_identity, invoke, respond };
}
