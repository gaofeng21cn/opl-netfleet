import { popen } from "fs";
import { cursor } from "uci";
import { listeners, rules, dns_ready as native_dns_ready } from "./health.uc";

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let restart, update_subscription, running, listener_port, https_hostname, dns_query_ready, lan_runtime_state, configured_value, valid_table, valid_device, no_lookup_rule, no_route, path_absent, cleanup_state, stop;

const profile_storage = context.use("mihomo.profile-storage");
const KIND = context.use("platform.runtime").KIND;
const UCI_PACKAGE = context.use("platform.runtime").UCI_PACKAGE;
const ROOT_DIR = context.use("platform.runtime").ROOT_DIR;
const RUN_DIR = context.use("platform.runtime").RUN_DIR;
const SERVICE = context.use("platform.runtime").SERVICE;
const NFT_TABLE = context.use("platform.runtime").NFT_TABLE;
const STATE_DIR = context.use("platform.runtime").STATE_DIR;
const shell_quote = context.use("platform.process").shell_quote;

restart = function() {
	return system(`/etc/init.d/${SERVICE} restart >/dev/null 2>&1`) == 0;
};

update_subscription = function(section) {
	if (type(section) != "string" || !match(section, /^[A-Za-z0-9_]+$/)) {
		return false;
	}
	return system(`/etc/init.d/${SERVICE} update_subscription ${shell_quote(section)} >/dev/null 2>&1`) == 0;
};

running = function() {
	if (KIND == "native-mihomo")
		return system(`/etc/init.d/${SERVICE} running >/dev/null 2>&1`) == 0;
	return system("pidof mihomo >/dev/null 2>&1") == 0;
};

listener_port = function(value) {
	const parts = split(`${value ?? ""}`, ":");
	const value_port = parts[length(parts) - 1];
	if (!match(value_port, /^[0-9]+$/)) return null;
	const port = int(value_port);
	return port > 0 && port < 65536 ? port : null;
};

https_hostname = function(url) {
	if (type(url) != "string" || index(url, "https://") != 0) return null;
	const authority = split(substr(url, 8), "/")[0];
	if (substr(authority, 0, 1) == "[") return null;
	const hostname = split(authority, ":")[0];
	if (!match(hostname, /^[A-Za-z0-9.-]+$/) || match(hostname, /^[0-9.]+$/)) return null;
	return hostname;
};

dns_query_ready = function(url) {
	const hostname = https_hostname(url);
	if (hostname == null) return null;
	const command = `nslookup ${shell_quote(hostname)} 127.0.0.1 >/dev/null 2>&1 & probe=$!; ` +
		`(sleep 5; kill "$probe" 2>/dev/null) >/dev/null 2>&1 & watchdog=$!; ` +
		`wait "$probe"; status=$?; kill "$watchdog" 2>/dev/null; ` +
		`wait "$watchdog" 2>/dev/null; exit "$status"`;
	return system(command) == 0;
};

