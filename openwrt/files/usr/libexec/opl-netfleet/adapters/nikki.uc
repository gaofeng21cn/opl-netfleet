import { popen } from "fs";
import { cursor } from "uci";
import { shell_quote, mkdir, write_text, sha256 } from "./uci.uc";

export const ARTIFACT_DIR = "/etc/nikki/profiles/opl-netfleet";
export const ARTIFACT_PATH = `${ARTIFACT_DIR}/mvp.json`;
export const MANIFEST_PATH = `${ARTIFACT_DIR}/mvp.manifest.json`;
export const PROFILE_ENTRY_PATH = "/etc/nikki/profiles/OPL-NetFleet.json";
export const PROFILE_ENTRY_TARGET = "opl-netfleet/mvp.json";
export const COMPILED_PROFILE = "file:OPL-NetFleet.json";
export const PROXY_PROVIDER_DIR = "/etc/nikki/run/providers/proxy";

export function resolve_profile(reference) {
	const parts = split(reference ?? "", ":");
	if (length(parts) != 2 || (parts[0] != "subscription" && parts[0] != "file") || length(parts[1]) == 0) {
		return null;
	}
	// Profile references are persisted in UCI and later passed to a shell
	// command.  Keep the reference relative to Nikki's known directories and
	// reject traversal instead of treating an arbitrary path as a rollback.
	if (index(parts[1], "..") >= 0 || index(parts[1], "\\") >= 0 ||
		index(parts[1], "\n") >= 0 || index(parts[1], "\r") >= 0 ||
		substr(parts[1], 0, 1) == "/") {
		return null;
	}
	if (parts[0] == "subscription") {
		if (!match(parts[1], /^[A-Za-z0-9_]+$/)) {
			return null;
		}
		return `/etc/nikki/subscriptions/${parts[1]}.yaml`;
	}
	return `/etc/nikki/profiles/${parts[1]}`;
};

export function profile_exists(reference) {
	const path = resolve_profile(reference);
	return path != null && system(`test -f ${shell_quote(path)}`) == 0;
};

export function restart() {
	return system("/etc/init.d/nikki restart >/dev/null 2>&1") == 0;
};

export function update_subscription(section) {
	if (type(section) != "string" || !match(section, /^[A-Za-z0-9_]+$/)) {
		return false;
	}
	return system(`/etc/init.d/nikki update_subscription ${shell_quote(section)} >/dev/null 2>&1`) == 0;
};

export function provider_runtime_path(provider_name) {
	return `${PROXY_PROVIDER_DIR}/netfleet-${provider_name}.yaml`;
};

function link_target(path) {
	const process = popen(`readlink ${shell_quote(path)}`);
	if (!process) {
		return null;
	}
	const target = process.read("line");
	process.close();
	return target ? trim(target) : null;
};

function subscription_cache_path(path) {
	return type(path) == "string" &&
		match(path, /^\/etc\/nikki\/subscriptions\/[A-Za-z0-9_]+\.yaml$/);
};

export function prepare_provider_links(provider_profiles) {
	if (!mkdir(PROXY_PROVIDER_DIR)) {
		return false;
	}
	const names = keys(provider_profiles ?? {});
	for (let i = 0; i < length(names); i++) {
		const name = names[i];
		const source = provider_profiles[name]?.path;
		const target = provider_runtime_path(name);
		if (!source || !target) {
			return false;
		}
		if (system(`test -L ${shell_quote(target)}`) == 0) {
			const existing = link_target(target);
			if (existing == source) {
				continue;
			}
			if (!subscription_cache_path(existing) || !subscription_cache_path(source) ||
				system(`ln -sfn ${shell_quote(source)} ${shell_quote(target)}`) != 0 ||
				link_target(target) != source) {
				return false;
			}
			continue;
		}
		if (system(`test -e ${shell_quote(target)}`) == 0 ||
			system(`ln -s ${shell_quote(source)} ${shell_quote(target)}`) != 0) {
			return false;
		}
	}
	return true;
};

