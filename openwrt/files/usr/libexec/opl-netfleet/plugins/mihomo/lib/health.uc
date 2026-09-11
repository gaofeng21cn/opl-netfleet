import { readfile, popen } from "fs";
import * as socket from "socket";

// Read each kernel socket table once per observation, without a netstat process.
export function parse_listeners(tables) {
	const ports = { tcp: {}, udp: {} };
	for (let name, data in tables) {
		const protocol = substr(name, 0, 3);
		for (let line in split(data ?? "", "\n")) {
			const fields = split(trim(line), /[[:space:]]+/);
			const address = split(fields[1] ?? "", ":");
			if (length(address) != 2 || !match(address[0], /^(00000000|00000000000000000000000000000000)$/) ||
				!match(address[1], /^[0-9A-Fa-f]{4}$/) ||
				fields[3] != (protocol == "tcp" ? "0A" : "07")) continue;
			ports[protocol][int(address[1], 16)] = true;
		}
	}
	return ports;
};

export function listeners() {
	let tables = {};
	for (let name in ["tcp", "tcp6", "udp", "udp6"]) tables[name] = readfile(`/proc/net/${name}`);
	return parse_listeners(tables);
};

export function rule_snapshot(table) {
	const process = popen(`nft -j list table inet ${table} 2>/dev/null`);
	let data = null;
	try { data = process == null ? null : json(process.read("all")); } catch (error) {}
	if (process == null || process.close() != 0) return { present: false, chains: {} };
	let chains = {}, present = false;
	for (let item in data?.nftables ?? []) {
		if (item.table?.family == "inet" && item.table?.name == table) present = true;
		if (item.chain != null) chains[item.chain.name] ??= [];
		if (item.rule != null) {
			chains[item.rule.chain] ??= [];
			for (let expr in item.rule.expr ?? []) push(chains[item.rule.chain], expr);
		}
	}
	return { present, chains };
};

const QUESTION = "\x06health\x0copl-netfleet\x07invalid\x00\x00\x10\x00\x01";
const QUERY = "NF\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + QUESTION;

export function dns_response_ok(data) {
	// The local rcode resolver returns NXDOMAIN with this question and no RRs.
	return type(data) == "string" && length(data) == length(QUERY) &&
		substr(data, 0, 2) == substr(QUERY, 0, 2) &&
		(ord(data, 2) & 0xfa) == 0x80 && (ord(data, 3) & 0x7f) == 3 &&
		substr(data, 4) == substr(QUERY, 4);
};

export function dns_ready(port) {
	if (type(port) != "int" || port < 1 || port > 65535) return false;
	const sock = socket.create(socket.AF_INET, socket.SOCK_DGRAM | socket.SOCK_NONBLOCK);
	if (sock == null) return false;
	let ready = false;
	try {
		if (sock.connect("127.0.0.1", port) && sock.send(QUERY) == length(QUERY)) {
			const events = socket.poll(1000, [sock, socket.POLLIN]);
			if (length(events ?? []) > 0 && (events[0][1] & socket.POLLIN))
				ready = dns_response_ok(sock.recv(512));
		}
	} catch (error) {}
	sock.close();
	return ready;
};
