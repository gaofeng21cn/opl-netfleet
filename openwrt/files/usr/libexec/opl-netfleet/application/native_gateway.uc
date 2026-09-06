#!/usr/bin/ucode

import * as fs from "fs";
import { cursor } from "uci";
import { read_json, read_yaml, shell_quote, sha256 } from "../adapters/uci.uc";
import { private_file, private_directory, atomic_json } from "../adapters/native.uc";

const BASE = "/etc/opl-netfleet/native";
const RUN = `${BASE}/run`;
const STATE = "/var/run/opl-netfleet-core";
const OWNERSHIP = `${STATE}/ownership.json`;
const CONFIG = `${RUN}/config.yaml`;
const VENDOR = "/usr/share/opl-netfleet/nikki";
const SERVICE = "opl-netfleet-core";
const COMMAND = ["/usr/bin/mihomo", "-d", RUN, "-f", CONFIG];
const COMPAT = "/usr/libexec/opl-netfleet-compat/control.py";

function shell(command) { return system(command + " >/dev/null 2>&1") == 0; };
function capture(command) {
	const p = fs.popen(command + " 2>/dev/null");
	if (p == null) return null;
	const out = p.read("all");
	return p.close() == 0 ? out : null;
};
function parse(text) { try { return json(text); } catch (error) { return null; } };
function directory(path) {
	return fs.lstat(path) == null ? fs.mkdir(path, 0700) : private_directory(path);
};
function uci_value(section, option, fallback) { return cursor().get("netfleet", section, option) ?? fallback; };
function enabled(section, option) { return `${uci_value(section, option, "0")}` == "1"; };
function merge(base, overlay) {
	const out = type(base) == "object" ? { ...base } : {};
	for (let key, value in overlay ?? {})
		out[key] = type(value) == "object" ? merge(out[key], value) : value;
	return out;
};
function source_path(ref) {
	const parts = split(ref ?? "", ":");
	if (length(parts) != 2 || !match(parts[1], /^[A-Za-z0-9_.-]+$/) || index(parts[1], "..") >= 0) return null;
	return parts[0] == "file" ? `${BASE}/profiles/${parts[1]}` :
		parts[0] == "subscription" ? `${BASE}/subscriptions/${parts[1]}.yaml` : null;
};
function process_state() {
	const data = parse(capture(`ubus call service list '{"name":"${SERVICE}"}'`));
	const instance = data?.[SERVICE]?.instances?.core;
	const pid = instance?.pid;
	const actual = pid ? fs.readfile(`/proc/${pid}/cmdline`) : null;
	return { registered: data?.[SERVICE] != null, pid: pid,
		running: instance?.running == true && actual == join("\u0000", COMMAND) + "\u0000" };
};
function controller_ready() {
	return type(parse(capture(`curl -q -fsS --max-time 2 --noproxy '*' --proxy '' ` +
		`--unix-socket ${shell_quote(`${RUN}/controller.sock`)} http://localhost/version`))?.version) == "string";
};
function ownership() {
	return private_file(OWNERSHIP) ? read_json(OWNERSHIP) : null;
};
function routes_present(state) {
	for (let family in state?.families ?? []) {
		const rules = capture(`ip -${family} rule show`);
		const routes = capture(`ip -${family} route show table ${state.table}`);
		if (rules == null || routes == null || index(rules, `lookup ${state.table}`) < 0 ||
			index(routes, "local default dev lo") < 0) return false;
	}
	return true;
};
function status() {
	const core = process_state();
	const state = ownership();
	const table = shell("nft list table inet netfleet");
	const attached = state != null && state.core_pid == core.pid && table && routes_present(state);
	return { ok: true, result: { ready: core.running && controller_ready() && attached,
		core_running: core.running, registered: core.registered, attached: attached,
		clean: !table && state == null, config_sha256: private_file(CONFIG) ? sha256(CONFIG) : null } };
};
function prepare() {
	if (read_json("/etc/opl-netfleet/backend.json")?.kind != "native-mihomo")
		return { ok: false, error: "native_backend_not_selected" };
	if (!enabled("config", "enabled")) return { ok: false, error: "backend_disabled" };
	const nikki = parse(capture("ubus call service list '{\"name\":\"nikki\"}'"));
	for (let name, instance in nikki?.nikki?.instances ?? {})
		if (instance.running == true) return { ok: false, error: "existing_backend_owner" };
	if (shell("pidof mihomo")) return { ok: false, error: "existing_backend_owner" };
	if (!directory(BASE) || !directory(RUN) || !directory(STATE)) return { ok: false, error: "private_directory_required" };
	const path = source_path(uci_value("config", "profile", null));
	if (path == null) return { ok: false, error: "invalid_profile_reference" };
	const source = read_yaml(path, true);
	const overlay = parse(capture(`ucode -S ${shell_quote(`${VENDOR}/mixin.uc`)}`));
	if (type(source) != "object" || type(overlay) != "object") return { ok: false, error: "profile_unreadable" };
	const extra = fs.lstat(`${BASE}/mixin.json`) == null ? {} : read_json(`${BASE}/mixin.json`);
	if (type(extra) != "object") return { ok: false, error: "mixin_unreadable" };
	const replacements = {
		authentication: [["authentication"]], tun_dns_hijack: [["tun", "dns-hijack"]],
		fake_ip_filter: [["dns", "fake-ip-filter"]], hosts: [["hosts"]],
		dns_nameserver: [["dns", "default-nameserver"], ["dns", "proxy-server-nameserver"],
			["dns", "direct-nameserver"], ["dns", "nameserver"], ["dns", "fallback"]],
		dns_nameserver_policy: [["dns", "nameserver-policy"]],
		sniffer_force_domain_name: [["sniffer", "force-domain"]],
		sniffer_ignore_domain_name: [["sniffer", "skip-domain"]], sniffer_sniff: [["sniffer", "sniff"]]
	};
	for (let option, paths in replacements) {
		if (!enabled("mixin", option)) continue;
		for (let fields in paths) {
			if (length(fields) == 1) delete source[fields[0]];
			else if (type(source[fields[0]]) == "object") delete source[fields[0]][fields[1]];
		}
	}
	const profile = merge(merge(source, extra), overlay);
	for (let field in ["proxies", "proxy-groups", "rules"]) {
		const additions = profile[`netfleet-${field}`] ?? [];
		if (length(additions) > 0) profile[field] = [...additions, ...(profile[field] ?? [])];
		delete profile[`netfleet-${field}`];
	}
	// Route installation remains exclusively in this owner, not in Mihomo TUN.
	if (profile.tun != null) profile.tun = { ...profile.tun, enable: false, "auto-route": false, "auto-redirect": false };
	for (let listener in profile.listeners ?? [])
		if (listener.type == "tun") return { ok: false, error: "tun_mode_not_supported" };
	if (uci_value("proxy", "tcp_mode", "tproxy") != "tproxy" || uci_value("proxy", "udp_mode", "tproxy") != "tproxy")
		return { ok: false, error: "tproxy_mode_required" };
	if (profile.dns?.enable != true || !profile.dns?.listen || !profile["tproxy-port"] || profile["allow-lan"] != true)
		return { ok: false, error: "gateway_listeners_required" };
	profile["external-controller-unix"] = `${RUN}/controller.sock`;
	if (!atomic_json(`${RUN}/candidate.json`, profile)) return { ok: false, error: "profile_write_failed" };
	if (!shell(`/usr/bin/mihomo -t -d ${shell_quote(RUN)} -f ${shell_quote(`${RUN}/candidate.json`)}`)) {
		fs.unlink(`${RUN}/candidate.json`);
		return { ok: false, error: "invalid_runtime_profile" };
	}
	if (!fs.rename(`${RUN}/candidate.json`, CONFIG)) return { ok: false, error: "profile_install_failed" };
	return { ok: true, result: { prepared: true, config_sha256: sha256(CONFIG) } };
};
function cleanup() {
	// The optional TLS layer cannot remain attached while the original gateway is changing.
	if (shell("nft list table inet netfleet_compat") && !shell("nft delete table inet netfleet_compat"))
		return { ok: false, error: "compatibility_cleanup_failed" };
	const state = ownership();
	if (state == null) return shell("nft list table inet netfleet") ?
		{ ok: false, error: "network_owner_unknown" } : { ok: true, result: { clean: true } };
	if (state.service != SERVICE || !match(`${state.table}`, /^[0-9]+$/) ||
		!match(`${state.pref}`, /^[0-9]+$/) || !match(state.mark ?? "", /^0x[0-9A-Fa-f]+$/) ||
		!match(state.mask ?? "", /^0x[0-9A-Fa-f]+$/)) return { ok: false, error: "network_owner_invalid" };
	// Remove interception before route state or the core is stopped.
	if (shell("nft list table inet netfleet") && !shell("nft delete table inet netfleet"))
		return { ok: false, error: "interception_cleanup_failed" };
	for (let family in state.families) {
		shell(`ip -${family} rule del pref ${state.pref} fwmark ${state.mark}/${state.mask} table ${state.table}`);
		shell(`ip -${family} route del local default dev lo table ${state.table}`);
		if (length(trim(capture(`ip -${family} route show table ${state.table}`) ?? "")) > 0 ||
			index(capture(`ip -${family} rule show`) ?? "", `lookup ${state.table}`) >= 0)
			return { ok: false, error: "route_cleanup_unconfirmed" };
	}
	for (let name, value in state.bridge ?? {}) {
		if (!shell(`sysctl -q -w ${shell_quote(`${name}=${value}`)}`)) return { ok: false, error: "bridge_restore_failed" };
	}
	fs.unlink(OWNERSHIP);
	return { ok: true, result: { clean: true } };
};
function attach() {
	const current = status();
	if (current.result.ready) return current;
	if (ownership() != null && !cleanup().ok) return { ok: false, error: "previous_cleanup_failed" };
	if (shell("nft list table inet netfleet")) return { ok: false, error: "network_owner_conflict" };
	for (let i = 0; i < 15; i++) {
		if (process_state().running && controller_ready()) break;
		if (i == 14) return { ok: false, error: "core_not_ready" };
		system("sleep 1");
	}
	const pid = process_state().pid;
	if (fs.stat("/sys/fs/cgroup/cgroup.controllers") != null) {
		const membership = fs.readfile(`/proc/${pid}/cgroup`) ?? "";
		if (index(membership, `0::/services/${SERVICE}`) < 0)
			return { ok: false, error: "core_cgroup_unconfirmed" };
	} else {
		const name = uci_value("routing", "cgroup_name", SERVICE);
		const id = uci_value("routing", "cgroup_id", "0x12061206");
		if (name != SERVICE || !match(id, /^0x[0-9A-Fa-f]+$/)) return { ok: false, error: "invalid_core_cgroup" };
		const path = `/sys/fs/cgroup/net_cls/${name}`;
		if (!shell(`mkdir -p ${shell_quote(path)}`) || fs.writefile(`${path}/net_cls.classid`, id) != length(id) ||
			fs.writefile(`${path}/cgroup.procs`, `${pid}`) != length(`${pid}`))
			return { ok: false, error: "core_cgroup_unavailable" };
	}
	const table = uci_value("routing", "tproxy_route_table", "11900");
	const pref = uci_value("routing", "tproxy_rule_pref", "11900");
	const mark = uci_value("routing", "tproxy_fw_mark", "0x40000000");
	const mask = uci_value("routing", "tproxy_fw_mask", "0x40000000");
	if (!match(table, /^[0-9]+$/) || int(table) < 1 || index([253,254,255], int(table)) >= 0 ||
		!match(pref, /^[0-9]+$/) || !match(mark, /^0x[0-9A-Fa-f]+$/) || !match(mask, /^0x[0-9A-Fa-f]+$/))
		return { ok: false, error: "invalid_routing_identity" };
	const families = [];
	if (enabled("proxy", "ipv4_proxy")) push(families, 4);
	if (enabled("proxy", "ipv6_proxy")) push(families, 6);
	for (let family in families) {
		const rules = capture(`ip -${family} rule show`);
		const routes = capture(`ip -${family} route show table ${table}`);
		if (rules == null || index(rules, `lookup ${table}`) >= 0 ||
			match(rules, regexp(`(^|\n)${pref}:`)) || length(trim(routes ?? "")) > 0)
			return { ok: false, error: "route_owner_conflict" };
	}
	const nft = capture(`utpl -S ${shell_quote(`${VENDOR}/hijack.ut`)}`);
	if (nft == null || fs.writefile(`${STATE}/rules.nft`, nft) != length(nft) ||
		!shell(`nft -c -f ${shell_quote(`${STATE}/rules.nft`)}`)) return { ok: false, error: "invalid_interception_rules" };
	const state = { service: SERVICE, core_pid: pid, table: table, pref: pref, mark: mark, mask: mask, families: families, bridge: {} };
	for (let family in families) {
		const name = family == 4 ? "net.bridge.bridge-nf-call-iptables" : "net.bridge.bridge-nf-call-ip6tables";
		const value = trim(capture(`sysctl -e -n ${name}`) ?? "");
		if (value == "1") state.bridge[name] = value;
	}
	if (!atomic_json(OWNERSHIP, state)) return { ok: false, error: "ownership_write_failed" };
	let applied = true;
	for (let name, value in state.bridge) applied = shell(`sysctl -q -w ${shell_quote(`${name}=0`)}`) && applied;
	for (let family in families) {
		applied = shell(`ip -${family} route add local default dev lo table ${table}`) && applied;
		applied = shell(`ip -${family} rule add pref ${pref} fwmark ${mark}/${mask} table ${table}`) && applied;
	}
	if (applied) applied = shell(`nft -f ${shell_quote(`${STATE}/rules.nft`)}`);
	if (!applied || !status().result.ready) {
		const cleaned = cleanup();
		return { ok: false, error: cleaned.ok ? "interception_start_failed" : "interception_cleanup_failed" };
	}
	return status();
};