export function remove_provider_links(provider_profiles) {
	const names = keys(provider_profiles ?? {});
	let removed = true;
	for (let i = 0; i < length(names); i++) {
		const name = names[i];
		const source = provider_profiles[name]?.path;
		const target = provider_runtime_path(name);
		if (!source) continue;
		const is_link = system(`test -L ${shell_quote(target)}`) == 0;
		if (!is_link && system(`test -e ${shell_quote(target)}`) != 0) continue;
		if (!is_link || link_target(target) != source ||
			system(`rm -f ${shell_quote(target)}`) != 0) removed = false;
	}
	return removed;
};

export function running() {
	return system("pidof mihomo >/dev/null 2>&1") == 0;
};

function wildcard_listener(protocol, port) {
	const flag = protocol == "udp" ? "-lnu" : "-lnt";
	return system(`netstat ${flag} 2>/dev/null | awk '$4 == "0.0.0.0:${port}" || $4 == ":::${port}" || $4 == "[::]:${port}" { found=1 } END { exit !found }'`) == 0;
};

function listener_port(value) {
	const parts = split(`${value ?? ""}`, ":");
	const value_port = parts[length(parts) - 1];
	if (!match(value_port, /^[0-9]+$/)) return null;
	const port = int(value_port);
	return port > 0 && port < 65536 ? port : null;
};

function https_hostname(url) {
	if (type(url) != "string" || index(url, "https://") != 0) return null;
	const authority = split(substr(url, 8), "/")[0];
	if (substr(authority, 0, 1) == "[") return null;
	const hostname = split(authority, ":")[0];
	if (!match(hostname, /^[A-Za-z0-9.-]+$/) || match(hostname, /^[0-9.]+$/)) return null;
	return hostname;
};

function dns_query_ready(url) {
	const hostname = https_hostname(url);
	if (hostname == null) return null;
	const command = `nslookup ${shell_quote(hostname)} 127.0.0.1 >/dev/null 2>&1 & probe=$!; ` +
		`(sleep 5; kill "$probe" 2>/dev/null) >/dev/null 2>&1 & watchdog=$!; ` +
		`wait "$probe"; status=$?; kill "$watchdog" 2>/dev/null; ` +
		`wait "$watchdog" 2>/dev/null; exit "$status"`;
	return system(command) == 0;
};