// The selected backend owns transparent-proxy rules and listeners. This adapter only
// reads their effective state so a live Mihomo process cannot be mistaken for
// a working LAN data path.
lan_runtime_state = function(dns_probe_url) {
	let allow_lan = false;
	let api_listen = null;
	let dns_enabled = false;
	let dns_listen = null;
	let native_expected = null;
	try {
		const uci = cursor();
		allow_lan = `${uci.get(UCI_PACKAGE, "mixin", "allow_lan") ?? "0"}` == "1";
		api_listen = uci.get(UCI_PACKAGE, "mixin", "api_listen");
		dns_enabled = `${uci.get(UCI_PACKAGE, "mixin", "dns_enabled") ?? "0"}` == "1";
		dns_listen = uci.get(UCI_PACKAGE, "mixin", "dns_listen");
		if (KIND == "native-mihomo") {
			const dns = `${uci.get(UCI_PACKAGE, "proxy", "ipv4_dns_hijack") ?? "0"}` == "1" ||
				`${uci.get(UCI_PACKAGE, "proxy", "ipv6_dns_hijack") ?? "0"}` == "1";
			native_expected = { lan: `${uci.get(UCI_PACKAGE, "proxy", "lan_proxy") ?? "0"}` == "1",
				router: `${uci.get(UCI_PACKAGE, "proxy", "router_proxy") ?? "0"}` == "1", dns: dns };
		}
	} catch (error) {
		return {
			transparent_proxy_ready: false,
			dns_ready: false,
			dashboard_lan_ready: false,
			allow_lan: false,
			api_listen: null,
			error: "uci_unavailable"
		};
	}
	const sockets = listeners();
	const chains = rules(NFT_TABLE);
	const tproxy_tcp_wildcard = sockets.tcp[7892] == true;
	const tproxy_udp_wildcard = sockets.udp[7892] == true;
	const tproxy_rule_present = length(filter(chains.lan_tproxy ?? [], expr => expr.tproxy?.port == 7892)) > 0;
	const controller_wildcard = sockets.tcp[9090] == true;
	const dns_port = listener_port(dns_listen);
	const dns_tcp_wildcard = dns_port != null && sockets.tcp[dns_port] == true;
	const dns_udp_wildcard = dns_port != null && sockets.udp[dns_port] == true;
	const dns_hijack_rule_present = dns_port != null &&
		length(filter(chains.lan_dns_hijack ?? [], expr => expr.redirect?.port == dns_port)) > 0;
	const dns_query_ok = KIND == "native-mihomo" ?
		(dns_enabled && dns_udp_wildcard && native_dns_ready(dns_port)) : dns_query_ready(dns_probe_url);
	if (native_expected != null) {
		const owner = context.use("mihomo.gateway").status();
		const owner_ready = owner?.ok == true && owner?.result?.ready == true;
		let proxy_chains = true;
		let dns_chains = true;
		for (let scope in ["lan", "router"]) {
			const proxy_present = chains[`${scope}_tproxy`] != null;
			const dns_present = chains[`${scope}_dns_hijack`] != null;
			proxy_chains = proxy_chains && proxy_present == native_expected[scope];
			dns_chains = dns_chains && dns_present == (native_expected[scope] && native_expected.dns);
		}
		// An intentionally disabled interception scope is not a failed data plane.
		return { transparent_proxy_ready: owner_ready && allow_lan && tproxy_tcp_wildcard && tproxy_udp_wildcard && proxy_chains,
			dashboard_lan_ready: api_listen == "0.0.0.0:9090" && controller_wildcard,
			dns_ready: owner_ready && dns_enabled && dns_tcp_wildcard && dns_udp_wildcard && dns_chains && dns_query_ok,
			allow_lan: allow_lan, api_listen: api_listen, dns_enabled: dns_enabled, dns_listen: dns_listen,
			dns_tcp_wildcard: dns_tcp_wildcard, dns_udp_wildcard: dns_udp_wildcard,
			dns_hijack_rule_present: dns_hijack_rule_present, dns_query_ok: dns_query_ok,
			tproxy_tcp_wildcard: tproxy_tcp_wildcard, tproxy_udp_wildcard: tproxy_udp_wildcard,
			tproxy_rule_present: tproxy_rule_present, controller_wildcard: controller_wildcard,
			lan_proxy_enabled: native_expected.lan, router_proxy_enabled: native_expected.router,
			requested_proxy_chains_ready: proxy_chains, requested_dns_chains_ready: dns_chains };
	}
	return {
		transparent_proxy_ready: allow_lan && tproxy_tcp_wildcard &&
			tproxy_udp_wildcard && tproxy_rule_present,
		dashboard_lan_ready: api_listen == "0.0.0.0:9090" && controller_wildcard,
		dns_ready: dns_enabled && dns_tcp_wildcard && dns_udp_wildcard &&
			dns_hijack_rule_present && dns_query_ok != false,
		allow_lan: allow_lan,
		api_listen: api_listen,
		dns_enabled: dns_enabled,
		dns_listen: dns_listen,
		dns_tcp_wildcard: dns_tcp_wildcard,
		dns_udp_wildcard: dns_udp_wildcard,
		dns_hijack_rule_present: dns_hijack_rule_present,
		dns_query_ok: dns_query_ok,
		tproxy_tcp_wildcard: tproxy_tcp_wildcard,
		tproxy_udp_wildcard: tproxy_udp_wildcard,
		tproxy_rule_present: tproxy_rule_present,
		controller_wildcard: controller_wildcard
	};
};

configured_value = function(uci, section, option, fallback) {
	const value = uci.get(UCI_PACKAGE, section, option);
	return type(value) == "string" && length(value) > 0 ? value : fallback;
};

valid_table = function(value) {
	return type(value) == "string" && match(value, /^[0-9]+$/);
};

valid_device = function(value) {
	return type(value) == "string" && match(value, /^[A-Za-z0-9_.-]+$/);
};

no_lookup_rule = function(family, table) {
	return system(`ip -${family} rule show 2>/dev/null | grep -Fq ${shell_quote(`lookup ${table}`)}`) != 0;
};

no_route = function(family, table) {
	return system(`ip -${family} route show table ${shell_quote(table)} 2>/dev/null | grep -q .`) != 0;
};

path_absent = function(path) {
	return system(`test ! -e ${shell_quote(path)}`) == 0;
};