function reconcile() {
	if (!process_state().running) return cleanup();
	const result = attach();
	if (result.ok) return result;
	const cleaned = cleanup();
	return { ok: false, error: result.error, cleanup: cleaned };
};

function watch() {
	const loop = require("uloop");
	const ubus = require("ubus");
	if (!loop.init()) return { ok: false, error: "lifecycle_loop_unavailable" };
	const connection = ubus.connect();
	if (connection == null) return { ok: false, error: "lifecycle_bus_unavailable" };
	function synchronize() {
		if (!shell(`/etc/init.d/${SERVICE} reconcile`))
			shell(`logger -t ${SERVICE} lifecycle_reconcile_failed`);
	};
	const pending = loop.timer(-1, synchronize);
	const compatibility = loop.timer(-1, () => {
		compatibility.set(2000);
		if (fs.stat(COMPAT) != null) shell(`timeout 4 /usr/bin/python3 ${COMPAT} tick >/dev/null 2>&1 &`);
	});
	if (compatibility != null) compatibility.set(2000);
	if (pending == null) return { ok: false, error: "lifecycle_timer_unavailable" };
	// procd emits object notifications, not service trigger events.
	const subscriber = connection.subscriber((request) => {
		const ours = request.data?.service == SERVICE && request.data?.instance == "core" &&
			index(["instance.start", "instance.stop", "instance.fail", "instance.respawn"], request.type) >= 0;
		request.reply({});
		// The start notification precedes completion of the child's exec.
		// Leave the notify callback before inspecting its final command and PID.
		if (ours) pending.set(1000);
	}, () => loop.end());
	if (subscriber == null || !subscriber.subscribe("service"))
		return { ok: false, error: "lifecycle_subscription_failed" };
	// A core can already be running when this observer starts or respawns.
	pending.set(1000);
	loop.run();
	return { ok: false, error: "lifecycle_subscription_ended" };
};