// Nikki owns the transparent-proxy rules and listeners.  This adapter only
// reads their effective state so a live Mihomo process cannot be mistaken for
// a working LAN data path.
export function lan_runtime_state(dns_probe_url) {
	let allow_lan = false;
	let api_listen = null;
	let dns_enabled = false;
	let dns_listen = null;
	try {
		const uci = cursor();
		allow_lan = `${uci.get("nikki", "mixin", "allow_lan") ?? "0"}` == "1";
		api_listen = uci.get("nikki", "mixin", "api_listen");
		dns_enabled = `${uci.get("nikki", "mixin", "dns_enabled") ?? "0"}` == "1";
		dns_listen = uci.get("nikki", "mixin", "dns_listen");
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
	const tproxy_tcp_wildcard = wildcard_listener("tcp", 7892);
	const tproxy_udp_wildcard = wildcard_listener("udp", 7892);
	const tproxy_rule_present = system("nft list chain inet nikki lan_tproxy 2>/dev/null | grep -Fq 'tproxy to :7892'") == 0;
	const controller_wildcard = wildcard_listener("tcp", 9090);
	const dns_port = listener_port(dns_listen);
	const dns_tcp_wildcard = dns_port != null && wildcard_listener("tcp", dns_port);
	const dns_udp_wildcard = dns_port != null && wildcard_listener("udp", dns_port);
	const dns_hijack_rule_present = dns_port != null &&
		system(`nft list chain inet nikki lan_dns_hijack 2>/dev/null | grep -Fq ${shell_quote(`redirect to :${dns_port}`)}`) == 0;
	const dns_query_ok = dns_query_ready(dns_probe_url);
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

function configured_value(uci, section, option, fallback) {
	const value = uci.get("nikki", section, option);
	return type(value) == "string" && length(value) > 0 ? value : fallback;
};

function valid_table(value) {
	return type(value) == "string" && match(value, /^[0-9]+$/);
};

function valid_device(value) {
	return type(value) == "string" && match(value, /^[A-Za-z0-9_.-]+$/);
};

function no_lookup_rule(family, table) {
	return system(`ip -${family} rule show 2>/dev/null | grep -Fq ${shell_quote(`lookup ${table}`)}`) != 0;
};

function no_route(family, table) {
	return system(`ip -${family} route show table ${shell_quote(table)} 2>/dev/null | grep -q .`) != 0;
};

function path_absent(path) {
	return system(`test ! -e ${shell_quote(path)}`) == 0;
};

// This is a read-only observation of Nikki's cleanup contract.  The commands
// that remove these objects remain exclusively in /etc/init.d/nikki.
export function cleanup_state() {
	let uci = null;
	try {
		uci = cursor();
	} catch (error) {
		return { ok: false, error: "uci_unavailable" };
	}
	const tproxy_table = configured_value(uci, "routing", "tproxy_route_table", "80");
	const tun_table = configured_value(uci, "routing", "tun_route_table", "81");
	const dummy = configured_value(uci, "routing", "dummy_device", "nikki-dummy");
	const ip_available = system("command -v ip >/dev/null 2>&1") == 0;
	const nft_available = system("command -v nft >/dev/null 2>&1") == 0;
	const mihomo_stopped = !running();
	const service_stopped = system("/etc/init.d/nikki running >/dev/null 2>&1") != 0;
	const nft_table_absent = nft_available &&
		system("nft list table inet nikki >/dev/null 2>&1") != 0;
	const fw4_rules_absent = nft_available &&
		system(`nft -a list table inet fw4 2>/dev/null | grep -Fq ${shell_quote('comment "nikki"')}`) != 0;
	const routing_absent = ip_available && valid_table(tproxy_table) && valid_table(tun_table) &&
		no_lookup_rule(4, tproxy_table) && no_lookup_rule(4, tun_table) &&
		no_lookup_rule(6, tproxy_table) && no_lookup_rule(6, tun_table) &&
		no_route(4, tproxy_table) && no_route(4, tun_table) &&
		no_route(6, tproxy_table) && no_route(6, tun_table);
	const dummy_absent = ip_available && valid_device(dummy) &&
		system(`ip link show dev ${shell_quote(dummy)} >/dev/null 2>&1`) != 0;
	// These markers are part of Nikki's own stop contract.  A leftover cron
	// entry or started flag can bring the proxy back after a seemingly clean
	// passthrough, so cleanup is not durable until they are gone as well.
	const started_flag_absent = path_absent("/var/run/nikki/started.flag");
	const bridge_flags_absent = path_absent("/var/run/nikki/bridge_nf_call_iptables.flag") &&
		path_absent("/var/run/nikki/bridge_nf_call_ip6tables.flag");
	const cron_clean = system("[ ! -f /etc/crontabs/root ] || ! grep -q '#nikki' /etc/crontabs/root") == 0;
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

// Nikki owns cleanup of Mihomo, transparent proxy rules, DNS and policy
// routing.  NetFleet may use this only as an emergency recovery action; it
// never assembles a parallel cleanup command of its own.
export function stop() {
	let before = cleanup_state();
	if (before.ok) {
		return { ok: true, requested: false, readback: before };
	}
	const requested = system("/etc/init.d/nikki stop >/dev/null 2>&1") == 0;
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

function make_json(profile) {
	return sprintf("%J", profile);
};

export function test_profile_object(profile) {
	const text = make_json(profile);
	if (text == null || !write_text("/tmp/opl-netfleet-mvp-test.json", text)) {
		return false;
	}
	const result = system(`mihomo -d ${shell_quote("/etc/nikki/run")} -f ${shell_quote("/tmp/opl-netfleet-mvp-test.json")} -t >/dev/null 2>&1`) == 0;
	system("rm -f /tmp/opl-netfleet-mvp-test.json");
	return result;
};

export function install_artifact(profile, manifest) {
	const profile_text_value = make_json(profile);
	if (profile_text_value == null || type(manifest) != "object" || !mkdir(ARTIFACT_DIR)) {
		return false;
	}
	if (system(`test -L ${shell_quote(PROFILE_ENTRY_PATH)}`) == 0) {
		if (link_target(PROFILE_ENTRY_PATH) != PROFILE_ENTRY_TARGET) {
			return false;
		}
	} else if (system(`test -e ${shell_quote(PROFILE_ENTRY_PATH)}`) == 0) {
		return false;
	}
	const profile_tmp = `${ARTIFACT_DIR}/.mvp.json.tmp`;
	const manifest_tmp = `${ARTIFACT_DIR}/.mvp.manifest.json.tmp`;
	if (!write_text(profile_tmp, profile_text_value)) {
		system(`rm -f ${shell_quote(profile_tmp)} ${shell_quote(manifest_tmp)}`);
		return false;
	}
	const artifact_digest = sha256(profile_tmp);
	if (artifact_digest == null) {
		system(`rm -f ${shell_quote(profile_tmp)} ${shell_quote(manifest_tmp)}`);
		return false;
	}
	manifest.artifact_sha256 = artifact_digest;
	if (!write_text(manifest_tmp, sprintf("%J", manifest)) ||
		system(`mihomo -d ${shell_quote("/etc/nikki/run")} -f ${shell_quote(profile_tmp)} -t >/dev/null 2>&1`) != 0) {
		system(`rm -f ${shell_quote(profile_tmp)} ${shell_quote(manifest_tmp)}`);
		return false;
	}
	if (system(`mv -f ${shell_quote(profile_tmp)} ${shell_quote(ARTIFACT_PATH)}`) != 0 ||
		system(`mv -f ${shell_quote(manifest_tmp)} ${shell_quote(MANIFEST_PATH)}`) != 0) {
		system(`rm -f ${shell_quote(profile_tmp)} ${shell_quote(manifest_tmp)}`);
		return false;
	}
	if (system(`test -L ${shell_quote(PROFILE_ENTRY_PATH)}`) != 0 &&
		system(`ln -s ${shell_quote(PROFILE_ENTRY_TARGET)} ${shell_quote(PROFILE_ENTRY_PATH)}`) != 0) {
		return false;
	}
	return link_target(PROFILE_ENTRY_PATH) == PROFILE_ENTRY_TARGET &&
		sha256(ARTIFACT_PATH) == artifact_digest &&
		sha256(PROFILE_ENTRY_PATH) == artifact_digest &&
		system(`mihomo -d ${shell_quote("/etc/nikki/run")} -f ${shell_quote(PROFILE_ENTRY_PATH)} -t >/dev/null 2>&1`) == 0;
};

export function remove_artifact() {
	if (system(`test -L ${shell_quote(PROFILE_ENTRY_PATH)}`) == 0) {
		if (link_target(PROFILE_ENTRY_PATH) != PROFILE_ENTRY_TARGET ||
			system(`rm -f ${shell_quote(PROFILE_ENTRY_PATH)}`) != 0) return false;
	} else if (system(`test -e ${shell_quote(PROFILE_ENTRY_PATH)}`) == 0) {
		return false;
	}
	return system(`rm -f ${shell_quote(ARTIFACT_PATH)} ${shell_quote(MANIFEST_PATH)}`) == 0;
};