// Observe only the selected owner's cleanup contract; mutation stays in its init service.
cleanup_state = function() {
	if (KIND == "native-mihomo") {
		const response = context.use("mihomo.gateway").status();
		const completed = response?.ok == true;
		// procd can remove the instance before the old process has exited.
		// Match the native owner's start precondition before reusing its listeners.
		const stopped = completed && response?.ok == true && response.result?.core_running == false &&
			system("pidof mihomo >/dev/null 2>&1") != 0;
		return { ok: stopped && response.result?.clean == true,
			mihomo_stopped: stopped, service_stopped: stopped,
			nft_table_absent: response?.result?.clean == true, routing_absent: response?.result?.clean == true };
	}
	let uci = null;
	try {
		uci = cursor();
	} catch (error) {
		return { ok: false, error: "uci_unavailable" };
	}
	const tproxy_table = configured_value(uci, "routing", "tproxy_route_table", "80");
	const tun_table = configured_value(uci, "routing", "tun_route_table", "81");
	const dummy = configured_value(uci, "routing", "dummy_device", `${UCI_PACKAGE}-dummy`);
	const ip_available = system("command -v ip >/dev/null 2>&1") == 0;
	const nft_available = system("command -v nft >/dev/null 2>&1") == 0;
	const mihomo_stopped = !running();
	const service_stopped = system(`/etc/init.d/${SERVICE} running >/dev/null 2>&1`) != 0;
	const nft_table_absent = nft_available &&
		system(`nft list table inet ${NFT_TABLE} >/dev/null 2>&1`) != 0;
	const fw4_rules_absent = nft_available &&
		system(`nft -a list table inet fw4 2>/dev/null | grep -Fq ${shell_quote(`comment "${NFT_TABLE}"`)}`) != 0;
	const routing_absent = ip_available && valid_table(tproxy_table) && valid_table(tun_table) &&
		no_lookup_rule(4, tproxy_table) && no_lookup_rule(4, tun_table) &&
		no_lookup_rule(6, tproxy_table) && no_lookup_rule(6, tun_table) &&
		no_route(4, tproxy_table) && no_route(4, tun_table) &&
		no_route(6, tproxy_table) && no_route(6, tun_table);
	const dummy_absent = ip_available && valid_device(dummy) &&
		system(`ip link show dev ${shell_quote(dummy)} >/dev/null 2>&1`) != 0;
	// These markers are part of the backend's stop contract. A leftover cron
	// entry or started flag can bring the proxy back after a seemingly clean
	// passthrough, so cleanup is not durable until they are gone as well.
	const started_flag_absent = path_absent(`${STATE_DIR}/started.flag`);
	const bridge_flags_absent = path_absent(`${STATE_DIR}/bridge_nf_call_iptables.flag`) &&
		path_absent(`${STATE_DIR}/bridge_nf_call_ip6tables.flag`);
	const cron_clean = system(`[ ! -f /etc/crontabs/root ] || ! grep -q '#${UCI_PACKAGE}' /etc/crontabs/root`) == 0;
	return {
		ok: mihomo_stopped && service_stopped && nft_table_absent && fw4_rules_absent &&
			routing_absent && dummy_absent && started_flag_absent && bridge_flags_absent && cron_clean,
		mihomo_stopped: mihomo_stopped,
		service_stopped: service_stopped,
		nft_table_absent: nft_table_absent,
		fw4_rules_absent: fw4_rules_absent,
		routing_absent: routing_absent,
		dummy_absent: dummy_absent,
		started_flag_absent: started_flag_absent,
		bridge_flags_absent: bridge_flags_absent,
		cron_clean: cron_clean,
		tproxy_route_table: tproxy_table,
		tun_route_table: tun_table,
		dummy_device: dummy
	};
};

// The selected backend owns cleanup of Mihomo, transparent proxy rules, DNS and policy
// routing.  NetFleet may use this only as an emergency recovery action; it
// never assembles a parallel cleanup command of its own.
stop = function() {
	let before = cleanup_state();
	if (before.ok) {
		return { ok: true, requested: false, readback: before };
	}
	const requested = system(`/etc/init.d/${SERVICE} stop >/dev/null 2>&1`) == 0;
	let readback = before;
	// procd may report stop before the child and its cleanup hook have settled.
	// Wait only for the official owner to reach a fully clean state; never issue
	// a parallel nft, route, or process-kill command here.
	for (let attempt = 0; attempt < 9; attempt++) {
		readback = cleanup_state();
		if (readback.ok) {
			return { ok: true, requested: requested, readback: readback };
		}
		if (attempt < 8) {
			system("sleep 1");
		}
	}
	return { ok: false, requested: requested, readback: readback };
};

return { ...profile_storage, restart, update_subscription, running, lan_runtime_state, cleanup_state, stop };
};
