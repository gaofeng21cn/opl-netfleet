import * as socket from "socket";

function now_ms() {
	const value = clock();
	return value[0] * 1000 + int(value[1] / 1000000);
};

function parse_target(target) {
	if (type(target) == "object" && type(target.unix_path) == "string" && length(target.unix_path) > 0) {
		return { kind: "unix", path: target.unix_path, host_header: "localhost" };
	}
	if (type(target) != "string") return null;
	const ipv4 = match(target, /^http:\/\/(127\.0\.0\.1|localhost):([0-9]+)$/);
	if (ipv4 != null) {
		const port = int(ipv4[2]);
		return port > 0 && port < 65536 ? { kind: "tcp", host: "127.0.0.1", port, host_header: `${ipv4[1]}:${port}` } : null;
	}
	const ipv6 = match(target, /^http:\/\/\[(::1)\]:([0-9]+)$/);
	if (ipv6 != null) {
		const port = int(ipv6[2]);
		return port > 0 && port < 65536 ? { kind: "tcp6", host: "::1", port, host_header: `[::1]:${port}` } : null;
	}
	return null;
};

function is_in_progress(sock) {
	const code = sock.error(true);
	return code == 36 || code == 115 || match(lc(sock.error() ?? ""), /in progress/) != null;
};

function is_retryable_io(sock) {
	const code = sock.error(true);
	return code == 4 || code == 11 || code == 35;
};

function decode_chunked(raw) {
	let pos = 0;
	const parts = [];
	const total = length(raw);
	while (true) {
		const rel = index(substr(raw, pos, 128), "\r\n");
		if (rel < 0) return total - pos > 128 ? { error: true } : { done: false };
		const line = substr(raw, pos, rel);
		const semi = index(line, ";");
		const hex_len = trim(semi < 0 ? line : substr(line, 0, semi));
		if (!match(hex_len, /^[0-9A-Fa-f]+$/)) return { error: true };
		const size = int(hex_len, 16);
		pos += rel + 2;
		if (size == 0) {
			if (pos + 2 <= total && substr(raw, pos, 2) == "\r\n") return { done: true, body: join("", parts) };
			if (index(substr(raw, pos), "\r\n\r\n") >= 0) return { done: true, body: join("", parts) };
			return { done: false };
		}
		if (pos + size + 2 > total) return { done: false };
		push(parts, substr(raw, pos, size));
		pos += size;
		if (substr(raw, pos, 2) != "\r\n") return { error: true };
		pos += 2;
	}
};

function try_complete_response(raw, method, discard_body, eof, max_bytes) {
	const boundary = index(raw, "\r\n\r\n");
	if (boundary < 0) {
		if (length(raw) > 16384) return { done: true, result: { ok: false, status: 0, body: null, transport_error: "invalid_response", transport_code: 52 } };
		if (!eof) return { done: false };
		if (length(raw) == 0) return { done: true, result: { ok: false, status: 0, body: null, transport_error: "empty_reply", transport_code: 52 } };
		return { done: true, result: { ok: false, status: 0, body: null, transport_error: "invalid_response", transport_code: 52 } };
	}
	if (boundary > 16384) return { done: true, result: { ok: false, status: 0, body: null, transport_error: "invalid_response", transport_code: 52 } };
	const headers = substr(raw, 0, boundary);
	const status_line_end = index(headers, "\r\n");
	const status_line = status_line_end < 0 ? headers : substr(headers, 0, status_line_end);
	const status_match = match(status_line, /^HTTP\/1\.[01][ \t]+([0-9]{3})([ \t]|$)/);
	if (status_match == null) return { done: true, result: { ok: false, status: 0, body: null, transport_error: "invalid_response", transport_code: 52 } };
	const status = int(status_match[1]);
	if (discard_body == true || status == 204 || status == 304 || method == "HEAD") {
		return { done: true, result: { ok: true, status, body: "", transport_error: null, transport_code: 0 } };
	}
	const payload = substr(raw, boundary + 4);
	const lower = lc(headers);
	if (match(lower, /(^|\r\n)transfer-encoding:[^\r\n]*chunked/) != null) {
		const chunked = decode_chunked(payload);
		if (chunked.error) return { done: true, result: { ok: false, status: 0, body: null, transport_error: "invalid_response", transport_code: 52 } };
		if (chunked.done) {
			if (max_bytes != null && length(chunked.body) > max_bytes) {
				return { done: true, result: { ok: false, status: 0, body: null, transport_error: "response_too_large", transport_code: 63 } };
			}
			return { done: true, result: { ok: true, status, body: chunked.body, transport_error: null, transport_code: 0 } };
		}
		if (max_bytes != null && length(payload) > max_bytes + 4096) {
			return { done: true, result: { ok: false, status: 0, body: null, transport_error: "response_too_large", transport_code: 63 } };
		}
		return eof ? { done: true, result: { ok: false, status: 0, body: null, transport_error: "invalid_response", transport_code: 52 } } : { done: false };
	}
	const content_length = match(lower, /(^|\r\n)content-length:[ \t]*([0-9]+)[ \t]*(\r\n|$)/);
	if (content_length != null) {
		const expected = int(content_length[2]);
		if (max_bytes != null && expected > max_bytes) {
			return { done: true, result: { ok: false, status: 0, body: null, transport_error: "response_too_large", transport_code: 63 } };
		}
		if (length(payload) >= expected) {
			return { done: true, result: { ok: true, status, body: substr(payload, 0, expected), transport_error: null, transport_code: 0 } };
		}
		return eof ? { done: true, result: { ok: false, status: 0, body: null, transport_error: "invalid_response", transport_code: 52 } } : { done: false };
	}
	if (max_bytes != null && length(payload) > max_bytes) {
		return { done: true, result: { ok: false, status: 0, body: null, transport_error: "response_too_large", transport_code: 63 } };
	}
	return eof ? { done: true, result: { ok: true, status, body: payload, transport_error: null, transport_code: 0 } } : { done: false };
};

