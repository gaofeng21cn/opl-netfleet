import * as fs from 'fs';
import * as socket from 'socket';

// loadfile() factories compile imports independently. Keep the dispatcher on the
// current VM, so every platform factory shares one command stack and held lock.
function owner() {
	if (global.__netfleetDesktopOwner == null) die('desktop_executor_unavailable');
	return global.__netfleetDesktopOwner;
}
export function shell_quote(value) { return `'${replace(`${value}`, "'", "'\\''")}'`; }
export function rpc(method, params) {
	const body = sprintf('%J', { method, params: params ?? {} });
	const connection = socket.connect({ path: getenv('NETFLEET_SOCKET') }, null, null, 3000);
	if (connection == null) die('desktop_owner_unavailable');
	let result;
	try {
		if (!connection.setopt(socket.SOL_SOCKET, socket.SO_RCVTIMEO, { sec: 120, usec: 0 }) ||
			!connection.setopt(socket.SOL_SOCKET, socket.SO_SNDTIMEO, { sec: 120, usec: 0 })) die('desktop_socket_timeout_unavailable');
		const request = `POST /rpc HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nAuthorization: Bearer ${getenv('NETFLEET_RPC_TOKEN')}\r\nContent-Type: application/json\r\nContent-Length: ${length(body)}\r\n\r\n${body}`;
		let sent = 0;
		while (sent < length(request)) {
			const size = connection.send(substr(request, sent));
			if (size == null || size <= 0) die('desktop_owner_unavailable');
			sent += size;
		}
		let response = '';
		const deadline = time() + 120;
		while (true) {
			if (time() >= deadline) die('desktop_owner_timeout');
			const chunk = connection.recv(65536);
			if (chunk == null) die('desktop_owner_unavailable');
			if (!length(chunk)) break;
			response += chunk;
			if (length(response) > 8 * 1024 * 1024 + 8192) die('desktop_owner_response_too_large');
		}
		const boundary = index(response, '\r\n\r\n');
		if (boundary < 0 || boundary > 8192) die('desktop_owner_response_invalid');
		const headers = substr(response, 0, boundary), payload = substr(response, boundary + 4);
		const size = match(lc(headers), /(^|\r\n)content-length: ([0-9]+)(\r\n|$)/);
		if (size == null || int(size[2]) != length(payload) || length(payload) > 8 * 1024 * 1024 ||
			match(lc(headers), /(^|\r\n)transfer-encoding:/)) die('desktop_owner_response_invalid');
		try { result = json(payload); } catch (error) { die('desktop_owner_response_invalid'); }
		if (!match(headers, /^HTTP\/1\.[01] 200 /)) die(result?.error ?? 'desktop_owner_failed');
	} catch (error) { connection.close(); die(error.message); }
	connection.close();
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
