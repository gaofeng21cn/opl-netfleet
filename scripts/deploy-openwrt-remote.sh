#!/bin/sh
set -eu
umask 077

bundle=""
preserve_state=0
allow_disable=0
presentation_only=0
instance=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--bundle) [ "$#" -ge 2 ] || exit 2; bundle=$2; shift 2 ;;
		--preserve-state) preserve_state=1; allow_disable=1; shift ;;
		--presentation-only) preserve_state=1; allow_disable=1; presentation_only=1; shift ;;
		--leave-disabled) preserve_state=0; allow_disable=1; shift ;;
		--stage-only) preserve_state=0; allow_disable=0; shift ;;
		--instance) instance=1; shift ;;
		*) exit 2 ;;
	esac
done

root_prefix=${OPL_NETFLEET_DEPLOY_ROOT:-}
if [ -n "$root_prefix" ]; then
	[ "${OPL_NETFLEET_DEPLOY_TESTING:-}" = "1" ] || exit 2
	case "$root_prefix" in /*) ;; *) exit 2 ;; esac
	[ "$root_prefix" != "/" ] || exit 2
	root_prefix=${root_prefix%/}
fi

root_path() {
	if [ -n "$root_prefix" ]; then printf '%s/%s' "$root_prefix" "${1#/}"; else printf '/%s' "${1#/}"; fi
}
sha_of() { sha256sum "$1" | awk '{print $1}'; }
jf() { jsonfilter -i "$1" -e "$2" 2>/dev/null || true; }
uci_get() { uci -q get "$1" 2>/dev/null || true; }
current_profile() { uci_get nikki.config.profile; }
is_netfleet_profile() { [ "$1" = "file:OPL-NetFleet.json" ] || [ "$1" = "file:opl-netfleet/mvp.json" ]; }
fail() { error_code=$1; [ "$#" -lt 2 ] || error_detail=$2; return 1; }
fail_exit() { error_code=$1; [ "$#" -lt 2 ] || error_detail=$2; exit 1; }

missing_commands() {
	missing=""
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || missing="${missing}${missing:+,}${cmd}"
	done
	printf '%s' "$missing"
}

error_code=unexpected_error
error_detail=""
payload_mutated=0
control_plane_repair=0
service_mutated=0
service_restore_mode=none
service_before_enabled=0
service_before_running=0
rollback_state=not_needed
source_commit=""
source_tree=""
was_active=false
rollback_dir=$(root_path /etc/opl-netfleet/deploy-rollback)
external_state_paths="etc/config/rpcd etc/config/uhttpd"
subscriptions_match=true
default_placeholder_present=false
platform_matches=true
platform_changed=false
rulesets_match=false
rulesets_changed=false

owned_paths='usr/libexec/opl-netfleet
usr/libexec/opl-netfleet-plugin-package
usr/libexec/opl-netfleet-transfer
usr/libexec/rpcd/opl-netfleet
usr/libexec/rpcd/opl-netfleet.plugins
etc/init.d/opl-netfleet
etc/init.d/opl-netfleet-core
etc/opl-netfleet/policy.example.json
etc/opl-netfleet/policy-sources
etc/opl-netfleet/rulesets.lock.json
etc/opl-netfleet/installed.json
www/luci-static/resources/netfleet
www/luci-static/resources/view/netfleet
usr/share/luci/menu.d/luci-app-netfleet.json
usr/share/opl-netfleet
usr/share/rpcd/acl.d/luci-app-netfleet.json'

state_paths='etc/opl-netfleet/policy.json
etc/nikki/profiles/OPL-NetFleet.json
etc/nikki/profiles/opl-netfleet/mvp.json
etc/nikki/profiles/opl-netfleet/mvp.manifest.json
etc/nikki/run/rulesets
etc/opl-netfleet/rulesets
etc/apk/world
lib/apk/db/installed
etc/opkg/status
usr/lib/opkg/status
etc/apk/keys/opl-netfleet-apk.pem
etc/opl-netfleet/policy.example.json.apk-new
etc/opl-netfleet/rulesets.lock.json.apk-new'

# Snapshot only state files, never /var or /var/lib themselves (preserves /var -> tmp).
runtime_state_paths='etc/opl-netfleet/evidence.json
var/lib/opl-netfleet/evidence.json
var/lib/opl-netfleet/events.json'

platform_uci_map='config scheduled_restart scheduled_restart bool
config test_profile test_profile bool
procd fast_reload fast_reload bool
mixin api_listen api_listen string
mixin allow_lan allow_lan bool
mixin selection_cache selection_cache bool
mixin log_level log_level string
log clear_at_stop log_clear_at_stop bool
mixin ipv6 ipv6 bool
mixin unify_delay unified_delay bool
mixin tcp_concurrent tcp_concurrent bool
mixin tun_enabled tun_enabled bool
mixin dns_enabled dns_enabled bool
mixin dns_cache_algorithm dns_cache_algorithm string
mixin dns_ipv6 dns_ipv6 bool
mixin dns_mode dns_mode string
mixin fake_ip_cache fake_ip_cache bool
mixin sniffer sniffer_enabled bool
mixin sniffer_sniff_dns_mapping sniffer_force_dns_mapping bool
mixin sniffer_sniff_pure_ip sniffer_parse_pure_ip bool
proxy tcp_mode tcp_mode string
proxy udp_mode udp_mode string
proxy ipv4_dns_hijack ipv4_dns_hijack bool
proxy ipv6_dns_hijack ipv6_dns_hijack bool
proxy ipv4_proxy ipv4_proxy bool
proxy ipv6_proxy ipv6_proxy bool
proxy fake_ip_ping_hijack fake_ip_ping_hijack bool
proxy bypass_china_mainland_ip bypass_china_mainland_ip bool
proxy bypass_china_mainland_ip6 bypass_china_mainland_ip6 bool'

emit_failure() {
	profile=$(current_profile)
	recovery=not_needed
	case "$rollback_state" in
		active_profile_not_recoverable|original_*_not_recoverable|restore_failed) recovery=needs_local_recovery ;;
	esac
	case "$profile" in *[!A-Za-z0-9:._/-]*) profile=unavailable ;; esac
	case "$error_detail" in *[!A-Za-z0-9_,.:-]*) error_detail=unavailable ;; esac
	printf '{"ok":false,"action":"deploy","error":"%s","detail":"%s","source_commit":"%s","source_tree":"%s","previous_active":%s,"profile":"%s","rollback":"%s","recovery":"%s"}\n' \
		"$error_code" "$error_detail" "$source_commit" "$source_tree" "$was_active" "$profile" "$rollback_state" "$recovery"
}

configure_nikki_apk_feed() {
	. /etc/openwrt_release
	case "${DISTRIB_RELEASE:-}" in
		*24.10*) nikki_branch=openwrt-24.10 ;;
		*25.12*) nikki_branch=openwrt-25.12 ;;
		SNAPSHOT) nikki_branch=SNAPSHOT ;;
		*) return 1 ;;
	esac
	[ -n "${DISTRIB_ARCH:-}" ] || return 1
	nikki_repo=https://nikkinikki.pages.dev
	nikki_feed="$nikki_repo/$nikki_branch/$DISTRIB_ARCH/nikki/packages.adb"
	nikki_key=/etc/apk/keys/nikki.pem
	nikki_key_tmp="$nikki_key.opl-netfleet.$$"
	nikki_key_sha=677ef1af372065e2e856175363e2da9471a6c5c6443563b912c8d325bfa1fbad
	if [ ! -f "$nikki_key" ] || [ "$(sha_of "$nikki_key")" != "$nikki_key_sha" ]; then
		if ! curl -fsSL --connect-timeout 10 --max-time 30 -o "$nikki_key_tmp" "$nikki_repo/public-key.pem" ||
			[ "$(sha_of "$nikki_key_tmp")" != "$nikki_key_sha" ]; then
			rm -f "$nikki_key_tmp"; return 1
		fi
		mv -f "$nikki_key_tmp" "$nikki_key"
	fi
	feed_file=/etc/apk/repositories.d/customfeeds.list
	mkdir -p "$(dirname "$feed_file")" && touch "$feed_file"
	if ! grep -Fqx "$nikki_feed" "$feed_file"; then
		feed_tmp="$feed_file.opl-netfleet.$$"
		awk '!/^https:\/\/nikkinikki\.pages\.dev\/.*\/nikki\/packages\.adb$/' "$feed_file" >"$feed_tmp"
		printf '%s\n' "$nikki_feed" >>"$feed_tmp"
		mv -f "$feed_tmp" "$feed_file"
	fi
}

bootstrap_instance_dependencies() {
	missing=$(missing_commands curl flock jsonfilter mihomo ucode yq)
	nikki_init=$(root_path /etc/init.d/nikki)
	[ -z "$missing" ] && [ -x "$nikki_init" ] && return 0
	dep_detail=$missing
	[ -x "$nikki_init" ] || dep_detail="${dep_detail}${dep_detail:+,}nikki_service"
	[ "$instance" = "1" ] || { fail target_dependencies_missing "$dep_detail"; return 1; }
	[ -z "$root_prefix" ] || { fail unsupported_target "$dep_detail"; return 1; }
	if command -v apk >/dev/null 2>&1; then
		apk --timeout 300 update >/dev/null 2>&1 || { fail dependency_bootstrap_failed "$missing"; return 1; }
		apk --timeout 300 add ucode yq curl jsonfilter >/dev/null 2>&1 || true
		core_missing=$(missing_commands curl flock jsonfilter ucode yq)
		[ -z "$core_missing" ] || { fail dependency_bootstrap_failed "$core_missing"; return 1; }
		if [ ! -x "$nikki_init" ] || ! command -v mihomo >/dev/null 2>&1; then
			configure_nikki_apk_feed || { fail dependency_bootstrap_failed nikki_feed; return 1; }
			apk --timeout 300 update >/dev/null 2>&1 || { fail dependency_bootstrap_failed nikki_packages; return 1; }
			apk --timeout 300 add nikki luci-app-nikki mihomo-meta >/dev/null 2>&1 || true
			[ -x "$nikki_init" ] && command -v mihomo >/dev/null 2>&1 || { fail dependency_bootstrap_failed nikki_packages; return 1; }
		fi
	elif command -v opkg >/dev/null 2>&1; then
		opkg update >/dev/null 2>&1 &&
			opkg install nikki luci-app-nikki mihomo ucode yq curl jsonfilter flock >/dev/null 2>&1 ||
			{ fail dependency_bootstrap_failed "$missing"; return 1; }
	else
		fail unsupported_target "package_manager,$missing"; return 1
	fi
	missing=$(missing_commands curl flock jsonfilter mihomo ucode yq)
	[ -z "$missing" ] && [ -x "$nikki_init" ] || { fail dependency_bootstrap_incomplete "${missing:-nikki_service}"; return 1; }
}

supervisor_init() { root_path /etc/init.d/opl-netfleet; }
supervisor_enabled() { init=$(supervisor_init); [ -x "$init" ] && "$init" enabled >/dev/null 2>&1; }
supervisor_running() { init=$(supervisor_init); [ -x "$init" ] && "$init" status >/dev/null 2>&1; }

stop_supervisor() {
	init=$(supervisor_init)
	if [ -x "$init" ]; then
		service_mutated=1
		service_restore_mode=rollback
		"$init" stop >/dev/null 2>&1 || true
	fi
}

restore_supervisor_flags() {
	init=$(supervisor_init)
	[ -x "$init" ] || return 0
	if [ "$1" = "1" ]; then "$init" enable >/dev/null 2>&1 || return 1; else "$init" disable >/dev/null 2>&1 || return 1; fi
	if [ "$2" = "1" ]; then "$init" restart >/dev/null 2>&1 || return 1; else "$init" stop >/dev/null 2>&1 || return 1; fi
}

ensure_supervisor() {
	init=$(supervisor_init)
	[ -x "$init" ] || return 1
	eb=0; rb=0
	supervisor_enabled && eb=1
	supervisor_running && rb=1
	if ! "$init" enable >/dev/null 2>&1 ||
		{ ! "$init" status >/dev/null 2>&1 && ! "$init" start >/dev/null 2>&1; } ||
		! "$init" enabled >/dev/null 2>&1 || ! "$init" status >/dev/null 2>&1; then
		restore_supervisor_flags "$eb" "$rb" || true
		return 1
	fi
}

restore_supervisor_state() {
	te=0; tr=0
	[ -f "$rollback_dir/supervisor-enabled" ] && te=1
	[ -f "$rollback_dir/supervisor-running" ] && tr=1
	restore_supervisor_flags "$te" "$tr"
}

restore_paths_from_snapshot() {
	restore_stage="$rollback_dir/restore.$$"
	rm -rf -- "$restore_stage" && mkdir -p "$restore_stage" || return 1
	if ! tar -C "$restore_stage" -xf "$rollback_dir/snapshot.tar"; then
		rm -rf -- "$restore_stage"; return 1
	fi
	for rel in $1; do
		target=$(root_path "/$rel")
		rm -rf -- "$target" || { rm -rf -- "$restore_stage"; return 1; }
		if [ -f "$rollback_dir/absent" ] && grep -Fqx "$rel" "$rollback_dir/absent"; then
			continue
		fi
		src="$restore_stage/$rel"
		if { [ ! -e "$src" ] && [ ! -L "$src" ]; } || ! mkdir -p "$(dirname "$target")" || ! cp -a "$src" "$target"; then
			rm -rf -- "$restore_stage"; return 1
		fi
	done
	rm -rf -- "$restore_stage"
}

restore_snapshot_bytes() {
	[ -f "$rollback_dir/snapshot.tar" ] || return 1
	init=$(supervisor_init)
	[ ! -x "$init" ] || { "$init" stop >/dev/null 2>&1 || true; "$init" disable >/dev/null 2>&1 || true; }
	for rel in $owned_paths $state_paths $external_state_paths $runtime_state_paths; do
		rm -rf -- "$(root_path "/$rel")"
	done
	restore_paths_from_snapshot "$owned_paths $state_paths $external_state_paths $runtime_state_paths" || return 1
	for svc_act in "rpcd reload" "uhttpd restart" "firewall reload"; do
		svc=${svc_act% *}; act=${svc_act#* }
		sinit=$(root_path "/etc/init.d/$svc")
		[ ! -x "$sinit" ] || "$sinit" "$act" >/dev/null 2>&1 || true
	done
}

restore_control_plane_snapshot() {
	[ -f "$rollback_dir/snapshot.tar" ] || return 1
	init=$(supervisor_init)
	[ ! -x "$init" ] || { "$init" stop >/dev/null 2>&1 || true; "$init" disable >/dev/null 2>&1 || true; }
	restore_paths_from_snapshot "$owned_paths" || return 1
	for svc_act in "rpcd reload" "uhttpd restart"; do
		svc=${svc_act% *}; act=${svc_act#* }
		sinit=$(root_path "/etc/init.d/$svc")
		[ ! -x "$sinit" ] || "$sinit" "$act" >/dev/null 2>&1 || true
	done
	restore_supervisor_state
}

rpcd_surface_ready() {
	ubus -v list luci 2>/dev/null | grep -q '"getFeatures":' || return 1
	methods=$(ubus -v list opl-netfleet 2>/dev/null || true)
	for m in status events connections probe config_get config_validate config_save config_apply enable select_auto refresh disable; do
		printf '%s\n' "$methods" | grep -q "\"$m\":" || return 1
	done
	if [ -f "$(root_path /usr/libexec/rpcd/opl-netfleet.plugins)" ]; then
		[ -x "$(root_path /usr/libexec/rpcd/opl-netfleet.plugins)" ] || return 1
		pmethods=$(ubus -v list opl-netfleet.plugins 2>/dev/null || true)
		for m in plugins_list plugin_read plugin_call; do
			printf '%s\n' "$pmethods" | grep -q "\"$m\":" || return 1
		done
	fi
}

timeout_ge_300() {
	val=$(uci_get "$1")
	case "$val" in ''|*[!0-9]*) return 1 ;; esac
	[ "$val" -ge 300 ]
}
rpcd_timeout_ready() { timeout_ge_300 rpcd.@rpcd[0].timeout; }
uhttpd_timeout_ready() { timeout_ge_300 uhttpd.main.script_timeout; }

uhttpd_runtime_timeout_ready() {
	[ -n "$root_prefix" ] && return 0
	ps w 2>/dev/null | awk '$0 ~ /[u]httpd/ { for (i=1; i<NF; i++) if ($i=="-t" && $(i+1) ~ /^[0-9]+$/ && $(i+1)>=300) ok=1 } END { exit(ok ? 0 : 1) }'
}

ensure_rpc_timeouts() {
	changed=false; uhttpd_timeout_changed=false
	if ! rpcd_timeout_ready; then
		uci set rpcd.@rpcd[0].timeout=300 >/dev/null 2>&1 && uci commit rpcd >/dev/null 2>&1 || return 1
		changed=true
	fi
	if ! uhttpd_timeout_ready; then
		uci set uhttpd.main.script_timeout=300 >/dev/null 2>&1 && uci commit uhttpd >/dev/null 2>&1 || return 1
		uhttpd_timeout_changed=true; changed=true
	fi
	[ "$changed" = true ] && return 2
	return 0
}

luci_http_surface_ready() {
	session_json=$(ubus call session create '{"timeout":30}' 2>/dev/null) || return 1
	sid=$(jsonfilter -s "$session_json" -e '@.ubus_rpc_session' 2>/dev/null || true)
	[ "${#sid}" -eq 32 ] || return 1
	case "$sid" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
	sp="{\"ubus_rpc_session\":\"$sid\"}"
	gp="{\"ubus_rpc_session\":\"$sid\",\"scope\":\"ubus\",\"objects\":[[\"luci\",\"getFeatures\"]]}"
	if ! ubus call session grant "$gp" >/dev/null 2>&1; then
		ubus call session destroy "$sp" >/dev/null 2>&1 || true; return 1
	fi
	req="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$sid\",\"luci\",\"getFeatures\",{}]}"
	resp=$(curl -fsS --connect-timeout 2 --max-time 5 -H 'Content-Type: application/json' -d "$req" http://127.0.0.1/ubus 2>/dev/null || true)
	ubus call session destroy "$sp" >/dev/null 2>&1 || true
	[ "$(jsonfilter -s "$resp" -e '@.result[0]' 2>/dev/null || true)" = "0" ]
}

restart_uhttpd_for_rpc() {
	uinit=$(root_path /etc/init.d/uhttpd)
	[ -x "$uinit" ] && "$uinit" restart >/dev/null 2>&1 || return 1
	for attempt in 1 2 3 4; do
		luci_http_surface_ready && return 0
		[ "$attempt" -eq 4 ] || sleep 1
	done
	return 1
}

ensure_rpcd_surface() {
	restart_required=${1:-false}
	if ensure_rpc_timeouts; then
		:
	else
		rc=$?; [ "$rc" -eq 2 ] || return 1; restart_required=true
	fi
	if ! uhttpd_runtime_timeout_ready; then
		restart_required=true; uhttpd_timeout_changed=true
	fi
	if [ "$restart_required" = "false" ] && rpcd_surface_ready; then
		luci_http_surface_ready && return 0
		restart_uhttpd_for_rpc; return $?
	fi
	rinit=$(root_path /etc/init.d/rpcd)
	[ -x "$rinit" ] && "$rinit" restart >/dev/null 2>&1 || return 1
	local_ready=false
	for attempt in 1 2 3 4; do
		if ubus call system board >/dev/null 2>&1 && rpcd_timeout_ready && uhttpd_timeout_ready && rpcd_surface_ready; then
			local_ready=true
			if luci_http_surface_ready; then
				[ "$uhttpd_timeout_changed" = true ] || return 0
				restart_uhttpd_for_rpc; return $?
			fi
			break
		fi
		[ "$attempt" -eq 4 ] || sleep 1
	done
	[ "$local_ready" = "true" ] && restart_uhttpd_for_rpc
}

is_presentation_path() {
	case "$1" in
		www/luci-static/resources/netfleet/*|www/luci-static/resources/view/netfleet/*|\
		usr/share/luci/menu.d/luci-app-netfleet.json|usr/share/rpcd/acl.d/luci-app-netfleet.json) return 0 ;;
		*) return 1 ;;
	esac
}

verify_manifest() {
	scope=$1
	while read -r expected rel extra; do
		[ -n "$expected" ] || continue
		[ -z "${extra:-}" ] || return 1
		case "$rel" in /*|*../*|*' '*) return 1 ;; esac
		if [ "$scope" = "runtime" ] && is_presentation_path "$rel"; then continue; fi
		target=$(root_path "/$rel")
		if [ ! -f "$target" ]; then
			[ "$scope" != "all" ] || error_detail="missing:$rel"
			return 1
		fi
		if [ "$(sha_of "$target")" != "$expected" ]; then
			[ "$scope" != "all" ] || error_detail="digest:$rel"
			return 1
		fi
	done <"$bundle/FILES.sha256"
}

current_runtime_payload_digest() {
	runtime_manifest="$action_dir/runtime-files.sha256"
	: >"$runtime_manifest"
	while read -r expected rel extra; do
		[ -n "$expected" ] || continue
		[ -z "${extra:-}" ] || return 1
		case "$rel" in /*|*../*|*' '*) return 1 ;; esac
		is_presentation_path "$rel" && continue
		printf '%s  %s\n' "$expected" "$rel" >>"$runtime_manifest"
	done <"$bundle/FILES.sha256"
	sha_of "$runtime_manifest"
}

json_semantically_equal() {
	[ -f "$1" ] && [ -f "$2" ] || return 1
	ucode - "$1" "$2" >/dev/null 2>&1 <<'UCODE'
import { readfile } from "fs";
function same(a, b) {
	if (type(a) != type(b)) return false;
	if (type(a) == "array") {
		if (length(a) != length(b)) return false;
		for (let i = 0; i < length(a); i++) if (!same(a[i], b[i])) return false;
		return true;
	}
	if (type(a) == "object") {
		const ka = keys(a), kb = keys(b);
		if (length(ka) != length(kb)) return false;
		for (let i = 0; i < length(ka); i++) if (index(kb, ka[i]) < 0 || !same(a[ka[i]], b[ka[i]])) return false;
		return true;
	}
	return a == b;
}
try { exit(same(json(readfile(ARGV[0])), json(readfile(ARGV[1]))) ? 0 : 1); } catch (e) { exit(1); }
UCODE
}

yaml_semantically_equal() {
	lj="$action_dir/yaml-left.$$.json"; rj="$action_dir/yaml-right.$$.json"
	if yq -M -p yaml -o json "$1" >"$lj" 2>/dev/null &&
		yq -M -p yaml -o json "$2" >"$rj" 2>/dev/null &&
		json_semantically_equal "$lj" "$rj"; then
		rm -f -- "$lj" "$rj"; return 0
	fi
	rm -f -- "$lj" "$rj"; return 1
}

install_identity() {
	mkdir -p "$(dirname "$installed_identity")" &&
		cp "$bundle/bundle.json" "${installed_identity}.tmp" &&
		chmod 0644 "${installed_identity}.tmp" &&
		mv -f "${installed_identity}.tmp" "$installed_identity"
}

install_release_packages() {
	pm="$bundle/package-manifest.json"
	pkey=$(jf "$pm" '@.apk_public_key.name')
	parch=$(jf "$pm" '@.package_arch')
	package_files=""
	for pf in $(jf "$pm" '@.artifacts[*].name'); do
		[ -n "$pf" ] && [ -f "$bundle/$pf" ] || { fail package_file_missing; return 1; }
		package_files="$package_files $bundle/$pf"
	done
	if [ "$release_format" = "apk" ]; then
		command -v apk >/dev/null 2>&1 || { fail package_manager_unavailable; return 1; }
		tarch=$(apk --print-arch 2>/dev/null || true)
		arch_ok=false
		[ "$parch" = "noarch" ] || [ "$tarch" = "$parch" ] ||
			{ [ "$parch" = "aarch64_generic" ] && [ "$tarch" = "aarch64" ]; } && arch_ok=true
		[ "$arch_ok" = true ] || { fail package_arch_mismatch "$tarch"; return 1; }
		[ -n "$pkey" ] && [ -f "$bundle/$pkey" ] || { fail package_key_missing; return 1; }
		mkdir -p "$(root_path /etc/apk/keys)"
		kt=$(root_path "/etc/apk/keys/$pkey")
		if [ -f "$kt" ] && [ "$(sha_of "$kt")" != "$(sha_of "$bundle/$pkey")" ]; then
			fail package_key_conflict; return 1
		fi
		cp "$bundle/$pkey" "${kt}.tmp.$$" && chmod 0644 "${kt}.tmp.$$" && mv -f "${kt}.tmp.$$" "$kt" ||
			{ rm -f "${kt}.tmp.$$"; fail package_key_install_failed; return 1; }
		apk --no-network --repositories-file /dev/null add $package_files >/dev/null 2>&1 ||
			{ fail package_install_failed; return 1; }
		return 0
	fi
	if [ "$release_format" = "ipk" ]; then
		command -v opkg >/dev/null 2>&1 || { fail package_manager_unavailable; return 1; }
		opkg install $package_files >/dev/null 2>&1 || { fail package_install_failed; return 1; }
		return 0
	fi
	fail package_release_invalid; return 1
}

install_owned_payload() {
	payload_mutated=1
	menu_path=$(root_path /usr/share/luci/menu.d/luci-app-netfleet.json)
	menu_before=""
	[ ! -f "$menu_path" ] || menu_before=$(sha_of "$menu_path")
	install_release_packages || return 1
	menu_after=""
	[ ! -f "$menu_path" ] || menu_after=$(sha_of "$menu_path")
	luci_menu_changed=false
	if [ "$menu_before" != "$menu_after" ]; then
		luci_menu_changed=true
		ltmp=$(root_path /tmp)
		rm -f "$ltmp"/luci-indexcache.*
		rm -rf "$ltmp/luci-modulecache"
	fi
	verify_manifest all || { fail installed_parity_failed; return 1; }
	ensure_rpcd_surface "$luci_menu_changed" || { fail rpcd_surface_unavailable; return 1; }
}

native_owner_ready() {
	nikki_init=$(root_path /etc/init.d/nikki)
	[ -x "$nikki_init" ] && [ "$(current_profile)" = "$1" ] &&
		ubus call system board >/dev/null 2>&1 &&
		[ "$("$nikki_init" status 2>/dev/null || true)" = "running" ] &&
		pidof mihomo >/dev/null 2>&1
}

run_action() {
	main=$1; action=$2; output=$3; shift 3
	ucode "$main" "$action" "$@" >"$output" 2>"$output.stderr" && [ "$(jf "$output" '@.ok')" = "true" ]
}

action_error_detail() {
	ae=$(jf "$1" '@.error')
	if [ "$ae" = "unexpected_error" ]; then
		detail=unexpected_error_lines; found=false
		for idx in 0 1 2 3 4; do
			ln=$(jf "$1" "@.detail.unexpected_stacktrace[$idx].line")
			case "$ln" in ''|*[!0-9]*) continue ;; esac
			detail="${detail}_$ln"; found=true
		done
		if [ "$found" = "true" ]; then printf '%s\n' "$detail"; return 0; fi
	fi
	printf '%s\n' "$ae"
}

atomic_install_verified() {
	src=$1; dst=$2; mode=$3; expected=$4; err=$5
	tmp="${dst}.tmp.$$"
	mkdir -p "$(dirname "$dst")"
	if cp "$src" "$tmp" && chmod "$mode" "$tmp" && [ "$(sha_of "$tmp")" = "$expected" ] && mv -f "$tmp" "$dst"; then
		return 0
	fi
	rm -f -- "$tmp"; fail "$err"; return 1
}

install_declared_policy() {
	[ "$instance" = "1" ] || return 0
	atomic_install_verified "$bundle/policy.json" "$(root_path /etc/opl-netfleet/policy.json)" 0600 \
		"$(jf "$bundle/bundle.json" '@.policy_sha256')" policy_install_failed
}

install_declared_mixin() {
	[ "$instance" = "1" ] || return 0
	yq -M -p yaml -o json "$bundle/nikki-mixin.yaml" >/dev/null 2>&1 || { fail nikki_mixin_install_failed; return 1; }
	atomic_install_verified "$bundle/nikki-mixin.yaml" "$(root_path /etc/nikki/mixin.yaml)" 0644 \
		"$(jf "$bundle/bundle.json" '@.nikki_mixin_sha256')" nikki_mixin_install_failed || return 1
	uci set nikki.mixin.mixin_file_content=1 && uci commit nikki || { fail nikki_mixin_install_failed; return 1; }
}

platform_val() { jf "$bundle/platform.json" "@.$1.$2"; }
platform_bool() {
	case "$(platform_val "$1" "$2")" in
		true) printf '1' ;;
		false) printf '0' ;;
		*) return 1 ;;
	esac
}

platform_field_expected() {
	if [ "$2" = "bool" ]; then platform_bool nikki "$1"; else platform_val nikki "$1"; fi
}

platform_current_matches() {
	while read -r sec opt field kind; do
		[ -n "$sec" ] || continue
		exp=$(platform_field_expected "$field" "$kind") || return 1
		[ "$(uci_get "nikki.$sec.$opt")" = "$exp" ] || return 1
	done <<EOF
$platform_uci_map
EOF
	override=$(platform_bool nikki sniffer_override_destination) || return 1
	sw=$(platform_bool openwrt software_flow_offload) || return 1
	hw=$(platform_bool openwrt hardware_flow_offload) || return 1
	[ "$(uci_get nikki.mixin.sniffer_sniff)" = "1" ] &&
		[ "$(uci_get 'nikki.@sniff[0].protocol')" = "HTTP" ] &&
		[ "$(uci_get 'nikki.@sniff[1].protocol')" = "TLS" ] &&
		[ "$(uci_get 'nikki.@sniff[2].protocol')" = "QUIC" ] &&
		[ "$(uci_get 'nikki.@sniff[0].overwrite_destination')" = "$override" ] &&
		[ "$(uci_get 'nikki.@sniff[1].overwrite_destination')" = "$override" ] &&
		[ "$(uci_get 'nikki.@sniff[2].overwrite_destination')" = "$override" ] &&
		[ "$(uci_get 'firewall.@defaults[0].flow_offloading')" = "$sw" ] &&
		[ "$(uci_get 'firewall.@defaults[0].flow_offloading_hw')" = "$hw" ]
}

install_declared_platform() {
	[ "$instance" = "1" ] && [ "$platform_matches" != "true" ] || return 0
	override=$(platform_bool nikki sniffer_override_destination) || { fail platform_config_failed; return 1; }
	while read -r sec opt field kind; do
		[ -n "$sec" ] || continue
		val=$(platform_field_expected "$field" "$kind") && uci set "nikki.$sec.$opt=$val" || { fail platform_config_failed; return 1; }
	done <<EOF
$platform_uci_map
EOF
	uci set nikki.mixin.sniffer_sniff=1 &&
		[ "$(uci_get 'nikki.@sniff[0].protocol')" = "HTTP" ] &&
		[ "$(uci_get 'nikki.@sniff[1].protocol')" = "TLS" ] &&
		[ "$(uci_get 'nikki.@sniff[2].protocol')" = "QUIC" ] &&
		uci set "nikki.@sniff[0].overwrite_destination=$override" &&
		uci set "nikki.@sniff[1].overwrite_destination=$override" &&
		uci set "nikki.@sniff[2].overwrite_destination=$override" &&
		uci commit nikki || { fail platform_config_failed; return 1; }
	sw=$(platform_bool openwrt software_flow_offload) || { fail platform_config_failed; return 1; }
	hw=$(platform_bool openwrt hardware_flow_offload) || { fail platform_config_failed; return 1; }
	if [ "$(uci_get 'firewall.@defaults[0].flow_offloading')" != "$sw" ] ||
		[ "$(uci_get 'firewall.@defaults[0].flow_offloading_hw')" != "$hw" ]; then
		uci set "firewall.@defaults[0].flow_offloading=$sw" &&
			uci set "firewall.@defaults[0].flow_offloading_hw=$hw" &&
			uci commit firewall || { fail platform_config_failed; return 1; }
		fw_init=$(root_path /etc/init.d/firewall)
		[ -x "$fw_init" ] && "$fw_init" reload >/dev/null 2>&1 || { fail platform_firewall_reload_failed; return 1; }
	fi
	platform_current_matches || { fail platform_readback_failed; return 1; }
	platform_changed=true
}

sub_val() { jf "$bundle/subscriptions.json" "@.subscriptions[$1].$2"; }

subscription_entry_matches() {
	s_sec=$1; s_name=$2; s_url=$3; s_ua=$4; s_info=$5
	s_cache=$(root_path "/etc/nikki/subscriptions/$s_sec.yaml")
	[ "$(uci_get "nikki.$s_sec")" = "subscription" ] &&
		[ "$(uci_get "nikki.$s_sec.name")" = "$s_name" ] &&
		[ "$(uci_get "nikki.$s_sec.url")" = "$s_url" ] &&
		[ "$(uci_get "nikki.$s_sec.user_agent")" = "$s_ua" ] &&
		[ "$(uci_get "nikki.$s_sec.info_url")" = "$s_info" ] &&
		[ -f "$s_cache" ] && yq -M -p yaml -o json "$s_cache" >/dev/null 2>&1
}

validate_instance_inputs() {
	[ "$instance" = "1" ] || return 0
	p_schema=$(jf "$bundle/platform.json" '@.schema_version')
	p_target=$(jf "$bundle/platform.json" '@.target')
	pol_target=$(jf "$bundle/policy.json" '@.main.target')
	if [ "$p_schema" != "1" ] || [ -z "$pol_target" ] || [ "$p_target" != "$pol_target" ] ||
		[ "$(platform_val nikki api_listen)" != "0.0.0.0:9090" ] ||
		[ "$(platform_val nikki dns_mode)" != "redir-host" ] ||
		[ "$(platform_val nikki tcp_mode)" != "tproxy" ] ||
		[ "$(platform_val nikki udp_mode)" != "tproxy" ] ||
		[ "$(platform_bool nikki api_secret_required 2>/dev/null || true)" != "1" ] ||
		[ "$(platform_bool nikki allow_lan 2>/dev/null || true)" != "1" ] ||
		[ "$(platform_bool nikki tun_enabled 2>/dev/null || true)" != "0" ] ||
		[ "$(platform_bool nikki fake_ip_cache 2>/dev/null || true)" != "0" ] ||
		[ "$(platform_bool nikki sniffer_override_destination 2>/dev/null || true)" != "0" ] ||
		[ "$(platform_bool openwrt software_flow_offload 2>/dev/null || true)" != "0" ] ||
		[ "$(platform_bool openwrt hardware_flow_offload 2>/dev/null || true)" != "0" ]; then
		fail instance_platform_schema_invalid; return 1
	fi
	while read -r sec opt field kind; do
		[ -n "$sec" ] || continue
		if [ "$kind" = "bool" ]; then
			platform_bool nikki "$field" >/dev/null || { fail instance_platform_schema_invalid "$field"; return 1; }
		else
			[ -n "$(platform_val nikki "$field")" ] || { fail instance_platform_schema_invalid "$field"; return 1; }
		fi
	done <<EOF
$platform_uci_map
EOF
	if [ "$(platform_bool nikki api_secret_required)" = "1" ] && [ -z "$(uci_get nikki.mixin.api_secret)" ]; then
		fail instance_platform_secret_missing; return 1
	fi
	platform_matches=false
	platform_current_matches && platform_matches=true
	external_state_paths="$external_state_paths etc/config/firewall"

	[ "$(jf "$bundle/subscriptions.json" '@.schema_version')" = "1" ] || { fail instance_subscriptions_schema_invalid; return 1; }
	ps_kind=$(jf "$bundle/policy.json" '@.policy_source.kind')
	ps_ref=$(jf "$bundle/policy.json" '@.policy_source.ref')
	recovery_profile_ref=$(jf "$bundle/policy.json" '@.recovery_profile.ref')
	ps_sec=""
	case "$ps_kind:$ps_ref" in
		profile:subscription:*) ps_sec=${ps_ref#subscription:} ;;
		bundle:bundle:*)
			ps_bundle=${ps_ref#bundle:}
			case "$ps_bundle" in *[!A-Za-z0-9_-]*|'') fail instance_policy_source_unsupported; return 1 ;; esac
			[ -f "$(root_path "/etc/opl-netfleet/policy-sources/$ps_bundle.json")" ] ||
				grep -Eq "^[0-9a-f]{64}  etc/opl-netfleet/policy-sources/$ps_bundle\\.json$" "$bundle/FILES.sha256" ||
				{ fail instance_policy_source_unsupported; return 1; }
			;;
		*) fail instance_policy_source_unsupported; return 1 ;;
	esac
	case "$recovery_profile_ref" in
		subscription:*) rec_sec=${recovery_profile_ref#subscription:} ;;
		*) fail instance_recovery_profile_unsupported; return 1 ;;
	esac
	if [ -n "$ps_sec" ]; then
		case "$ps_sec" in *[!A-Za-z0-9_]*|'') fail instance_policy_source_unsupported; return 1 ;; esac
	fi
	case "$rec_sec" in *[!A-Za-z0-9_]*|'') fail instance_recovery_profile_unsupported; return 1 ;; esac

	seen=,; declared_ps=0; declared_rec=0; idx=0; sub_paths=""; subscriptions_match=true
	while :; do
		sec=$(sub_val "$idx" section); [ -n "$sec" ] || break
		case "$sec" in *[!A-Za-z0-9_]*|'') fail instance_subscription_section_invalid; return 1 ;; esac
		case "$seen" in *",$sec,"*) fail instance_subscription_section_duplicate; return 1 ;; esac
		seen="${seen}${sec},"
		[ -z "$ps_sec" ] || [ "$sec" != "$ps_sec" ] || declared_ps=1
		[ "$sec" != "$rec_sec" ] || declared_rec=1
		name=$(sub_val "$idx" name); url=$(sub_val "$idx" url)
		ua=$(sub_val "$idx" user_agent); info=$(sub_val "$idx" info_url)
		[ -n "$name" ] || { fail instance_subscription_name_invalid; return 1; }
		case "$url" in https://*) ;; *) fail instance_subscription_url_invalid; return 1 ;; esac
		case "$info" in ''|https://*) ;; *) fail instance_subscription_info_url_invalid; return 1 ;; esac
		sub_paths="$sub_paths etc/nikki/subscriptions/$sec.yaml"
		subscription_entry_matches "$sec" "$name" "$url" "$ua" "$info" || subscriptions_match=false
		idx=$((idx + 1))
	done
	[ "$idx" -gt 0 ] || { fail instance_subscriptions_empty; return 1; }
	[ -z "$ps_sec" ] || [ "$declared_ps" = "1" ] || { fail instance_policy_source_subscription_missing; return 1; }
	[ "$declared_rec" = "1" ] || { fail instance_recovery_subscription_missing; return 1; }
	for psec in $(jf "$bundle/policy.json" '@.providers.*.section'); do
		case "$seen" in *",$psec,"*) ;; *) fail instance_provider_subscription_missing "$psec"; return 1 ;; esac
	done
	case "$seen" in
		*,subscription,*) ;;
		*)
			if [ "$(uci_get nikki.subscription)" = "subscription" ] &&
				[ "$(uci_get nikki.subscription.name)" = "default" ] &&
				[ "$(uci_get nikki.subscription.user_agent)" = "clash" ] &&
				[ "$(uci_get nikki.subscription.success)" != "1" ] &&
				[ ! -e "$(root_path /etc/nikki/subscriptions/subscription.yaml)" ] &&
				[ "$(current_profile)" != "subscription:subscription" ]; then
				default_placeholder_present=true
			fi
			;;
	esac
	external_state_paths="$external_state_paths etc/config/nikki etc/nikki/mixin.yaml$sub_paths"
}

cleanup_default_subscription_placeholder() {
	[ "$instance" = "1" ] && [ "$default_placeholder_present" = "true" ] || return 0
	cfg=$(root_path /etc/config/nikki); bak="$action_dir/nikki-before-placeholder-cleanup"
	[ -f "$cfg" ] && cp -a "$cfg" "$bak" || { fail default_subscription_cleanup_failed; return 1; }
	if ! uci -q delete nikki.subscription >/dev/null 2>&1 || ! uci commit nikki || [ -n "$(uci_get nikki.subscription)" ]; then
		cp -a "$bak" "$cfg" >/dev/null 2>&1 || true; fail default_subscription_cleanup_failed; return 1
	fi
	default_placeholder_present=false
}

install_instance_subscriptions() {
	[ "$instance" = "1" ] || return 0
	idx=0
	while :; do
		sec=$(sub_val "$idx" section); [ -n "$sec" ] || break
		name=$(sub_val "$idx" name); url=$(sub_val "$idx" url)
		ua=$(sub_val "$idx" user_agent); info=$(sub_val "$idx" info_url)
		cache=$(root_path "/etc/nikki/subscriptions/$sec.yaml")
		if ! subscription_entry_matches "$sec" "$name" "$url" "$ua" "$info"; then
			uci -q delete "nikki.$sec" >/dev/null 2>&1 || true
			uci set "nikki.$sec=subscription" && uci set "nikki.$sec.name=$name" && uci set "nikki.$sec.url=$url" ||
				{ fail instance_subscription_config_failed; return 1; }
			[ -z "$ua" ] || uci set "nikki.$sec.user_agent=$ua" || { fail instance_subscription_config_failed; return 1; }
			[ -z "$info" ] || uci set "nikki.$sec.info_url=$info" || { fail instance_subscription_config_failed; return 1; }
			nikki_init=$(root_path /etc/init.d/nikki)
			if ! uci commit nikki || [ ! -x "$nikki_init" ] ||
				! "$nikki_init" update_subscription "$sec" >/dev/null 2>&1 ||
				[ "$(uci_get "nikki.$sec.success")" != "1" ] ||
				[ ! -f "$cache" ] || ! yq -M -p yaml -o json "$cache" >/dev/null 2>&1; then
				fail instance_subscription_update_failed "$sec"; return 1
			fi
		fi
		idx=$((idx + 1))
	done
	if [ -z "$(current_profile)" ]; then
		uci set "nikki.config.profile=$recovery_profile_ref" && uci commit nikki ||
			{ fail instance_recovery_profile_set_failed; return 1; }
	fi
}

rs_val() { jf "$bundle/rulesets.lock.json" "@.rulesets[$1].$2"; }

download_locked_ruleset() {
	url=$1; out=$2; secret=$(uci_get nikki.mixin.api_secret); proxy_port=""
	if [ "$(uci_get nikki.config.enabled)" = "1" ] && command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1 && [ -n "$secret" ]; then
		proxy_port=$(curl -fsS --noproxy '*' --proxy '' --connect-timeout 2 --max-time 3 \
			-H "Authorization: Bearer $secret" http://127.0.0.1:9090/configs 2>/dev/null | jsonfilter -e '@.mixed-port' 2>/dev/null || true)
	fi
	case "$proxy_port" in ''|*[!0-9]*) proxy_port="" ;; *) [ "$proxy_port" -ge 1 ] && [ "$proxy_port" -le 65535 ] || proxy_port="" ;; esac
	if [ -n "$proxy_port" ]; then
		if [ "$(uci_get nikki.mixin.authentication)" = "1" ]; then
			pu=$(uci_get 'nikki.@authentication[0].username'); pp=$(uci_get 'nikki.@authentication[0].password')
			[ -n "$pu" ] && [ -n "$pp" ] || return 1
			curl -fsSL --noproxy '' --proxy "http://127.0.0.1:$proxy_port" --proxy-user "$pu:$pp" --connect-timeout 10 --max-time 90 -o "$out" "$url"
			return
		fi
		curl -fsSL --noproxy '' --proxy "http://127.0.0.1:$proxy_port" --connect-timeout 10 --max-time 90 -o "$out" "$url"
		return
	fi
	curl -fsSL --noproxy '*' --proxy '' --connect-timeout 10 --max-time 90 -o "$out" "$url"
}

verify_locked_rulesets() {
	idx=0
	while :; do
		id=$(rs_val "$idx" id); [ -n "$id" ] || break
		path=$(root_path "/etc/nikki/run/rulesets/$id.mrs")
		[ -f "$path" ] && [ "$(wc -c <"$path" | tr -d ' ')" = "$(rs_val "$idx" size_bytes)" ] &&
			[ "$(sha_of "$path")" = "$(rs_val "$idx" sha256)" ] || return 1
		idx=$((idx + 1))
	done
	[ "$idx" -gt 0 ]
}

is_hex() {
	[ "${#1}" -eq "$2" ] || return 1
	case "$1" in *[!0-9a-f]*) return 1 ;; esac
}

prepare_locked_rulesets() {
	[ "$(jf "$bundle/rulesets.lock.json" '@.schema')" = "opl-netfleet-ruleset-lock.v1" ] || { fail ruleset_lock_schema_invalid; return 1; }
	upstream=$(jf "$bundle/rulesets.lock.json" '@.upstream.commit')
	is_hex "$upstream" 40 || { fail ruleset_lock_identity_invalid; return 1; }
	seen=,; idx=0
	while :; do
		id=$(rs_val "$idx" id); [ -n "$id" ] || break
		beh=$(rs_val "$idx" behavior); fmt=$(rs_val "$idx" format)
		url=$(rs_val "$idx" url); sz=$(rs_val "$idx" size_bytes); sha=$(rs_val "$idx" sha256)
		case "$id" in *[!A-Za-z0-9_-]*|'') fail ruleset_lock_entry_invalid; return 1 ;; esac
		case "$seen" in *",$id,"*) fail ruleset_lock_entry_duplicate; return 1 ;; esac
		seen="${seen}${id},"
		case "$beh" in domain|ipcidr) ;; *) fail ruleset_lock_entry_invalid "$id"; return 1 ;; esac
		[ "$fmt" = "mrs" ] || { fail ruleset_lock_entry_invalid "$id"; return 1; }
		case "$url" in "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/$upstream/"*) ;; *) fail ruleset_lock_url_invalid "$id"; return 1 ;; esac
		case "$sz" in ''|*[!0-9]*) fail ruleset_lock_entry_invalid "$id"; return 1 ;; esac
		[ "$sz" -gt 0 ] && is_hex "$sha" 64 || { fail ruleset_lock_entry_invalid "$id"; return 1; }
		idx=$((idx + 1))
	done
	[ "$idx" -gt 0 ] || { fail ruleset_lock_set_invalid; return 1; }
	ruleset_count=$idx
	for req in cn-domain cn-ip geolocation-non-cn; do
		case "$seen" in *",$req,"*) ;; *) fail ruleset_lock_set_invalid "$req"; return 1 ;; esac
	done
	rulesets_match=false
	if verify_locked_rulesets; then rulesets_match=true; return 0; fi
	rulesets_stage_dir=$bundle/rulesets-staged
	rm -rf -- "$rulesets_stage_dir" && mkdir -p "$rulesets_stage_dir" || { fail ruleset_stage_failed; return 1; }
	idx=0
	while [ "$idx" -lt "$ruleset_count" ]; do
		id=$(rs_val "$idx" id); url=$(rs_val "$idx" url)
		sz=$(rs_val "$idx" size_bytes); sha=$(rs_val "$idx" sha256)
		tmp="$rulesets_stage_dir/$id.mrs.tmp"
		if ! download_locked_ruleset "$url" "$tmp" ||
			[ "$(wc -c <"$tmp" 2>/dev/null | tr -d ' ')" != "$sz" ] ||
			[ "$(sha_of "$tmp" 2>/dev/null || true)" != "$sha" ] ||
			! mv -f "$tmp" "$rulesets_stage_dir/$id.mrs"; then
			rm -f -- "$tmp"; fail ruleset_download_failed "$id"; return 1
		fi
		idx=$((idx + 1))
	done
}

install_locked_rulesets() {
	legacy=$(root_path /etc/opl-netfleet/rulesets)
	if [ "$rulesets_match" = "true" ]; then rm -rf -- "$legacy"; return 0; fi
	target=$(root_path /etc/nikki/run/rulesets)
	tmp="${target}.new.$$"; old="${target}.old.$$"
	rm -rf -- "$tmp" "$old" && mkdir -p "$tmp" || { fail ruleset_install_failed; return 1; }
	idx=0
	while [ "$idx" -lt "$ruleset_count" ]; do
		id=$(rs_val "$idx" id)
		cp "$rulesets_stage_dir/$id.mrs" "$tmp/$id.mrs" && chmod 0644 "$tmp/$id.mrs" || { fail ruleset_install_failed; return 1; }
		idx=$((idx + 1))
	done
	[ ! -e "$target" ] || mv "$target" "$old" || { fail ruleset_install_failed; return 1; }
	if ! mv "$tmp" "$target"; then
		[ ! -e "$old" ] || mv "$old" "$target" >/dev/null 2>&1 || true
		fail ruleset_install_failed; return 1
	fi
	rm -rf -- "$old"
	verify_locked_rulesets || { fail ruleset_readback_failed; return 1; }
	rm -rf -- "$legacy"
	rulesets_changed=true
}

snapshot_current() {
	new_dir="${rollback_dir}.new.$$"; old_dir="${rollback_dir}.old.$$"
	rm -rf -- "$new_dir" "$old_dir" && mkdir -p "$new_dir/files" || return 1
	for rel in $owned_paths $state_paths $external_state_paths $runtime_state_paths; do
		target=$(root_path "/$rel")
		if [ -e "$target" ] || [ -L "$target" ]; then
			dst="$new_dir/files/$rel"
			mkdir -p "$(dirname "$dst")" && cp -a "$target" "$dst" || return 1
		else
			printf '%s\n' "$rel" >>"$new_dir/absent" || return 1
		fi
	done
	printf '%s\n' "$(current_profile)" >"$new_dir/profile-before" || return 1
	! supervisor_enabled || : >"$new_dir/supervisor-enabled" || return 1
	! supervisor_running || : >"$new_dir/supervisor-running" || return 1
	(cd "$new_dir/files" && tar -cf "$new_dir/snapshot.tar" .) && rm -rf -- "$new_dir/files" || return 1
	[ ! -e "$rollback_dir" ] || mv "$rollback_dir" "$old_dir" || return 1
	if ! mv "$new_dir" "$rollback_dir"; then
		[ ! -e "$old_dir" ] || mv "$old_dir" "$rollback_dir"; return 1
	fi
	rm -rf -- "$old_dir"
}

migrate_evidence_state() {
	persistent=$(root_path /etc/opl-netfleet/evidence.json)
	legacy=$(root_path /var/lib/opl-netfleet/evidence.json)
	if [ ! -f "$persistent" ] && [ -f "$legacy" ]; then
		mkdir -p "$(dirname "$persistent")" &&
			cp "$legacy" "${persistent}.tmp.$$" &&
			chmod 0600 "${persistent}.tmp.$$" &&
			mv -f "${persistent}.tmp.$$" "$persistent" || { rm -f "${persistent}.tmp.$$"; return 1; }
	fi
	[ ! -f "$persistent" ] || rm -f "$legacy"
}

rollback_payload() {
	profile=$(current_profile)
	new_main=$(root_path /usr/libexec/opl-netfleet/main.uc)
	if is_netfleet_profile "$profile" && [ -f "$new_main" ]; then
		run_action "$new_main" disable "$action_dir/rollback-disable.json" || true
		profile=$(current_profile)
	fi
	if is_netfleet_profile "$profile"; then
		rollback_state=active_profile_not_recoverable; return 1
	fi
	if [ "$instance" = "1" ]; then
		restore_snapshot_bytes || { rollback_state=original_nikki_state_not_recoverable; return 1; }
		restored_main=$(root_path /usr/libexec/opl-netfleet/main.uc)
		nikki_init=$(root_path /etc/init.d/nikki)
		if is_netfleet_profile "$profile_before"; then
			[ -x "$restored_main" ] && run_action "$restored_main" disable "$action_dir/rollback-old-disable.json" ||
				{ rollback_state=original_active_owner_not_recoverable; return 1; }
		elif [ -n "$profile_before" ]; then
			[ -x "$nikki_init" ] && "$nikki_init" restart >/dev/null 2>&1 && native_owner_ready "$profile_before" ||
				{ rollback_state=original_native_profile_not_recoverable; return 1; }
		else
			[ -x "$nikki_init" ] && "$nikki_init" stop >/dev/null 2>&1 ||
				{ rollback_state=original_passthrough_not_recoverable; return 1; }
		fi
		restore_supervisor_state && { rollback_state=restored_previous_bytes_native_profile; return 0; }
		rollback_state=restore_failed; return 1
	fi
	restore_snapshot_bytes && restore_supervisor_state &&
		{ rollback_state=restored_previous_bytes_native_profile; return 0; }
	rollback_state=restore_failed; return 1
}

on_exit() {
	rc=$?
	trap - EXIT
	if [ "$rc" -ne 0 ]; then
		set +e
		if [ "$payload_mutated" = "1" ]; then
			if [ "$control_plane_repair" = "1" ]; then
				if restore_control_plane_snapshot; then
					rollback_state=restored_previous_control_plane_active_profile
				else
					rollback_state=restore_failed
				fi
			else
				rollback_payload || true
			fi
		elif [ "$service_mutated" = "1" ]; then
			if [ "$service_restore_mode" = "flags" ]; then
				restore_supervisor_flags "$service_before_enabled" "$service_before_running" || rollback_state=restore_failed
			else
				restore_supervisor_state || rollback_state=restore_failed
			fi
		fi
		emit_failure
	fi
	exit "$rc"
}
trap on_exit EXIT

[ -n "$bundle" ] && [ -d "$bundle" ] || fail_exit bundle_missing
for tool in awk chmod cp curl dirname find grep ip mkdir mv rm sha256sum sleep tar tr ubus uci wc; do
	command -v "$tool" >/dev/null 2>&1 || fail_exit unsupported_target "$tool"
done
[ -n "$root_prefix" ] || [ "$(id -u)" = "0" ] || fail_exit root_required
[ -n "$root_prefix" ] || [ -f /etc/openwrt_release ] || fail_exit unsupported_target openwrt_identity
if [ "$allow_disable" = "0" ] && is_netfleet_profile "$(current_profile)"; then
	fail_exit active_target_requires_explicit_mode
fi

for path in SHA256SUMS FILES.sha256 bundle.json deploy-openwrt-remote.sh; do
	[ -f "$bundle/$path" ] || fail_exit bundle_incomplete
done
while read -r expected path extra; do
	[ -n "$expected" ] || continue
	[ -z "${extra:-}" ] || fail_exit bundle_checksum_format_invalid
	case "$path" in
		FILES.sha256|bundle.json|deploy-openwrt-remote.sh|rulesets.lock.json|package-manifest.json|*.apk|*.ipk|packages.adb|opl-netfleet-apk.pem|policy.json|subscriptions.json|nikki-mixin.yaml|platform.json) ;;
		*) fail_exit bundle_checksum_path_invalid ;;
	esac
done <"$bundle/SHA256SUMS"
(cd "$bundle" && sha256sum -c SHA256SUMS >/dev/null) || fail_exit bundle_checksum_mismatch

bootstrap_instance_dependencies || exit 1

lock_path=$(root_path /var/lock/opl-netfleet-deploy.lock)
mkdir -p "$(dirname "$lock_path")"
if [ "${OPL_NETFLEET_DEPLOY_LOCKED:-}" != "1" ]; then
	exec 8>"$(root_path /var/lock/opl-netfleet-operator.lock)"
	flock -n 8 || fail_exit operator_window_busy
	exec 9>"$lock_path"
	flock -n 9 || fail_exit deploy_busy
	set -- --bundle "$bundle"
	if [ "$presentation_only" = "1" ]; then set -- "$@" --presentation-only
	elif [ "$preserve_state" = "1" ]; then set -- "$@" --preserve-state
	elif [ "$allow_disable" = "1" ]; then set -- "$@" --leave-disabled
	else set -- "$@" --stage-only; fi
	[ "$instance" != "1" ] || set -- "$@" --instance
	trap - EXIT
	OPL_NETFLEET_DEPLOY_LOCKED=1 sh "$0" "$@" 8>&- 9>&-
	exit $?
fi

source_commit=$(jf "$bundle/bundle.json" '@.source_commit')
source_tree=$(jf "$bundle/bundle.json" '@.source_tree')
product_version=$(jf "$bundle/bundle.json" '@.product_version')
bundle_schema=$(jf "$bundle/bundle.json" '@.schema')
bundle_instance=$(jf "$bundle/bundle.json" '@.instance')
[ "$bundle_instance" = "true" ] || bundle_instance=false
case "$bundle_schema" in
	opl-netfleet-deploy-bundle.v3|opl-netfleet-deploy-bundle.v4|opl-netfleet-deploy-bundle.v5) ;;
	*) fail_exit bundle_schema_invalid ;;
esac
is_hex "$source_commit" 40 && is_hex "$source_tree" 40 || fail_exit bundle_identity_invalid
case "$product_version" in '' ) ;; *[!0-9A-Za-z.+~-]*|[!0-9]*) fail_exit bundle_identity_invalid ;; esac

activation_qualified=$(jf "$bundle/bundle.json" '@.activation_qualified')
qualification_digest=$(jf "$bundle/bundle.json" '@.qualification_sha256')
runtime_payload_digest=$(jf "$bundle/bundle.json" '@.runtime_payload_sha256')
release_mode=$(jf "$bundle/bundle.json" '@.release_mode')
release_format=$(jf "$bundle/bundle.json" '@.release_format')
rulesets_lock_digest=$(jf "$bundle/bundle.json" '@.rulesets_lock_sha256')

# Legacy file-by-file source-overlay deployments are retired; OpenWrt signed apk/opkg
# packages own file ownership, upgrades, and plugin drain/resume hooks.
[ "$release_mode" = "package" ] || fail_exit package_release_required
case "$release_format" in apk|ipk) ;; *) fail_exit package_release_invalid ;; esac
[ -f "$bundle/package-manifest.json" ] || fail_exit package_release_incomplete
[ "$(jf "$bundle/package-manifest.json" '@.schema')" = "opl-netfleet-package-manifest.v2" ] || fail_exit package_manifest_invalid
[ "$(jf "$bundle/package-manifest.json" '@.source_commit')" = "$source_commit" ] &&
	[ "$(jf "$bundle/package-manifest.json" '@.source_tree')" = "$source_tree" ] || fail_exit package_manifest_identity_invalid

if [ "$bundle_schema" = "opl-netfleet-deploy-bundle.v5" ]; then
	[ -f "$bundle/rulesets.lock.json" ] && is_hex "$rulesets_lock_digest" 64 &&
		[ "$(sha_of "$bundle/rulesets.lock.json")" = "$rulesets_lock_digest" ] || fail_exit ruleset_lock_identity_invalid
fi
is_hex "$runtime_payload_digest" 64 || runtime_payload_digest=""
if [ "$preserve_state" = "1" ] && [ "$presentation_only" != "1" ]; then
	[ "$activation_qualified" = "true" ] && is_hex "$qualification_digest" 64 || fail_exit activation_qualification_required
fi
if [ "$instance" = "1" ]; then
	[ "$bundle_instance" = "true" ] && [ "$bundle_schema" = "opl-netfleet-deploy-bundle.v5" ] &&
		[ -f "$bundle/policy.json" ] && [ -f "$bundle/subscriptions.json" ] &&
		[ -f "$bundle/nikki-mixin.yaml" ] && [ -f "$bundle/platform.json" ] || fail_exit instance_incomplete
	policy_digest=$(jf "$bundle/bundle.json" '@.policy_sha256')
	subscriptions_digest=$(jf "$bundle/bundle.json" '@.subscriptions_sha256')
	mixin_digest=$(jf "$bundle/bundle.json" '@.nikki_mixin_sha256')
	platform_digest=$(jf "$bundle/bundle.json" '@.platform_sha256')
	is_hex "$policy_digest" 64 && [ "$(sha_of "$bundle/policy.json")" = "$policy_digest" ] &&
		is_hex "$subscriptions_digest" 64 && [ "$(sha_of "$bundle/subscriptions.json")" = "$subscriptions_digest" ] &&
		is_hex "$mixin_digest" 64 && [ "$(sha_of "$bundle/nikki-mixin.yaml")" = "$mixin_digest" ] &&
		is_hex "$platform_digest" 64 && [ "$(sha_of "$bundle/platform.json")" = "$platform_digest" ] &&
		yq -M -p yaml -o json "$bundle/nikki-mixin.yaml" >/dev/null 2>&1 || fail_exit instance_identity_invalid
else
	[ "$bundle_instance" != "true" ] || fail_exit instance_mode_required
fi

action_dir="$bundle/actions"
mkdir -p "$action_dir"
if [ "$bundle_schema" = "opl-netfleet-deploy-bundle.v5" ]; then
	prepare_locked_rulesets || exit 1
else
	rulesets_match=true
fi
[ "$instance" != "1" ] || validate_instance_inputs || exit 1

profile_before=$(current_profile)
[ -n "$profile_before" ] || [ "$instance" = "1" ] || fail_exit nikki_profile_unreadable
is_netfleet_profile "$profile_before" && was_active=true
ip -4 route show default 2>/dev/null | grep -q '^default ' || fail_exit upstream_default_route_missing

netfleet_present=false
preflight_active=false
live_policy=$(root_path /etc/opl-netfleet/policy.json)
old_main=$(root_path /usr/libexec/opl-netfleet/main.uc)

if [ "$instance" = "1" ]; then
	if [ -x "$old_main" ] && [ -f "$live_policy" ] && run_action "$old_main" status "$action_dir/preflight-status.json"; then
		netfleet_present=$(jf "$action_dir/preflight-status.json" '@.result.runtime.netfleet_present')
		preflight_active=$(jf "$action_dir/preflight-status.json" '@.result.active')
		if { [ "$was_active" = "true" ] || [ "$netfleet_present" = "true" ]; } &&
			! run_action "$old_main" probe "$action_dir/preflight-probe.json"; then
			fail_exit protected_probe_failed_before_deploy
		fi
	elif [ "$was_active" = "true" ]; then
		if [ ! -x "$old_main" ] && [ "$preserve_state" = "1" ] && [ "$presentation_only" != "1" ] &&
			ubus call system board >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1; then
			netfleet_present=true; preflight_active=true
		else
			fail_exit owner_status_unavailable
		fi
	fi
elif [ -x "$old_main" ]; then
	run_action "$old_main" validate "$action_dir/preflight-validate.json" || fail_exit candidate_validate_failed
	run_action "$old_main" status "$action_dir/preflight-status.json" || fail_exit owner_status_unavailable
	run_action "$old_main" probe "$action_dir/preflight-probe.json" || fail_exit protected_probe_failed_before_deploy
	netfleet_present=$(jf "$action_dir/preflight-status.json" '@.result.runtime.netfleet_present')
	preflight_active=$(jf "$action_dir/preflight-status.json" '@.result.active')
elif [ "$was_active" = "true" ] && [ "$preserve_state" = "1" ] && [ "$presentation_only" != "1" ] &&
	ubus call system board >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1; then
	# Active data plane whose control-plane binary is missing or non-executable:
	# allow in-place signed package control-plane repair without cycling data plane.
	netfleet_present=true; preflight_active=true
else
	fail_exit owner_status_unavailable
fi

[ "$presentation_only" = "1" ] || cleanup_default_subscription_placeholder || exit 1

installed_identity=$(root_path /etc/opl-netfleet/installed.json)
identity_matches=false
[ -f "$installed_identity" ] && [ "$(sha_of "$installed_identity")" = "$(sha_of "$bundle/bundle.json")" ] && identity_matches=true

candidate_runtime_digest=$(current_runtime_payload_digest 2>/dev/null || true)
runtime_payload_matches=false
[ -n "$runtime_payload_digest" ] && [ "$candidate_runtime_digest" = "$runtime_payload_digest" ] &&
	verify_manifest runtime && runtime_payload_matches=true

policy_matches=false
if [ "$instance" != "1" ] ||
	{ [ -f "$live_policy" ] && { [ "$(sha_of "$live_policy")" = "$policy_digest" ] || json_semantically_equal "$live_policy" "$bundle/policy.json"; }; }; then
	policy_matches=true
fi

mixin_matches=true
if [ "$instance" = "1" ]; then
	live_mixin=$(root_path /etc/nikki/mixin.yaml)
	if [ ! -f "$live_mixin" ] ||
		{ [ "$(sha_of "$live_mixin")" != "$mixin_digest" ] && ! yaml_semantically_equal "$live_mixin" "$bundle/nikki-mixin.yaml"; } ||
		[ "$(uci_get nikki.mixin.mixin_file_content)" != "1" ]; then
		mixin_matches=false
	fi
fi

instance_native_changed=false
if [ "$mixin_matches" != "true" ] || [ "$subscriptions_match" != "true" ] || [ "$platform_matches" != "true" ]; then
	instance_native_changed=true
fi

rpcd_timeout_matches=false
rpcd_timeout_ready && rpcd_timeout_matches=true

if [ "$presentation_only" = "1" ] &&
	{ [ "$instance" != "1" ] || [ "$was_active" != "true" ] || [ "$preflight_active" != "true" ] ||
	[ "$netfleet_present" != "true" ] || [ "$runtime_payload_matches" != "true" ] || [ "$policy_matches" != "true" ] ||
	[ "$mixin_matches" != "true" ] || [ "$subscriptions_match" != "true" ] || [ "$platform_matches" != "true" ] ||
	[ "$rulesets_match" != "true" ] || [ "$rpcd_timeout_matches" != "true" ]; }; then
	fail_exit presentation_only_precondition_failed
fi

shortcut_allowed=false
if [ "$instance" != "1" ] && [ "$rpcd_timeout_matches" = "true" ] && [ -x "$old_main" ]; then
	shortcut_allowed=true
elif [ "$preserve_state" = "1" ] && [ "$was_active" = "true" ] && [ -x "$old_main" ] &&
	[ "$policy_matches" = "true" ] && [ "$mixin_matches" = "true" ] &&
	[ "$subscriptions_match" = "true" ] && [ "$platform_matches" = "true" ] &&
	[ "$rulesets_match" = "true" ] && [ "$rpcd_timeout_matches" = "true" ]; then
	shortcut_allowed=true
fi

if [ "$shortcut_allowed" = "true" ] && [ "$rulesets_match" = "true" ] && verify_manifest all &&
	{ [ "$was_active" = "true" ] || [ "$netfleet_present" != "true" ]; } &&
	{ [ "$preserve_state" = "1" ] || [ "$was_active" != "true" ]; }; then
	service_before_enabled=0; service_before_running=0
	supervisor_enabled && service_before_enabled=1
	supervisor_running && service_before_running=1
	service_mutated=1; service_restore_mode=flags
	ensure_rpcd_surface || fail_exit rpcd_surface_unavailable
	install_state=already_installed
	ensure_supervisor || fail_exit supervisor_start_failed
	if [ "$identity_matches" != "true" ]; then
		install_identity || fail_exit installed_identity_update_failed
		install_state=payload_reconciled
	fi
	final_active=$(jf "$action_dir/preflight-status.json" '@.result.active')
	[ "$final_active" = "true" ] || final_active=false
	service_mutated=0; service_restore_mode=none
	trap - EXIT
	printf '{"ok":true,"action":"deploy","state":"%s","source_commit":"%s","source_tree":"%s","previous_active":%s,"final_active":%s,"installed_parity":true,"protected_probes":true}\n' \
		"$install_state" "$source_commit" "$source_tree" "$was_active" "$final_active"
	exit 0
fi

if [ "$preserve_state" = "1" ] && [ "$was_active" = "true" ] && [ "$preflight_active" = "true" ] &&
	[ "$netfleet_present" = "true" ] && [ "$policy_matches" = "true" ] && [ "$mixin_matches" = "true" ] &&
	[ "$subscriptions_match" = "true" ] && [ "$platform_matches" = "true" ] && [ "$rulesets_match" = "true" ] &&
	{ [ "$runtime_payload_matches" = "true" ] || [ ! -x "$old_main" ]; }; then
	repair_state=control_plane_repaired
	[ "$runtime_payload_matches" != "true" ] || repair_state=presentation_updated
	snapshot_current || fail_exit rollback_snapshot_failed
	stop_supervisor
	control_plane_repair=1
	install_owned_payload || exit 1
	new_main=$(root_path /usr/libexec/opl-netfleet/main.uc)
	run_action "$new_main" validate "$action_dir/repair-validate.json" || fail_exit installed_validate_failed
	ensure_supervisor || fail_exit supervisor_start_failed
	run_action "$new_main" status "$action_dir/repair-status.json" || fail_exit final_owner_status_failed
	run_action "$new_main" probe "$action_dir/repair-probe.json" || fail_exit protected_probe_failed_after_deploy
	[ "$(jf "$action_dir/repair-status.json" '@.result.active')" = "true" ] || fail_exit final_active_state_mismatch
	install_identity || fail_exit installed_identity_update_failed
	payload_mutated=0
	trap - EXIT
	printf '{"ok":true,"action":"deploy","state":"%s","source_commit":"%s","source_tree":"%s","previous_active":true,"final_active":true,"installed_parity":true,"protected_probes":true,"rollback":"available"}\n' \
		"$repair_state" "$source_commit" "$source_tree"
	exit 0
fi

snapshot_current || fail_exit rollback_snapshot_failed
stop_supervisor

if [ "$was_active" = "true" ] || [ "$netfleet_present" = "true" ]; then
	[ -f "$old_main" ] || fail_exit active_runtime_missing
	run_action "$old_main" disable "$action_dir/disable.json" || fail_exit disable_failed
	! is_netfleet_profile "$(current_profile)" || fail_exit disable_readback_failed
	disable_probe_ok=$(jf "$action_dir/disable.json" '@.result.protected_probes.ok')
	if [ "$instance" != "1" ] && [ "$disable_probe_ok" != "true" ] &&
		! run_action "$old_main" probe "$action_dir/native-probe.json"; then
		if [ "$was_active" = "true" ] &&
			run_action "$old_main" compile "$action_dir/restore-compile.json" &&
			run_action "$old_main" enable "$action_dir/restore-enable.json" &&
			run_action "$old_main" probe "$action_dir/restored-probe.json"; then
			rollback_state=restored_previous_active_profile
		else
			rollback_state=native_probe_failed_previous_runtime_not_restored
		fi
		fail_exit native_baseline_probe_failed
	fi
fi

install_owned_payload || exit 1
install_locked_rulesets || exit 1
install_instance_subscriptions || exit 1
install_declared_mixin || exit 1
install_declared_platform || exit 1
install_declared_policy || exit 1
migrate_evidence_state || fail_exit evidence_migration_failed

new_main=$(root_path /usr/libexec/opl-netfleet/main.uc)
if [ "$instance" = "1" ]; then
	run_action "$new_main" validate-schema "$action_dir/installed-instance-policy.json" "$bundle/policy.json" || fail_exit instance_policy_schema_invalid
fi
run_action "$new_main" validate "$action_dir/validate.json" || fail_exit installed_validate_failed
if [ "$instance" = "1" ] && [ "$preserve_state" = "1" ]; then
	native_before_prepare=$(current_profile)
	restart_mode=""; [ "$instance_native_changed" != "true" ] || restart_mode=restart
	run_action "$new_main" prepare-recovery "$action_dir/prepare-recovery.json" "$native_before_prepare" "$restart_mode" ||
		fail_exit recovery_profile_prepare_failed "$(action_error_detail "$action_dir/prepare-recovery.json")"
fi
run_action "$new_main" compile "$action_dir/compile.json" ||
	fail_exit compile_failed "$(action_error_detail "$action_dir/compile.json")"

expected_active=false
if { [ "$was_active" = "true" ] || [ "$instance" = "1" ]; } && [ "$preserve_state" = "1" ]; then
	expected_active=true
	run_action "$new_main" enable "$action_dir/enable.json" ||
		fail_exit enable_failed "$(action_error_detail "$action_dir/enable.json")"
fi
ensure_supervisor || fail_exit supervisor_start_failed
run_action "$new_main" status "$action_dir/final-status.json" || fail_exit final_owner_status_failed
if [ "$expected_active" = "true" ]; then
	run_action "$new_main" probe "$action_dir/final-probe.json" || fail_exit protected_probe_failed_after_deploy
fi
final_active=$(jf "$action_dir/final-status.json" '@.result.active')
[ "$final_active" = "$expected_active" ] || fail_exit final_active_state_mismatch
verify_manifest all || fail_exit final_installed_parity_failed
if [ "$bundle_schema" = "opl-netfleet-deploy-bundle.v5" ]; then
	installed_lock=$(root_path /etc/opl-netfleet/rulesets.lock.json)
	[ -f "$installed_lock" ] && [ "$(sha_of "$installed_lock")" = "$rulesets_lock_digest" ] &&
		verify_locked_rulesets || fail_exit final_ruleset_parity_failed
fi
[ "$instance" != "1" ] || platform_current_matches || fail_exit final_platform_readback_failed
install_identity || fail_exit installed_identity_update_failed

payload_mutated=0
trap - EXIT
printf '{"ok":true,"action":"deploy","state":"installed","source_commit":"%s","source_tree":"%s","previous_active":%s,"final_active":%s,"instance":%s,"installed_parity":true,"protected_probes":%s,"rollback":"available"}\n' \
	"$source_commit" "$source_tree" "$was_active" "$final_active" "$bundle_instance" "$expected_active"