function build_request_bytes(parsed_target, spec) {
	const method = spec?.method ?? "GET";
	const path = spec?.path ?? "/";
	const body = type(spec?.body) == "string" ? spec.body : "";
	let lines = `${method} ${path} HTTP/1.1\r\nHost: ${parsed_target.host_header}\r\nConnection: close\r\n`;
	let has_content_length = false;
	for (let key, value in spec?.headers ?? {}) {
		if (type(key) != "string" || value == null) continue;
		const clean_key = replace(key, /[\r\n:]/g, "");
		const clean_value = replace(`${value}`, /[\r\n]/g, "");
		if (lc(clean_key) == "content-length") has_content_length = true;
		lines += `${clean_key}: ${clean_value}\r\n`;
	}
	if (length(body) > 0 && !has_content_length) lines += `Content-Length: ${length(body)}\r\n`;
	return `${lines}\r\n${body}`;
};

export function request_all(specs, default_timeout_ms) {
	if (type(specs) != "array" || length(specs) == 0) return [];
	const started = now_ms();
	const flags = socket.SOCK_STREAM | socket.SOCK_NONBLOCK | (socket.SOCK_CLOEXEC ?? 0);
	const items = [];
	const results = [];

	function finish(item, value) {
		if (item.done) return;
		item.done = true;
		try { if (item.sock != null) item.sock.close(); } catch (error) {}
		item.sock = null;
		results[item.idx] = value;
	};

	try {
		for (let i = 0; i < length(specs); i++) {
			const spec = specs[i] ?? {};
			results[i] = { ok: false, status: 0, body: null, transport_error: "uninitialized", transport_code: 7 };
			const parsed_target = parse_target(spec.target);
			if (parsed_target == null || type(spec.path) != "string" || substr(spec.path, 0, 1) != "/") {
				results[i] = { ok: false, status: 0, body: null, transport_error: "invalid_target", transport_code: 3 };
				continue;
			}
			const timeout_ms = type(spec.timeout_ms) == "int" && spec.timeout_ms > 0 ? spec.timeout_ms :
				(type(default_timeout_ms) == "int" && default_timeout_ms > 0 ? default_timeout_ms : 5000);
			const connect_timeout_ms = type(spec.connect_timeout_ms) == "int" && spec.connect_timeout_ms > 0 ? spec.connect_timeout_ms : 2000;
			const max_bytes = type(spec.max_bytes) == "int" && spec.max_bytes > 0 ? spec.max_bytes : 33554432;
			const family = parsed_target.kind == "unix" ? socket.AF_UNIX :
				(parsed_target.kind == "tcp6" ? socket.AF_INET6 : socket.AF_INET);
			const sock = socket.create(family, flags);
			if (sock == null) {
				results[i] = { ok: false, status: 0, body: null, transport_error: "socket_create_failed", transport_code: 7 };
				continue;
			}
			const deadline = started + timeout_ms;
			const connect_deadline = started + connect_timeout_ms < deadline ? started + connect_timeout_ms : deadline;
			const item = {
				idx: i, sock, method: spec.method ?? "GET", discard_body: spec.discard_body == true,
				max_bytes, deadline, connect_deadline,
				req: build_request_bytes(parsed_target, spec), sent: 0, buf: "", state: "connect", done: false
			};
			const connected = parsed_target.kind == "unix" ?
				sock.connect({ path: parsed_target.path }) :
				sock.connect(parsed_target.host, parsed_target.port);
			if (connected == true) {
				item.state = "send";
				push(items, item);
			} else if (is_in_progress(sock)) {
				push(items, item);
			} else {
				finish(item, { ok: false, status: 0, body: null, transport_error: "connect_failed", transport_code: 7 });
			}
		}

		while (true) {
			const now = now_ms();
			const descriptors = [];
			const active = [];
			let earliest = null;
			for (let i = 0; i < length(items); i++) {
				const item = items[i];
				if (item.done) continue;
				const item_deadline = item.state == "connect" ? item.connect_deadline : item.deadline;
				if (now >= item_deadline) {
					finish(item, { ok: false, status: 0, body: null, transport_error: "timeout", transport_code: 28 });
					continue;
				}
				if (earliest == null || item_deadline < earliest) earliest = item_deadline;
				const events = item.state == "recv" ? (socket.POLLIN | socket.POLLERR | socket.POLLHUP) : (socket.POLLOUT | socket.POLLERR | socket.POLLHUP);
				push(descriptors, [item.sock, events]);
				push(active, item);
			}
			if (length(active) == 0) break;

			let wait_ms = earliest - now;
			if (wait_ms < 1) wait_ms = 1;
			const polled = socket.poll(wait_ms, ...descriptors);
			if (polled == null) continue;
			for (let j = 0; j < length(polled); j++) {
				const entry = polled[j];
				const sock_ref = entry[0], revents = entry[1];
				if (!revents) continue;
				let item = null;
				for (let k = 0; k < length(active); k++) {
					if (active[k].sock == sock_ref) { item = active[k]; break; }
				}
				if (item == null || item.done) continue;

				if (item.state == "connect") {
					const so_err = item.sock.getopt(socket.SOL_SOCKET, socket.SO_ERROR);
					if (so_err != 0) {
						finish(item, { ok: false, status: 0, body: null, transport_error: "connect_failed", transport_code: 7 });
						continue;
					}
					item.state = "send";
				}
				if (item.state == "send") {
					if (revents & socket.POLLERR) {
						finish(item, { ok: false, status: 0, body: null, transport_error: "send_failed", transport_code: 56 });
						continue;
					}
					const chunk = item.sock.send(substr(item.req, item.sent));
					if (chunk == null || chunk <= 0) {
						if (!is_retryable_io(item.sock)) {
							finish(item, { ok: false, status: 0, body: null, transport_error: "send_failed", transport_code: 56 });
						}
						continue;
					}
					item.sent += chunk;
					if (item.sent >= length(item.req)) item.state = "recv";
					continue;
				}
				if (item.state == "recv") {
					while (!item.done) {
						const data = item.sock.recv(65536);
						if (data == null) {
							if (is_retryable_io(item.sock)) break;
							if (length(item.buf) > 0) {
								const check = try_complete_response(item.buf, item.method, item.discard_body, true, item.max_bytes);
								if (check.result?.ok) { finish(item, check.result); break; }
							}
							finish(item, { ok: false, status: 0, body: null, transport_error: "recv_failed", transport_code: 56 });
							break;
						}
						if (length(data) == 0) {
							const check = try_complete_response(item.buf, item.method, item.discard_body, true, item.max_bytes);
							finish(item, check.result);
							break;
						}
						item.buf += data;
						if (length(item.buf) > item.max_bytes + 16384) {
							finish(item, { ok: false, status: 0, body: null, transport_error: "response_too_large", transport_code: 63 });
							break;
						}
						const check = try_complete_response(item.buf, item.method, item.discard_body, false, item.max_bytes);
						if (check.done) {
							finish(item, check.result);
							break;
						}
					}
				}
			}
		}
	} catch (error) {
		for (let i = 0; i < length(items); i++) {
			try { if (items[i].sock != null) items[i].sock.close(); } catch (close_error) {}
		}
		die(error?.message ?? "http_request_failed");
	}
	for (let i = 0; i < length(items); i++) {
		try { if (items[i].sock != null) items[i].sock.close(); } catch (close_error) {}
	}
	return results;
};

export function request(target, spec) {
	return request_all([{ ...(spec ?? {}), target }], spec?.timeout_ms)[0];
};