function compatibility_snapshot() {
	const uci = cursor();
	let custom = false;
	for (let kind in ["router_access_control", "lan_access_control"]) {
		let defaults = 0;
		uci.foreach("netfleet", kind, (section) => {
			if (`${section.enabled}` != "1") return;
			for (let key in ["ip", "ip6", "mac", "user", "group", "cgroup"])
				if (length(section[key] ?? []) > 0) custom = true;
			if (`${section.proxy}` != "1") custom = true;
			defaults++;
		});
		if (defaults != 1) custom = true;
	}
	const nft = parse(capture("nft -j list set inet netfleet lan_inbound_device"));
	let interfaces = [];
	for (let item in nft?.nftables ?? []) if (item.set?.name == "lan_inbound_device") interfaces = item.set.elem ?? [];
	const result = status();
	return { ok: true, result: { backend: "native-mihomo", ready: result.result?.ready == true,
		router_proxy: enabled("proxy", "router_proxy"), lan_proxy: enabled("proxy", "lan_proxy"),
		ipv4_proxy: enabled("proxy", "ipv4_proxy"), ipv6_proxy: enabled("proxy", "ipv6_proxy"),
		interfaces: interfaces, custom_lan_access: custom, preserve_source_port: true,
		source_bypass: length(uci_value("proxy", "bypass_fwmark", [])) > 0,
		dscp_bypass: map(uci_value("proxy", "bypass_dscp", []), value => int(value)) } };
};

let result;
try {
	if (system("test \"$(id -u)\" = 0") != 0) result = { ok: false, error: "root_required" };
	else if (ARGV[0] == "prepare") result = prepare();
	else if (ARGV[0] == "attach") result = attach();
	else if (ARGV[0] == "cleanup") result = cleanup();
	else if (ARGV[0] == "reconcile") result = reconcile();
	else if (ARGV[0] == "watch") result = watch();
	else if (ARGV[0] == "status") result = status();
	else if (ARGV[0] == "compatibility-snapshot") result = compatibility_snapshot();
	else result = { ok: false, error: "unknown_gateway_action" };
} catch (error) { result = { ok: false, error: "gateway_operation_failed" }; }
printf("%J\n", result);
exit(result.ok ? 0 : 1);
