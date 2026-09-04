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
		--bundle)
			[ "$#" -ge 2 ] || exit 2
			bundle=$2
			shift 2
			;;
		--preserve-state)
			preserve_state=1
			allow_disable=1
			shift
			;;
		--presentation-only)
			preserve_state=1
			allow_disable=1
			presentation_only=1
			shift
			;;
		--leave-disabled)
			preserve_state=0
			allow_disable=1
			shift
			;;
		--stage-only)
			preserve_state=0
			allow_disable=0
			shift
			;;
		--instance)
			instance=1
			shift
			;;
		*)
			exit 2
			;;
	esac
done

root_prefix=${OPL_NETFLEET_DEPLOY_ROOT:-}
if [ -n "$root_prefix" ]; then
	[ "${OPL_NETFLEET_DEPLOY_TESTING:-}" = "1" ] || exit 2
	case "$root_prefix" in
		/*) ;;
		*) exit 2 ;;
	esac
	[ "$root_prefix" != "/" ] || exit 2
	root_prefix=${root_prefix%/}
fi

root_path() {
	if [ -n "$root_prefix" ]; then
		printf '%s/%s' "$root_prefix" "${1#/}"
	else
		printf '/%s' "${1#/}"
	fi
}

missing_commands() {
	missing=""
	for command in "$@"; do
		if ! command -v "$command" >/dev/null 2>&1; then
			missing="${missing}${missing:+,}${command}"
		fi
	done
	printf '%s' "$missing"
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

	nikki_repository=https://nikkinikki.pages.dev
	nikki_feed="$nikki_repository/$nikki_branch/$DISTRIB_ARCH/nikki/packages.adb"
	nikki_key=/etc/apk/keys/nikki.pem
	nikki_key_tmp="$nikki_key.opl-netfleet.$$"
	nikki_key_sha256=677ef1af372065e2e856175363e2da9471a6c5c6443563b912c8d325bfa1fbad
	if [ ! -f "$nikki_key" ] ||
		[ "$(sha256sum "$nikki_key" | awk '{print $1}')" != "$nikki_key_sha256" ]; then
		if ! curl -fsSL --connect-timeout 10 --max-time 30 \
			-o "$nikki_key_tmp" "$nikki_repository/public-key.pem"; then
			rm -f "$nikki_key_tmp"
			return 1
		fi
		if [ "$(sha256sum "$nikki_key_tmp" | awk '{print $1}')" != "$nikki_key_sha256" ]; then
			rm -f "$nikki_key_tmp"
			return 1
		fi
		mv -f "$nikki_key_tmp" "$nikki_key"
	fi

	nikki_feed_file=/etc/apk/repositories.d/customfeeds.list
	mkdir -p "$(dirname "$nikki_feed_file")"
	touch "$nikki_feed_file"
	if ! grep -Fqx "$nikki_feed" "$nikki_feed_file"; then
		nikki_feed_tmp="$nikki_feed_file.opl-netfleet.$$"
		awk '!/^https:\/\/nikkinikki\.pages\.dev\/.*\/nikki\/packages\.adb$/' \
			"$nikki_feed_file" >"$nikki_feed_tmp"
		printf '%s\n' "$nikki_feed" >>"$nikki_feed_tmp"
		mv -f "$nikki_feed_tmp" "$nikki_feed_file"
	fi
}

bootstrap_instance_dependencies() {
	missing=$(missing_commands curl flock jsonfilter mihomo ucode yq)
	nikki_init=$(root_path /etc/init.d/nikki)
	if [ -z "$missing" ] && [ -x "$nikki_init" ]; then
		return 0
	fi
	dependency_detail=$missing
	[ -x "$nikki_init" ] || dependency_detail="${dependency_detail}${dependency_detail:+,}nikki_service"
	[ "$instance" = "1" ] || {
		error_code=target_dependencies_missing
		error_detail=$dependency_detail
		return 1
	}
	[ -z "$root_prefix" ] || {
		error_code=unsupported_target
		error_detail=$dependency_detail
		return 1
	}
	if command -v apk >/dev/null 2>&1; then
		if ! apk --timeout 300 update >/dev/null 2>&1; then
			error_code=dependency_bootstrap_failed
			error_detail=$missing
			return 1
		fi
		# FriendlyWrt images can retain vendor packages that are intentionally
		# absent from their current feeds. apk may install every requested package
		# and still return non-zero for that unrelated world warning, so the
		# executable postcondition is authoritative here.
		apk --timeout 300 add ucode yq curl jsonfilter >/dev/null 2>&1 || true
		core_missing=$(missing_commands curl flock jsonfilter ucode yq)
		if [ -n "$core_missing" ]; then
			error_code=dependency_bootstrap_failed
			error_detail=$core_missing
			return 1
		fi
		if [ ! -x "$nikki_init" ] || ! command -v mihomo >/dev/null 2>&1; then
			if ! configure_nikki_apk_feed; then
				error_code=dependency_bootstrap_failed
				error_detail=nikki_feed
				return 1
			fi
			if ! apk --timeout 300 update >/dev/null 2>&1; then
				error_code=dependency_bootstrap_failed
				error_detail=nikki_packages
				return 1
			fi
			apk --timeout 300 add nikki luci-app-nikki mihomo-meta >/dev/null 2>&1 || true
			if [ ! -x "$nikki_init" ] || ! command -v mihomo >/dev/null 2>&1; then
				error_code=dependency_bootstrap_failed
				error_detail=nikki_packages
				return 1
			fi
		fi
	elif command -v opkg >/dev/null 2>&1; then
		if ! opkg update >/dev/null 2>&1 ||
			! opkg install nikki luci-app-nikki mihomo ucode yq curl jsonfilter flock >/dev/null 2>&1; then
			error_code=dependency_bootstrap_failed
			error_detail=$missing
			return 1
		fi
	else
		error_code=unsupported_target
		error_detail="package_manager,$missing"
		return 1
	fi
	missing=$(missing_commands curl flock jsonfilter mihomo ucode yq)
	if [ -n "$missing" ] || [ ! -x "$nikki_init" ]; then
		error_code=dependency_bootstrap_incomplete
		error_detail=${missing:-nikki_service}
		return 1
	fi
}

current_profile() {
	uci -q get nikki.config.profile 2>/dev/null || true
}

active_profile='file:OPL-NetFleet.json'
legacy_active_profile='file:opl-netfleet/mvp.json'
is_netfleet_profile() {
	[ "$1" = "$active_profile" ] || [ "$1" = "$legacy_active_profile" ]
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
external_state_paths="etc/config/rpcd"
subscriptions_match=true
default_placeholder_present=false
platform_matches=true
platform_changed=false
rulesets_match=false
rulesets_changed=false

emit_failure() {
	profile=$(current_profile)
	recovery=not_needed
	case "$rollback_state" in
		active_profile_not_recoverable|original_*_not_recoverable|restore_failed)
			recovery=needs_local_recovery
			;;
	esac
	case "$profile" in
		*[!A-Za-z0-9:._/-]*) profile=unavailable ;;
	esac
	case "$error_detail" in
		*[!A-Za-z0-9_,.:-]*) error_detail=unavailable ;;
	esac
	printf '{"ok":false,"action":"deploy","error":"%s","detail":"%s","source_commit":"%s","source_tree":"%s","previous_active":%s,"profile":"%s","rollback":"%s","recovery":"%s"}\n' \
		"$error_code" "$error_detail" "$source_commit" "$source_tree" "$was_active" "$profile" "$rollback_state" "$recovery"
}

owned_paths='usr/libexec/opl-netfleet
usr/libexec/rpcd/opl-netfleet
etc/init.d/opl-netfleet
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

# Snapshot only the state files, never /var or /var/lib themselves. The old
# evidence path is retained solely for one-time migration and rollback.
runtime_state_paths='etc/opl-netfleet/evidence.json
var/lib/opl-netfleet/evidence.json
var/lib/opl-netfleet/events.json'

supervisor_init() {
	root_path /etc/init.d/opl-netfleet
}

supervisor_enabled() {
	init=$(supervisor_init)
	[ -x "$init" ] && "$init" enabled >/dev/null 2>&1
}

supervisor_running() {
	init=$(supervisor_init)
	[ -x "$init" ] && "$init" status >/dev/null 2>&1
}

stop_supervisor() {
	init=$(supervisor_init)
	if [ -x "$init" ]; then
		service_mutated=1
		service_restore_mode=rollback
		"$init" stop >/dev/null 2>&1 || true
	fi
}

restore_supervisor_flags() {
	target_enabled=$1
	target_running=$2
	init=$(supervisor_init)
	[ -x "$init" ] || return 0
	if [ "$target_enabled" = "1" ]; then
		"$init" enable >/dev/null 2>&1 || return 1
	else
		"$init" disable >/dev/null 2>&1 || return 1
	fi
	if [ "$target_running" = "1" ]; then
		"$init" restart >/dev/null 2>&1 || return 1
	else
		"$init" stop >/dev/null 2>&1 || return 1
	fi
}

ensure_supervisor() {
	init=$(supervisor_init)
	[ -x "$init" ] || return 1
	ensure_before_enabled=0
	ensure_before_running=0
	supervisor_enabled && ensure_before_enabled=1
	supervisor_running && ensure_before_running=1
	if ! "$init" enable >/dev/null 2>&1 ||
		{ ! "$init" status >/dev/null 2>&1 && ! "$init" start >/dev/null 2>&1; } ||
		! "$init" enabled >/dev/null 2>&1 || ! "$init" status >/dev/null 2>&1; then
		restore_supervisor_flags "$ensure_before_enabled" "$ensure_before_running" || true
		return 1
	fi
}

restore_supervisor_state() {
	target_enabled=0
	target_running=0
	if [ -f "$rollback_dir/supervisor-enabled" ]; then
		target_enabled=1
	fi
	if [ -f "$rollback_dir/supervisor-running" ]; then
		target_running=1
	fi
	restore_supervisor_flags "$target_enabled" "$target_running"
}

remove_snapshot_paths() {
	init=$(supervisor_init)
	if [ -x "$init" ]; then
		"$init" stop >/dev/null 2>&1 || true
		"$init" disable >/dev/null 2>&1 || true
	fi
	for rel in $owned_paths $state_paths $external_state_paths; do
		rm -rf -- "$(root_path "/$rel")"
	done
	for rel in $runtime_state_paths; do
		rm -rf -- "$(root_path "/$rel")"
	done
}

restore_paths_from_snapshot() {
	restore_paths=$1
	restore_stage="$rollback_dir/restore.$$"
	rm -rf -- "$restore_stage" || return 1
	mkdir -p "$restore_stage" || return 1
	if ! tar -C "$restore_stage" -xf "$rollback_dir/snapshot.tar"; then
		rm -rf -- "$restore_stage"
		return 1
	fi
	for restore_rel in $restore_paths; do
		restore_target=$(root_path "/$restore_rel")
		rm -rf -- "$restore_target" || {
			rm -rf -- "$restore_stage"
			return 1
		}
		if [ -f "$rollback_dir/absent" ] && grep -Fqx "$restore_rel" "$rollback_dir/absent"; then
			continue
		fi
		restore_source="$restore_stage/$restore_rel"
		if { [ ! -e "$restore_source" ] && [ ! -L "$restore_source" ]; } ||
			! mkdir -p "$(dirname "$restore_target")" ||
			! cp -a "$restore_source" "$restore_target"; then
			rm -rf -- "$restore_stage"
			return 1
		fi
	done
	rm -rf -- "$restore_stage"
}

restore_snapshot_bytes() {
	[ -f "$rollback_dir/snapshot.tar" ] || return 1
	remove_snapshot_paths
	restore_paths_from_snapshot "$owned_paths $state_paths $external_state_paths $runtime_state_paths" || return 1
	rpcd_init=$(root_path /etc/init.d/rpcd)
	[ ! -x "$rpcd_init" ] || "$rpcd_init" reload >/dev/null 2>&1 || true
	uhttpd_init=$(root_path /etc/init.d/uhttpd)
	[ ! -x "$uhttpd_init" ] || "$uhttpd_init" restart >/dev/null 2>&1 || true
	firewall_init=$(root_path /etc/init.d/firewall)
	[ ! -x "$firewall_init" ] || "$firewall_init" reload >/dev/null 2>&1 || true
}

restore_snapshot() {
	restore_snapshot_bytes || return 1
	restore_supervisor_state
}

restore_control_plane_snapshot() {
	[ -f "$rollback_dir/snapshot.tar" ] || return 1
	init=$(supervisor_init)
	if [ -x "$init" ]; then
		"$init" stop >/dev/null 2>&1 || true
		"$init" disable >/dev/null 2>&1 || true
	fi
	restore_paths_from_snapshot "$owned_paths" || return 1
	rpcd_init=$(root_path /etc/init.d/rpcd)
	[ ! -x "$rpcd_init" ] || "$rpcd_init" reload >/dev/null 2>&1 || true
	uhttpd_init=$(root_path /etc/init.d/uhttpd)
	[ ! -x "$uhttpd_init" ] || "$uhttpd_init" restart >/dev/null 2>&1 || true
	restore_supervisor_state
}

rpcd_surface_ready() {
	luci_methods=$(ubus -v list luci 2>/dev/null || true)
	printf '%s\n' "$luci_methods" | grep -q '"getFeatures":' || return 1

	methods=$(ubus -v list opl-netfleet 2>/dev/null || true)
	for method in status events connections probe config_get config_validate config_save config_apply enable select_auto refresh disable; do
		printf '%s\n' "$methods" | grep -q "\"$method\":" || return 1
	done
}

rpcd_timeout_ready() {
	value=$(uci -q get rpcd.@rpcd[0].timeout 2>/dev/null || true)
	case "$value" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "$value" -ge 300 ]
}

luci_http_surface_ready() {
	session_json=$(ubus call session create '{"timeout":30}' 2>/dev/null) || return 1
	session_id=$(jsonfilter -s "$session_json" -e '@.ubus_rpc_session' 2>/dev/null || true)
	[ "${#session_id}" -eq 32 ] || return 1
	case "$session_id" in
		''|*[!0-9a-fA-F]*) return 1 ;;
	esac
	session_payload=$(printf '{"ubus_rpc_session":"%s"}' "$session_id")
	grant_payload=$(printf '{"ubus_rpc_session":"%s","scope":"ubus","objects":[["luci","getFeatures"]]}' "$session_id")
	if ! ubus call session grant "$grant_payload" >/dev/null 2>&1; then
		ubus call session destroy "$session_payload" >/dev/null 2>&1 || true
		return 1
	fi
	request=$(printf '{"jsonrpc":"2.0","id":1,"method":"call","params":["%s","luci","getFeatures",{}]}' "$session_id")
	response=$(curl -fsS --connect-timeout 2 --max-time 5 \
		-H 'Content-Type: application/json' -d "$request" http://127.0.0.1/ubus 2>/dev/null || true)
	ubus call session destroy "$session_payload" >/dev/null 2>&1 || true
	result_code=$(jsonfilter -s "$response" -e '@.result[0]' 2>/dev/null || true)
	[ "$result_code" = "0" ]
}

restart_uhttpd_for_rpc() {
	uhttpd_init=$(root_path /etc/init.d/uhttpd)
	[ -x "$uhttpd_init" ] || return 1
	"$uhttpd_init" restart >/dev/null 2>&1 || return 1
	for attempt in 1 2 3 4; do
		if luci_http_surface_ready; then
			return 0
		fi
		[ "$attempt" -eq 4 ] || sleep 1
	done
	return 1
}

ensure_rpcd_surface() {
	force_restart=${1:-false}
	restart_required=$force_restart
	if ! rpcd_timeout_ready; then
		uci set rpcd.@rpcd[0].timeout=300 >/dev/null 2>&1 &&
			uci commit rpcd >/dev/null 2>&1 || return 1
		restart_required=true
	fi
	if [ "$restart_required" = "false" ] && rpcd_surface_ready; then
		luci_http_surface_ready && return 0
		restart_uhttpd_for_rpc
		return $?
	fi
	rpcd_init=$(root_path /etc/init.d/rpcd)
	[ -x "$rpcd_init" ] || return 1
	"$rpcd_init" restart >/dev/null 2>&1 || return 1
	local_surface_ready=false
	for attempt in 1 2 3 4; do
		if ubus call system board >/dev/null 2>&1 && rpcd_timeout_ready && rpcd_surface_ready; then
			local_surface_ready=true
			luci_http_surface_ready && return 0
			break
		fi
		[ "$attempt" -eq 4 ] || sleep 1
	done
	[ "$local_surface_ready" = "true" ] || return 1
	restart_uhttpd_for_rpc
}

verify_installed_files() {
	while read -r expected rel extra; do
		[ -n "$expected" ] || continue
		[ -z "${extra:-}" ] || return 1
		case "$rel" in
			/*|*../*|*' '*) return 1 ;;
		esac
		target=$(root_path "/$rel")
		[ -f "$target" ] || { error_detail="missing:$rel"; return 1; }
		actual=$(sha256sum "$target" | awk '{print $1}')
		[ "$actual" = "$expected" ] || { error_detail="digest:$rel"; return 1; }
	done <"$bundle/FILES.sha256"
}

verify_installed_runtime_files() {
	while read -r expected rel extra; do
		[ -n "$expected" ] || continue
		[ -z "${extra:-}" ] || return 1
		case "$rel" in
			/*|*../*|*' '*) return 1 ;;
			www/luci-static/resources/netfleet/*|\
			www/luci-static/resources/view/netfleet/*|\
			usr/share/luci/menu.d/luci-app-netfleet.json|\
			usr/share/rpcd/acl.d/luci-app-netfleet.json)
				continue
				;;
		esac
		target=$(root_path "/$rel")
		[ -f "$target" ] || return 1
		actual=$(sha256sum "$target" | awk '{print $1}')
		[ "$actual" = "$expected" ] || return 1
	done <"$bundle/FILES.sha256"
}

current_runtime_payload_digest() {
	runtime_manifest="$action_dir/runtime-files.sha256"
	: >"$runtime_manifest"
	while read -r expected rel extra; do
		[ -n "$expected" ] || continue
		[ -z "${extra:-}" ] || return 1
		case "$rel" in
			/*|*../*|*' '*) return 1 ;;
			www/luci-static/resources/netfleet/*|\
			www/luci-static/resources/view/netfleet/*|\
			usr/share/luci/menu.d/luci-app-netfleet.json|\
			usr/share/rpcd/acl.d/luci-app-netfleet.json)
				continue
				;;
		esac
		printf '%s  %s\n' "$expected" "$rel" >>"$runtime_manifest"
	done <"$bundle/FILES.sha256"
	sha256sum "$runtime_manifest" | awk '{print $1}'
}

json_semantically_equal() {
	left=$1
	right=$2
	[ -f "$left" ] && [ -f "$right" ] || return 1
	ucode - "$left" "$right" >/dev/null 2>&1 <<'UCODE'
import { readfile } from "fs";

function same(left, right) {
	if (type(left) != type(right)) return false;
	if (type(left) == "array") {
		if (length(left) != length(right)) return false;
		for (let i = 0; i < length(left); i++) {
			if (!same(left[i], right[i])) return false;
		}
		return true;
	}
	if (type(left) == "object") {
		const left_keys = keys(left);
		const right_keys = keys(right);
		if (length(left_keys) != length(right_keys)) return false;
		for (let i = 0; i < length(left_keys); i++) {
			const key = left_keys[i];
			if (index(right_keys, key) < 0 || !same(left[key], right[key])) return false;
		}
		return true;
	}
	return left == right;
}

try {
	exit(same(json(readfile(ARGV[0])), json(readfile(ARGV[1]))) ? 0 : 1);
} catch (error) {
	exit(1);
}
UCODE
}

yaml_semantically_equal() {
	left=$1
	right=$2
	left_json="$action_dir/yaml-left.$$.json"
	right_json="$action_dir/yaml-right.$$.json"
	if ! yq -M -p yaml -o json "$left" >"$left_json" 2>/dev/null ||
		! yq -M -p yaml -o json "$right" >"$right_json" 2>/dev/null; then
		rm -f -- "$left_json" "$right_json"
		return 1
	fi
	if json_semantically_equal "$left_json" "$right_json"; then
		rm -f -- "$left_json" "$right_json"
		return 0
	fi
	rm -f -- "$left_json" "$right_json"
	return 1
}

install_identity() {
	mkdir -p "$(dirname "$installed_identity")"
	cp "$bundle/bundle.json" "${installed_identity}.tmp" || return 1
	chmod 0644 "${installed_identity}.tmp" || return 1
	mv -f "${installed_identity}.tmp" "$installed_identity"
}

install_owned_payload() {
	payload_mutated=1
	if [ "$release_mode" = "package" ]; then
		install_release_packages || return 1
		if ! verify_installed_files; then
			error_code=installed_parity_failed
			return 1
		fi
		if ! ensure_rpcd_surface; then
			error_code=rpcd_surface_unavailable
			return 1
		fi
		return 0
	fi
	candidate_menu="$candidate_dir/usr/share/luci/menu.d/luci-app-netfleet.json"
	installed_menu=$(root_path /usr/share/luci/menu.d/luci-app-netfleet.json)
	luci_menu_changed=true
	if [ -f "$candidate_menu" ] && [ -f "$installed_menu" ] && cmp -s "$candidate_menu" "$installed_menu"; then
		luci_menu_changed=false
	fi
	for rel in $owned_paths; do
		rm -rf -- "$(root_path "/$rel")"
	done
	[ -d "$candidate_dir" ] || { error_code=payload_install_failed; return 1; }
	for rel in $owned_paths; do
		source="$candidate_dir/$rel"
		if [ ! -e "$source" ] && [ ! -L "$source" ]; then
			continue
		fi
		target=$(root_path "/$rel")
		if ! mkdir -p "$(dirname "$target")" || ! cp -a "$source" "$target"; then
			error_code=payload_install_failed
			return 1
		fi
	done
	if [ "$luci_menu_changed" = "true" ]; then
		luci_tmp=$(root_path /tmp)
		rm -f "$luci_tmp"/luci-indexcache.*
		rm -rf "$luci_tmp/luci-modulecache"
	fi
	if ! verify_installed_files; then
		error_code=installed_parity_failed
		return 1
	fi
	if ! ensure_rpcd_surface "$luci_menu_changed"; then
		error_code=rpcd_surface_unavailable
		return 1
	fi
}

install_release_packages() {
	package_manifest="$bundle/package-manifest.json"
	package_key=$(jsonfilter -i "$package_manifest" -e '@.apk_public_key.name' 2>/dev/null || true)
	package_arch=$(jsonfilter -i "$package_manifest" -e '@.package_arch' 2>/dev/null || true)
	if [ "$release_format" = "apk" ]; then
		command -v apk >/dev/null 2>&1 || { error_code=package_manager_unavailable; return 1; }
		target_arch=$(apk --print-arch 2>/dev/null || true)
		arch_compatible=false
		[ "$package_arch" = "noarch" ] && arch_compatible=true
		[ "$target_arch" = "$package_arch" ] && arch_compatible=true
		[ "$package_arch" = "aarch64_generic" ] && [ "$target_arch" = "aarch64" ] && arch_compatible=true
		[ "$arch_compatible" = true ] || { error_code=package_arch_mismatch; error_detail=$target_arch; return 1; }
		[ -n "$package_key" ] && [ -f "$bundle/$package_key" ] || { error_code=package_key_missing; return 1; }
		mkdir -p "$(root_path /etc/apk/keys)"
		key_target=$(root_path "/etc/apk/keys/$package_key")
		if [ -f "$key_target" ] && [ "$(sha256sum "$key_target" | awk '{print $1}')" != "$(sha256sum "$bundle/$package_key" | awk '{print $1}')" ]; then
			error_code=package_key_conflict
			return 1
		fi
		cp "$bundle/$package_key" "${key_target}.tmp.$$" || { error_code=package_key_install_failed; return 1; }
		chmod 0644 "${key_target}.tmp.$$" && mv -f "${key_target}.tmp.$$" "$key_target" || { rm -f "${key_target}.tmp.$$"; error_code=package_key_install_failed; return 1; }
		apk_args="--no-network --repositories-file /dev/null"
		package_files=""
		for package_name in opl-netfleet luci-app-netfleet; do
			package_file=$(jsonfilter -i "$package_manifest" -e "@.artifact_files[\"$package_name\"]" 2>/dev/null || true)
			[ -n "$package_file" ] && [ -f "$bundle/$package_file" ] || { error_code=package_file_missing; return 1; }
			package_files="$package_files $bundle/$package_file"
		done
		# Install the pair in one apk transaction to avoid a second process,
		# database lock and dependency-resolution pass.
		if ! apk $apk_args add $package_files >/dev/null 2>&1; then
			error_code=package_install_failed
			return 1
		fi
		return 0
	fi
	if [ "$release_format" = "ipk" ]; then
		command -v opkg >/dev/null 2>&1 || { error_code=package_manager_unavailable; return 1; }
		package_files=""
		for package_name in opl-netfleet luci-app-netfleet; do
			package_file=$(jsonfilter -i "$package_manifest" -e "@.artifact_files[\"$package_name\"]" 2>/dev/null || true)
			[ -n "$package_file" ] && [ -f "$bundle/$package_file" ] || { error_code=package_file_missing; return 1; }
			package_files="$package_files $bundle/$package_file"
		done
		if ! opkg install $package_files >/dev/null 2>&1; then
			error_code=package_install_failed
			return 1
		fi
		return 0
	fi
	error_code=package_release_invalid
	return 1
}

native_owner_ready() {
	expected=$1
	nikki_init=$(root_path /etc/init.d/nikki)
	[ -x "$nikki_init" ] &&
		[ "$(current_profile)" = "$expected" ] &&
		ubus call system board >/dev/null 2>&1 &&
		[ "$("$nikki_init" status 2>/dev/null || true)" = "running" ] &&
		pidof mihomo >/dev/null 2>&1
}

run_action() {
	main=$1
	action=$2
	output=$3
	shift 3
	if ucode "$main" "$action" "$@" >"$output" 2>"$output.stderr" &&
		[ "$(jsonfilter -i "$output" -e '@.ok' 2>/dev/null || true)" = "true" ]; then
		return 0
	fi
	return 1
}

action_error_detail() {
	output=$1
	action_error=$(jsonfilter -i "$output" -e '@.error' 2>/dev/null || true)
	if [ "$action_error" = "unexpected_error" ]; then
		detail=unexpected_error_lines
		found=false
		for index in 0 1 2 3 4; do
			line=$(jsonfilter -i "$output" -e "@.detail.unexpected_stacktrace[$index].line" 2>/dev/null || true)
			case "$line" in
				''|*[!0-9]*) continue ;;
			esac
			detail="${detail}_$line"
			found=true
		done
		if [ "$found" = "true" ]; then
			printf '%s\n' "$detail"
			return 0
		fi
	fi
	printf '%s\n' "$action_error"
}

install_declared_policy() {
	[ "$instance" = "1" ] || return 0
	source=$bundle/policy.json
	target=$(root_path /etc/opl-netfleet/policy.json)
	temporary="${target}.tmp.$$"
	expected=$(jsonfilter -i "$bundle/bundle.json" -e '@.policy_sha256' 2>/dev/null || true)
	mkdir -p "$(dirname "$target")"
	if ! cp "$source" "$temporary" || ! chmod 0600 "$temporary" ||
		[ "$(sha256sum "$temporary" | awk '{print $1}')" != "$expected" ] ||
		! mv -f "$temporary" "$target"; then
		rm -f -- "$temporary"
		error_code=policy_install_failed
		return 1
	fi
}

install_declared_mixin() {
	[ "$instance" = "1" ] || return 0
	source=$bundle/nikki-mixin.yaml
	target=$(root_path /etc/nikki/mixin.yaml)
	temporary="${target}.tmp.$$"
	expected=$(jsonfilter -i "$bundle/bundle.json" -e '@.nikki_mixin_sha256' 2>/dev/null || true)
	mkdir -p "$(dirname "$target")"
	if ! yq -M -p yaml -o json "$source" >/dev/null 2>&1 ||
		! cp "$source" "$temporary" || ! chmod 0644 "$temporary" ||
		[ "$(sha256sum "$temporary" | awk '{print $1}')" != "$expected" ] ||
		! mv -f "$temporary" "$target" ||
		! uci set nikki.mixin.mixin_file_content=1 || ! uci commit nikki; then
		rm -f -- "$temporary"
		error_code=nikki_mixin_install_failed
		return 1
	fi
}

platform_value() {
	jsonfilter -i "$bundle/platform.json" -e "@.nikki.$1" 2>/dev/null || true
}

platform_bool() {
	value=$(platform_value "$1")
	case "$value" in
		true) printf '1' ;;
		false) printf '0' ;;
		*) return 1 ;;
	esac
}

platform_openwrt_bool() {
	value=$(jsonfilter -i "$bundle/platform.json" -e "@.openwrt.$1" 2>/dev/null || true)
	case "$value" in
		true) printf '1' ;;
		false) printf '0' ;;
		*) return 1 ;;
	esac
}

platform_option_matches() {
	section=$1
	option=$2
	field=$3
	kind=$4
	if [ "$kind" = "bool" ]; then
		expected=$(platform_bool "$field") || return 1
	else
		expected=$(platform_value "$field")
	fi
	[ "$(uci -q get "nikki.$section.$option" 2>/dev/null || true)" = "$expected" ]
}

platform_current_matches() {
	platform_option_matches config scheduled_restart scheduled_restart bool &&
		platform_option_matches config test_profile test_profile bool &&
		platform_option_matches procd fast_reload fast_reload bool &&
		platform_option_matches mixin api_listen api_listen string &&
		platform_option_matches mixin allow_lan allow_lan bool &&
		platform_option_matches mixin selection_cache selection_cache bool &&
		platform_option_matches mixin log_level log_level string &&
		platform_option_matches log clear_at_stop log_clear_at_stop bool &&
		platform_option_matches mixin ipv6 ipv6 bool &&
		platform_option_matches mixin unify_delay unified_delay bool &&
		platform_option_matches mixin tcp_concurrent tcp_concurrent bool &&
		platform_option_matches mixin tun_enabled tun_enabled bool &&
		platform_option_matches mixin dns_enabled dns_enabled bool &&
		platform_option_matches mixin dns_cache_algorithm dns_cache_algorithm string &&
		platform_option_matches mixin dns_ipv6 dns_ipv6 bool &&
		platform_option_matches mixin dns_mode dns_mode string &&
		platform_option_matches mixin fake_ip_cache fake_ip_cache bool &&
		platform_option_matches mixin sniffer sniffer_enabled bool &&
		platform_option_matches mixin sniffer_sniff_dns_mapping sniffer_force_dns_mapping bool &&
		platform_option_matches mixin sniffer_sniff_pure_ip sniffer_parse_pure_ip bool &&
		[ "$(uci -q get nikki.mixin.sniffer_sniff 2>/dev/null || true)" = "1" ] &&
		platform_option_matches proxy tcp_mode tcp_mode string &&
		platform_option_matches proxy udp_mode udp_mode string &&
		platform_option_matches proxy ipv4_dns_hijack ipv4_dns_hijack bool &&
		platform_option_matches proxy ipv6_dns_hijack ipv6_dns_hijack bool &&
		platform_option_matches proxy ipv4_proxy ipv4_proxy bool &&
		platform_option_matches proxy ipv6_proxy ipv6_proxy bool &&
		platform_option_matches proxy fake_ip_ping_hijack fake_ip_ping_hijack bool &&
		platform_option_matches proxy bypass_china_mainland_ip bypass_china_mainland_ip bool &&
		platform_option_matches proxy bypass_china_mainland_ip6 bypass_china_mainland_ip6 bool &&
		[ "$(uci -q get nikki.@sniff[0].protocol 2>/dev/null || true)" = "HTTP" ] &&
		[ "$(uci -q get nikki.@sniff[1].protocol 2>/dev/null || true)" = "TLS" ] &&
		[ "$(uci -q get nikki.@sniff[2].protocol 2>/dev/null || true)" = "QUIC" ] &&
		[ "$(uci -q get nikki.@sniff[0].overwrite_destination 2>/dev/null || true)" = "$(platform_bool sniffer_override_destination)" ] &&
		[ "$(uci -q get nikki.@sniff[1].overwrite_destination 2>/dev/null || true)" = "$(platform_bool sniffer_override_destination)" ] &&
		[ "$(uci -q get nikki.@sniff[2].overwrite_destination 2>/dev/null || true)" = "$(platform_bool sniffer_override_destination)" ] &&
		[ "$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null || true)" = "$(platform_openwrt_bool software_flow_offload)" ] &&
		[ "$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null || true)" = "$(platform_openwrt_bool hardware_flow_offload)" ]
}

set_platform_option() {
	section=$1
	option=$2
	field=$3
	kind=$4
	if [ "$kind" = "bool" ]; then
		value=$(platform_bool "$field") || return 1
	else
		value=$(platform_value "$field")
	fi
	uci set "nikki.$section.$option=$value"
}

install_declared_platform() {
	[ "$instance" = "1" ] || return 0
	[ "$platform_matches" != "true" ] || return 0
	override=$(platform_bool sniffer_override_destination) || { error_code=platform_config_failed; return 1; }
	set_platform_option config scheduled_restart scheduled_restart bool &&
		set_platform_option config test_profile test_profile bool &&
		set_platform_option procd fast_reload fast_reload bool &&
		set_platform_option mixin api_listen api_listen string &&
		set_platform_option mixin allow_lan allow_lan bool &&
		set_platform_option mixin selection_cache selection_cache bool &&
		set_platform_option mixin log_level log_level string &&
		set_platform_option log clear_at_stop log_clear_at_stop bool &&
		set_platform_option mixin ipv6 ipv6 bool &&
		set_platform_option mixin unify_delay unified_delay bool &&
		set_platform_option mixin tcp_concurrent tcp_concurrent bool &&
		set_platform_option mixin tun_enabled tun_enabled bool &&
		set_platform_option mixin dns_enabled dns_enabled bool &&
		set_platform_option mixin dns_cache_algorithm dns_cache_algorithm string &&
		set_platform_option mixin dns_ipv6 dns_ipv6 bool &&
		set_platform_option mixin dns_mode dns_mode string &&
		set_platform_option mixin fake_ip_cache fake_ip_cache bool &&
		set_platform_option mixin sniffer sniffer_enabled bool &&
		set_platform_option mixin sniffer_sniff_dns_mapping sniffer_force_dns_mapping bool &&
		set_platform_option mixin sniffer_sniff_pure_ip sniffer_parse_pure_ip bool &&
		uci set nikki.mixin.sniffer_sniff=1 &&
		set_platform_option proxy tcp_mode tcp_mode string &&
		set_platform_option proxy udp_mode udp_mode string &&
		set_platform_option proxy ipv4_dns_hijack ipv4_dns_hijack bool &&
		set_platform_option proxy ipv6_dns_hijack ipv6_dns_hijack bool &&
		set_platform_option proxy ipv4_proxy ipv4_proxy bool &&
		set_platform_option proxy ipv6_proxy ipv6_proxy bool &&
		set_platform_option proxy fake_ip_ping_hijack fake_ip_ping_hijack bool &&
		set_platform_option proxy bypass_china_mainland_ip bypass_china_mainland_ip bool &&
		set_platform_option proxy bypass_china_mainland_ip6 bypass_china_mainland_ip6 bool &&
		[ "$(uci -q get nikki.@sniff[0].protocol 2>/dev/null || true)" = "HTTP" ] &&
		[ "$(uci -q get nikki.@sniff[1].protocol 2>/dev/null || true)" = "TLS" ] &&
		[ "$(uci -q get nikki.@sniff[2].protocol 2>/dev/null || true)" = "QUIC" ] &&
		uci set "nikki.@sniff[0].overwrite_destination=$override" &&
		uci set "nikki.@sniff[1].overwrite_destination=$override" &&
		uci set "nikki.@sniff[2].overwrite_destination=$override" &&
		uci commit nikki || { error_code=platform_config_failed; return 1; }
	software=$(platform_openwrt_bool software_flow_offload) || { error_code=platform_config_failed; return 1; }
	hardware=$(platform_openwrt_bool hardware_flow_offload) || { error_code=platform_config_failed; return 1; }
	if [ "$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null || true)" != "$software" ] ||
		[ "$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null || true)" != "$hardware" ]; then
		uci set "firewall.@defaults[0].flow_offloading=$software" &&
			uci set "firewall.@defaults[0].flow_offloading_hw=$hardware" &&
			uci commit firewall || { error_code=platform_config_failed; return 1; }
		firewall_init=$(root_path /etc/init.d/firewall)
		[ -x "$firewall_init" ] && "$firewall_init" reload >/dev/null 2>&1 || {
			error_code=platform_firewall_reload_failed
			return 1
		}
	fi
	platform_current_matches || { error_code=platform_readback_failed; return 1; }
	platform_changed=true
}

subscription_value() {
	index=$1
	field=$2
	jsonfilter -i "$bundle/subscriptions.json" -e "@.subscriptions[$index].$field" 2>/dev/null || true
}

validate_instance_inputs() {
	[ "$instance" = "1" ] || return 0
	platform_schema=$(jsonfilter -i "$bundle/platform.json" -e '@.schema_version' 2>/dev/null || true)
	platform_target=$(jsonfilter -i "$bundle/platform.json" -e '@.target' 2>/dev/null || true)
	policy_target=$(jsonfilter -i "$bundle/policy.json" -e '@.main.target' 2>/dev/null || true)
	if [ "$platform_schema" != "1" ] || [ -z "$policy_target" ] || [ "$platform_target" != "$policy_target" ] ||
		[ "$(platform_value api_listen)" != "0.0.0.0:9090" ] ||
		[ "$(platform_value dns_mode)" != "redir-host" ] ||
		[ "$(platform_value tcp_mode)" != "tproxy" ] ||
		[ "$(platform_value udp_mode)" != "tproxy" ] ||
		[ "$(platform_bool api_secret_required 2>/dev/null || true)" != "1" ] ||
		[ "$(platform_bool allow_lan 2>/dev/null || true)" != "1" ] ||
		[ "$(platform_bool tun_enabled 2>/dev/null || true)" != "0" ] ||
		[ "$(platform_bool fake_ip_cache 2>/dev/null || true)" != "0" ] ||
		[ "$(platform_bool sniffer_override_destination 2>/dev/null || true)" != "0" ] ||
		[ "$(platform_openwrt_bool software_flow_offload 2>/dev/null || true)" != "0" ] ||
		[ "$(platform_openwrt_bool hardware_flow_offload 2>/dev/null || true)" != "0" ]; then
		error_code=instance_platform_schema_invalid
		return 1
	fi
	for field in scheduled_restart test_profile fast_reload api_secret_required allow_lan selection_cache log_clear_at_stop ipv6 unified_delay tcp_concurrent tun_enabled dns_enabled dns_ipv6 fake_ip_cache sniffer_enabled sniffer_force_dns_mapping sniffer_parse_pure_ip sniffer_override_destination ipv4_dns_hijack ipv6_dns_hijack ipv4_proxy ipv6_proxy fake_ip_ping_hijack bypass_china_mainland_ip bypass_china_mainland_ip6; do
		platform_bool "$field" >/dev/null || { error_code=instance_platform_schema_invalid; error_detail=$field; return 1; }
	done
	for field in api_listen log_level dns_cache_algorithm dns_mode tcp_mode udp_mode; do
		[ -n "$(platform_value "$field")" ] || { error_code=instance_platform_schema_invalid; error_detail=$field; return 1; }
	done
	if [ "$(platform_bool api_secret_required)" = "1" ] && [ -z "$(uci -q get nikki.mixin.api_secret 2>/dev/null || true)" ]; then
		error_code=instance_platform_secret_missing
		return 1
	fi
	platform_matches=false
	platform_current_matches && platform_matches=true
	external_state_paths="$external_state_paths etc/config/firewall"
	if [ "$(jsonfilter -i "$bundle/subscriptions.json" -e '@.schema_version' 2>/dev/null || true)" != "1" ]; then
		error_code=instance_subscriptions_schema_invalid
		return 1
	fi
	policy_source_kind=$(jsonfilter -i "$bundle/policy.json" -e '@.policy_source.kind' 2>/dev/null || true)
	policy_source_ref=$(jsonfilter -i "$bundle/policy.json" -e '@.policy_source.ref' 2>/dev/null || true)
	recovery_profile_ref=$(jsonfilter -i "$bundle/policy.json" -e '@.recovery_profile.ref' 2>/dev/null || true)
	policy_source_section=""
	case "$policy_source_kind:$policy_source_ref" in
		profile:subscription:*) policy_source_section=${policy_source_ref#subscription:} ;;
		bundle:bundle:*)
			policy_source_bundle=${policy_source_ref#bundle:}
			case "$policy_source_bundle" in
				*[!A-Za-z0-9_-]*|'') error_code=instance_policy_source_unsupported; return 1 ;;
			esac
			[ -f "$(root_path "/etc/opl-netfleet/policy-sources/$policy_source_bundle.json")" ] ||
				[ -f "$candidate_dir/etc/opl-netfleet/policy-sources/$policy_source_bundle.json" ] ||
				grep -Eq "^[0-9a-f]{64}  etc/opl-netfleet/policy-sources/$policy_source_bundle\\.json$" "$bundle/FILES.sha256" || {
				error_code=instance_policy_source_unsupported
				return 1
			}
			;;
		*) error_code=instance_policy_source_unsupported; return 1 ;;
	esac
	case "$recovery_profile_ref" in
		subscription:*) recovery_section=${recovery_profile_ref#subscription:} ;;
		*) error_code=instance_recovery_profile_unsupported; return 1 ;;
	esac
	if [ -n "$policy_source_section" ]; then
		case "$policy_source_section" in
			*[!A-Za-z0-9_]*|'') error_code=instance_policy_source_unsupported; return 1 ;;
		esac
	fi
	case "$recovery_section" in
		*[!A-Za-z0-9_]*|'') error_code=instance_recovery_profile_unsupported; return 1 ;;
	esac
	seen=,
	declared_policy_source=0
	declared_recovery=0
	index=0
	subscription_state_paths=""
	subscriptions_match=true
	while :; do
		section=$(subscription_value "$index" section)
		[ -n "$section" ] || break
		case "$section" in
			*[!A-Za-z0-9_]*|'') error_code=instance_subscription_section_invalid; return 1 ;;
		esac
		case "$seen" in
			*",$section,"*) error_code=instance_subscription_section_duplicate; return 1 ;;
		esac
		seen="${seen}${section},"
		[ -z "$policy_source_section" ] || [ "$section" != "$policy_source_section" ] || declared_policy_source=1
		[ "$section" != "$recovery_section" ] || declared_recovery=1
		name=$(subscription_value "$index" name)
		url=$(subscription_value "$index" url)
		user_agent=$(subscription_value "$index" user_agent)
		info_url=$(subscription_value "$index" info_url)
		[ -n "$name" ] || { error_code=instance_subscription_name_invalid; return 1; }
		case "$url" in
			https://*) ;;
			*) error_code=instance_subscription_url_invalid; return 1 ;;
		esac
		case "$info_url" in
			''|https://*) ;;
			*) error_code=instance_subscription_info_url_invalid; return 1 ;;
		esac
		cache=$(root_path "/etc/nikki/subscriptions/$section.yaml")
		subscription_state_paths="$subscription_state_paths etc/nikki/subscriptions/$section.yaml"
		if [ "$(uci -q get "nikki.$section" 2>/dev/null || true)" != "subscription" ] ||
			[ "$(uci -q get "nikki.$section.name" 2>/dev/null || true)" != "$name" ] ||
			[ "$(uci -q get "nikki.$section.url" 2>/dev/null || true)" != "$url" ] ||
			[ "$(uci -q get "nikki.$section.user_agent" 2>/dev/null || true)" != "$user_agent" ] ||
			[ "$(uci -q get "nikki.$section.info_url" 2>/dev/null || true)" != "$info_url" ] ||
			[ ! -f "$cache" ] || ! yq -M -p yaml -o json "$cache" >/dev/null 2>&1; then
			subscriptions_match=false
		fi
		index=$((index + 1))
	done
	[ "$index" -gt 0 ] || { error_code=instance_subscriptions_empty; return 1; }
	[ -z "$policy_source_section" ] || [ "$declared_policy_source" = "1" ] || {
		error_code=instance_policy_source_subscription_missing
		return 1
	}
	[ "$declared_recovery" = "1" ] || { error_code=instance_recovery_subscription_missing; return 1; }
	provider_sections=$(jsonfilter -i "$bundle/policy.json" -e '@.providers.*.section' 2>/dev/null || true)
	for section in $provider_sections; do
		case "$seen" in
			*",$section,"*) ;;
			*) error_code=instance_provider_subscription_missing; error_detail=$section; return 1 ;;
		esac
	done
	# Nikki may leave its initial named `subscription` section behind after a
	# real instance is provisioned. It has no usable cache and is not part of
	# the declared instance, but still appears as an empty `default` row in LuCI.
	# Detect only that exact inert placeholder; arbitrary user subscriptions are
	# outside NetFleet ownership.
	case "$seen" in
		*,subscription,*) ;;
		*)
			if [ "$(uci -q get nikki.subscription 2>/dev/null || true)" = "subscription" ] &&
				[ "$(uci -q get nikki.subscription.name 2>/dev/null || true)" = "default" ] &&
				[ "$(uci -q get nikki.subscription.user_agent 2>/dev/null || true)" = "clash" ] &&
				[ "$(uci -q get nikki.subscription.success 2>/dev/null || true)" != "1" ] &&
				[ ! -e "$(root_path /etc/nikki/subscriptions/subscription.yaml)" ] &&
				[ "$(current_profile)" != "subscription:subscription" ]; then
				default_placeholder_present=true
			fi
			;;
	esac
	external_state_paths="$external_state_paths etc/config/nikki etc/nikki/mixin.yaml$subscription_state_paths"
}

cleanup_default_subscription_placeholder() {
	[ "$instance" = "1" ] && [ "$default_placeholder_present" = "true" ] || return 0
	config=$(root_path /etc/config/nikki)
	backup="$action_dir/nikki-before-default-placeholder-cleanup"
	[ -f "$config" ] && cp -a "$config" "$backup" || {
		error_code=default_subscription_cleanup_failed
		return 1
	}
	if ! uci -q delete nikki.subscription >/dev/null 2>&1 || ! uci commit nikki ||
		[ -n "$(uci -q get nikki.subscription 2>/dev/null || true)" ]; then
		cp -a "$backup" "$config" >/dev/null 2>&1 || true
		error_code=default_subscription_cleanup_failed
		return 1
	fi
	default_placeholder_present=false
}

install_instance_subscriptions() {
	[ "$instance" = "1" ] || return 0
	index=0
	while :; do
		section=$(subscription_value "$index" section)
		[ -n "$section" ] || break
		name=$(subscription_value "$index" name)
		url=$(subscription_value "$index" url)
		user_agent=$(subscription_value "$index" user_agent)
		info_url=$(subscription_value "$index" info_url)
		cache=$(root_path "/etc/nikki/subscriptions/$section.yaml")
		if [ "$(uci -q get "nikki.$section" 2>/dev/null || true)" != "subscription" ] ||
			[ "$(uci -q get "nikki.$section.name" 2>/dev/null || true)" != "$name" ] ||
			[ "$(uci -q get "nikki.$section.url" 2>/dev/null || true)" != "$url" ] ||
			[ "$(uci -q get "nikki.$section.user_agent" 2>/dev/null || true)" != "$user_agent" ] ||
			[ "$(uci -q get "nikki.$section.info_url" 2>/dev/null || true)" != "$info_url" ] ||
			[ ! -f "$cache" ] || ! yq -M -p yaml -o json "$cache" >/dev/null 2>&1; then
			uci -q delete "nikki.$section" >/dev/null 2>&1 || true
			uci set "nikki.$section=subscription" || { error_code=instance_subscription_config_failed; return 1; }
			uci set "nikki.$section.name=$name" || { error_code=instance_subscription_config_failed; return 1; }
			uci set "nikki.$section.url=$url" || { error_code=instance_subscription_config_failed; return 1; }
			if [ -n "$user_agent" ]; then
				uci set "nikki.$section.user_agent=$user_agent" || { error_code=instance_subscription_config_failed; return 1; }
			fi
			if [ -n "$info_url" ]; then
				uci set "nikki.$section.info_url=$info_url" || { error_code=instance_subscription_config_failed; return 1; }
			fi
			nikki_init=$(root_path /etc/init.d/nikki)
			if ! uci commit nikki || [ ! -x "$nikki_init" ] ||
				! "$nikki_init" update_subscription "$section" >/dev/null 2>&1 ||
				[ "$(uci -q get "nikki.$section.success" 2>/dev/null || true)" != "1" ] ||
				[ ! -f "$cache" ] || ! yq -M -p yaml -o json "$cache" >/dev/null 2>&1; then
				error_code=instance_subscription_update_failed
				error_detail=$section
				return 1
			fi
		fi
		index=$((index + 1))
	done
	if [ -z "$(current_profile)" ]; then
		uci set "nikki.config.profile=$recovery_profile_ref" || { error_code=instance_recovery_profile_set_failed; return 1; }
		uci commit nikki || { error_code=instance_recovery_profile_set_failed; return 1; }
	fi
}

ruleset_value() {
	index=$1
	field=$2
	jsonfilter -i "$bundle/rulesets.lock.json" -e "@.rulesets[$index].$field" 2>/dev/null || true
}

download_locked_ruleset() {
	url=$1
	output=$2
	secret=$(uci -q get nikki.mixin.api_secret 2>/dev/null || true)
	proxy_port=""
	if [ "$(uci -q get nikki.config.enabled 2>/dev/null || true)" = "1" ] &&
		command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1 && [ -n "$secret" ]; then
		proxy_port=$(curl -fsS --noproxy '*' --proxy '' --connect-timeout 2 --max-time 3 \
			-H "Authorization: Bearer $secret" http://127.0.0.1:9090/configs 2>/dev/null |
			jsonfilter -e '@.mixed-port' 2>/dev/null || true)
	fi
	case "$proxy_port" in
		''|*[!0-9]*) proxy_port="" ;;
		*) [ "$proxy_port" -ge 1 ] && [ "$proxy_port" -le 65535 ] || proxy_port="" ;;
	esac
	if [ -n "$proxy_port" ]; then
		if [ "$(uci -q get nikki.mixin.authentication 2>/dev/null || true)" = "1" ]; then
			proxy_username=$(uci -q get nikki.@authentication[0].username 2>/dev/null || true)
			proxy_password=$(uci -q get nikki.@authentication[0].password 2>/dev/null || true)
			[ -n "$proxy_username" ] && [ -n "$proxy_password" ] || return 1
			curl -fsSL --noproxy '' --proxy "http://127.0.0.1:$proxy_port" \
				--proxy-user "$proxy_username:$proxy_password" --connect-timeout 10 --max-time 90 \
				-o "$output" "$url"
			return
		fi
		curl -fsSL --noproxy '' --proxy "http://127.0.0.1:$proxy_port" \
			--connect-timeout 10 --max-time 90 -o "$output" "$url"
		return
	fi
	curl -fsSL --noproxy '*' --proxy '' --connect-timeout 10 --max-time 90 -o "$output" "$url"
}

verify_locked_rulesets() {
	index=0
	while :; do
		id=$(ruleset_value "$index" id)
		[ -n "$id" ] || break
		expected_size=$(ruleset_value "$index" size_bytes)
		expected_sha=$(ruleset_value "$index" sha256)
		path=$(root_path "/etc/nikki/run/rulesets/$id.mrs")
		[ -f "$path" ] && [ "$(wc -c <"$path" | tr -d ' ')" = "$expected_size" ] &&
			[ "$(sha256sum "$path" | awk '{print $1}')" = "$expected_sha" ] || return 1
		index=$((index + 1))
	done
	[ "$index" -gt 0 ]
}

prepare_locked_rulesets() {
	[ "$(jsonfilter -i "$bundle/rulesets.lock.json" -e '@.schema' 2>/dev/null || true)" = "opl-netfleet-ruleset-lock.v1" ] || {
		error_code=ruleset_lock_schema_invalid
		return 1
	}
	upstream_commit=$(jsonfilter -i "$bundle/rulesets.lock.json" -e '@.upstream.commit' 2>/dev/null || true)
	case "$upstream_commit" in
		????????????????????????????????????????)
			case "$upstream_commit" in *[!0-9a-f]*) error_code=ruleset_lock_identity_invalid; return 1 ;; esac
			;;
		*) error_code=ruleset_lock_identity_invalid; return 1 ;;
	esac
	seen=,
	index=0
	while :; do
		id=$(ruleset_value "$index" id)
		[ -n "$id" ] || break
		behavior=$(ruleset_value "$index" behavior)
		format=$(ruleset_value "$index" format)
		url=$(ruleset_value "$index" url)
		expected_size=$(ruleset_value "$index" size_bytes)
		expected_sha=$(ruleset_value "$index" sha256)
		case "$id" in *[!A-Za-z0-9_-]*|'') error_code=ruleset_lock_entry_invalid; return 1 ;; esac
		case "$seen" in *",$id,"*) error_code=ruleset_lock_entry_duplicate; return 1 ;; esac
		seen="${seen}${id},"
		case "$behavior" in domain|ipcidr) ;; *) error_code=ruleset_lock_entry_invalid; error_detail=$id; return 1 ;; esac
		[ "$format" = "mrs" ] || { error_code=ruleset_lock_entry_invalid; error_detail=$id; return 1; }
		case "$url" in "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/$upstream_commit/"*) ;; *) error_code=ruleset_lock_url_invalid; error_detail=$id; return 1 ;; esac
		case "$expected_size" in ''|*[!0-9]*) error_code=ruleset_lock_entry_invalid; error_detail=$id; return 1 ;; esac
		[ "$expected_size" -gt 0 ] || { error_code=ruleset_lock_entry_invalid; error_detail=$id; return 1; }
		case "$expected_sha" in
			????????????????????????????????????????????????????????????????)
				case "$expected_sha" in *[!0-9a-f]*) error_code=ruleset_lock_entry_invalid; error_detail=$id; return 1 ;; esac
				;;
			*) error_code=ruleset_lock_entry_invalid; error_detail=$id; return 1 ;;
		esac
		index=$((index + 1))
	done
	[ "$index" -gt 0 ] || { error_code=ruleset_lock_set_invalid; return 1; }
	ruleset_count=$index
	for required in cn-domain cn-ip geolocation-non-cn; do
		case "$seen" in *",$required,"*) ;; *) error_code=ruleset_lock_set_invalid; error_detail=$required; return 1 ;; esac
	done
	rulesets_match=false
	if verify_locked_rulesets; then
		rulesets_match=true
		return 0
	fi
	rulesets_stage_dir=$bundle/rulesets-staged
	rm -rf -- "$rulesets_stage_dir"
	mkdir -p "$rulesets_stage_dir" || { error_code=ruleset_stage_failed; return 1; }
	index=0
	while [ "$index" -lt "$ruleset_count" ]; do
		id=$(ruleset_value "$index" id)
		url=$(ruleset_value "$index" url)
		expected_size=$(ruleset_value "$index" size_bytes)
		expected_sha=$(ruleset_value "$index" sha256)
		temporary="$rulesets_stage_dir/$id.mrs.tmp"
		if ! download_locked_ruleset "$url" "$temporary" ||
			[ "$(wc -c <"$temporary" 2>/dev/null | tr -d ' ')" != "$expected_size" ] ||
			[ "$(sha256sum "$temporary" 2>/dev/null | awk '{print $1}')" != "$expected_sha" ] ||
			! mv -f "$temporary" "$rulesets_stage_dir/$id.mrs"; then
			rm -f -- "$temporary"
			error_code=ruleset_download_failed
			error_detail=$id
			return 1
		fi
		index=$((index + 1))
	done
}

install_locked_rulesets() {
	legacy=$(root_path /etc/opl-netfleet/rulesets)
	if [ "$rulesets_match" = "true" ]; then
		rm -rf -- "$legacy"
		return 0
	fi
	target=$(root_path /etc/nikki/run/rulesets)
	temporary="${target}.new.$$"
	old="${target}.old.$$"
	rm -rf -- "$temporary" "$old"
	mkdir -p "$temporary" || { error_code=ruleset_install_failed; return 1; }
	index=0
	while [ "$index" -lt "$ruleset_count" ]; do
		id=$(ruleset_value "$index" id)
		cp "$rulesets_stage_dir/$id.mrs" "$temporary/$id.mrs" && chmod 0644 "$temporary/$id.mrs" || {
			error_code=ruleset_install_failed
			return 1
		}
		index=$((index + 1))
	done
	[ ! -e "$target" ] || mv "$target" "$old" || { error_code=ruleset_install_failed; return 1; }
	if ! mv "$temporary" "$target"; then
		[ ! -e "$old" ] || mv "$old" "$target" >/dev/null 2>&1 || true
		error_code=ruleset_install_failed
		return 1
	fi
	rm -rf -- "$old"
	verify_locked_rulesets || { error_code=ruleset_readback_failed; return 1; }
	rm -rf -- "$legacy"
	rulesets_changed=true
}

snapshot_current() {
	new_dir="${rollback_dir}.new.$$"
	old_dir="${rollback_dir}.old.$$"
	rm -rf -- "$new_dir" "$old_dir" || return 1
	mkdir -p "$new_dir/files" || return 1
	for rel in $owned_paths $state_paths $external_state_paths $runtime_state_paths; do
		target=$(root_path "/$rel")
		if [ -e "$target" ] || [ -L "$target" ]; then
			destination="$new_dir/files/$rel"
			mkdir -p "$(dirname "$destination")" || return 1
			cp -a "$target" "$destination" || return 1
		else
			printf '%s\n' "$rel" >>"$new_dir/absent" || return 1
		fi
	done
	printf '%s\n' "$(current_profile)" >"$new_dir/profile-before" || return 1
	if supervisor_enabled; then
		: >"$new_dir/supervisor-enabled" || return 1
	fi
	if supervisor_running; then
		: >"$new_dir/supervisor-running" || return 1
	fi
	(
		cd "$new_dir/files" || exit 1
		tar -cf "$new_dir/snapshot.tar" .
	) || return 1
	rm -rf -- "$new_dir/files" || return 1
	if [ -e "$rollback_dir" ]; then
		mv "$rollback_dir" "$old_dir" || return 1
	fi
	if ! mv "$new_dir" "$rollback_dir"; then
		[ ! -e "$old_dir" ] || mv "$old_dir" "$rollback_dir"
		return 1
	fi
	rm -rf -- "$old_dir" || return 1
}

migrate_evidence_state() {
	persistent=$(root_path /etc/opl-netfleet/evidence.json)
	legacy=$(root_path /var/lib/opl-netfleet/evidence.json)
	if [ ! -f "$persistent" ] && [ -f "$legacy" ]; then
		mkdir -p "$(dirname "$persistent")" || return 1
		cp "$legacy" "${persistent}.tmp.$$" || return 1
		chmod 0600 "${persistent}.tmp.$$" || { rm -f "${persistent}.tmp.$$"; return 1; }
		mv -f "${persistent}.tmp.$$" "$persistent" || { rm -f "${persistent}.tmp.$$"; return 1; }
	fi
	if [ -f "$persistent" ]; then
		rm -f "$legacy" || return 1
	fi
}

rollback_payload() {
	profile=$(current_profile)
	new_main=$(root_path /usr/libexec/opl-netfleet/main.uc)
	if is_netfleet_profile "$profile" && [ -f "$new_main" ]; then
		run_action "$new_main" disable "$action_dir/rollback-disable.json" || true
		profile=$(current_profile)
	fi
	if is_netfleet_profile "$profile"; then
		rollback_state=active_profile_not_recoverable
		return 1
	fi
	if [ "$instance" = "1" ]; then
		if ! restore_snapshot_bytes; then
			rollback_state=original_nikki_state_not_recoverable
			return 1
		fi
		restored_main=$(root_path /usr/libexec/opl-netfleet/main.uc)
		nikki_init=$(root_path /etc/init.d/nikki)
		if is_netfleet_profile "$profile_before"; then
			if [ ! -x "$restored_main" ] ||
				! run_action "$restored_main" disable "$action_dir/rollback-old-disable.json"; then
				rollback_state=original_active_owner_not_recoverable
				return 1
			fi
		elif [ -n "$profile_before" ]; then
			if [ ! -x "$nikki_init" ] || ! "$nikki_init" restart >/dev/null 2>&1 ||
				! native_owner_ready "$profile_before"; then
				rollback_state=original_native_profile_not_recoverable
				return 1
			fi
		elif [ ! -x "$nikki_init" ] || ! "$nikki_init" stop >/dev/null 2>&1; then
			rollback_state=original_passthrough_not_recoverable
			return 1
		fi
		if restore_supervisor_state; then
			rollback_state=restored_previous_bytes_native_profile
			return 0
		fi
		rollback_state=restore_failed
		return 1
	fi
	if restore_snapshot; then
		rollback_state=restored_previous_bytes_native_profile
		return 0
	fi
	rollback_state=restore_failed
	return 1
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

[ -n "$bundle" ] && [ -d "$bundle" ] || {
	error_code=bundle_missing
	exit 1
}

for tool in awk chmod cp curl dirname find grep ip mkdir mv rm sha256sum sleep tar tr ubus uci wc; do
	command -v "$tool" >/dev/null 2>&1 || {
		error_code=unsupported_target
		error_detail=$tool
		exit 1
	}
done
if [ -z "$root_prefix" ] && [ "$(id -u)" != "0" ]; then
	error_code=root_required
	exit 1
fi
if [ -z "$root_prefix" ] && [ ! -f /etc/openwrt_release ]; then
	error_code=unsupported_target
	error_detail=openwrt_identity
	exit 1
fi
if [ "$allow_disable" = "0" ] && is_netfleet_profile "$(current_profile)"; then
	error_code=active_target_requires_explicit_mode
	exit 1
fi
for path in SHA256SUMS FILES.sha256 bundle.json deploy-openwrt-remote.sh; do
	[ -f "$bundle/$path" ] || {
		error_code=bundle_incomplete
		exit 1
	}
done
while read -r expected path extra; do
	[ -n "$expected" ] || continue
	[ -z "${extra:-}" ] || {
		error_code=bundle_checksum_format_invalid
		exit 1
	}
	case "$path" in
		FILES.sha256|bundle.json|deploy-openwrt-remote.sh|rulesets.lock.json|candidate.tar|payload.tar|package-manifest.json|*.apk|*.ipk|packages.adb|opl-netfleet-apk.pem|policy.json|subscriptions.json|nikki-mixin.yaml|platform.json) ;;
		*) error_code=bundle_checksum_path_invalid; exit 1 ;;
	esac
done <"$bundle/SHA256SUMS"
if ! (cd "$bundle" && sha256sum -c SHA256SUMS >/dev/null); then
	error_code=bundle_checksum_mismatch
	exit 1
fi

# A damaged or incomplete bundle must not trigger package installation. The
# package manager remains outside the rollback slot by design, but no Nikki
# state is touched until the instance and its native baseline are validated.
if ! bootstrap_instance_dependencies; then
	exit 1
fi

lock_path=$(root_path /var/lock/opl-netfleet-deploy.lock)
mkdir -p "$(dirname "$lock_path")"
if [ "${OPL_NETFLEET_DEPLOY_LOCKED:-}" != "1" ]; then
	exec 9>"$lock_path"
	if ! flock -n 9; then
		error_code=deploy_busy
		exit 1
	fi
	set -- --bundle "$bundle"
	if [ "$presentation_only" = "1" ]; then
		set -- "$@" --presentation-only
	elif [ "$preserve_state" = "1" ]; then
		set -- "$@" --preserve-state
	elif [ "$allow_disable" = "1" ]; then
		set -- "$@" --leave-disabled
	else
		set -- "$@" --stage-only
	fi
	[ "$instance" != "1" ] || set -- "$@" --instance
	trap - EXIT
	OPL_NETFLEET_DEPLOY_LOCKED=1 sh "$0" "$@" 9>&-
	exit $?
fi

source_commit=$(jsonfilter -i "$bundle/bundle.json" -e '@.source_commit' 2>/dev/null || true)
source_tree=$(jsonfilter -i "$bundle/bundle.json" -e '@.source_tree' 2>/dev/null || true)
product_version=$(jsonfilter -i "$bundle/bundle.json" -e '@.product_version' 2>/dev/null || true)
bundle_schema=$(jsonfilter -i "$bundle/bundle.json" -e '@.schema' 2>/dev/null || true)
bundle_instance=$(jsonfilter -i "$bundle/bundle.json" -e '@.instance' 2>/dev/null || true)
[ "$bundle_instance" = "true" ] || bundle_instance=false
[ "$bundle_schema" = "opl-netfleet-deploy-bundle.v3" ] || [ "$bundle_schema" = "opl-netfleet-deploy-bundle.v4" ] || [ "$bundle_schema" = "opl-netfleet-deploy-bundle.v5" ] || {
	error_code=bundle_schema_invalid
	exit 1
}
[ "${#source_commit}" -eq 40 ] && [ "${#source_tree}" -eq 40 ] || {
	error_code=bundle_identity_invalid
	exit 1
}
case "$source_commit$source_tree" in
	*[!0-9a-f]*)
		error_code=bundle_identity_invalid
		exit 1
		;;
esac
case "$product_version" in
	'') ;;
	*[!0-9A-Za-z.+~-]*|[!0-9]*) error_code=bundle_identity_invalid; exit 1 ;;
esac
activation_qualified=$(jsonfilter -i "$bundle/bundle.json" -e '@.activation_qualified' 2>/dev/null || true)
qualification_digest=$(jsonfilter -i "$bundle/bundle.json" -e '@.qualification_sha256' 2>/dev/null || true)
runtime_payload_digest=$(jsonfilter -i "$bundle/bundle.json" -e '@.runtime_payload_sha256' 2>/dev/null || true)
release_mode=$(jsonfilter -i "$bundle/bundle.json" -e '@.release_mode' 2>/dev/null || true)
release_format=$(jsonfilter -i "$bundle/bundle.json" -e '@.release_format' 2>/dev/null || true)
rulesets_lock_digest=$(jsonfilter -i "$bundle/bundle.json" -e '@.rulesets_lock_sha256' 2>/dev/null || true)
[ -n "$release_mode" ] || release_mode=source
[ -n "$release_format" ] || release_format=source
if [ "$bundle_schema" = "opl-netfleet-deploy-bundle.v5" ]; then
	[ -f "$bundle/rulesets.lock.json" ] && [ "${#rulesets_lock_digest}" -eq 64 ] &&
		[ "$(sha256sum "$bundle/rulesets.lock.json" | awk '{print $1}')" = "$rulesets_lock_digest" ] || {
		error_code=ruleset_lock_identity_invalid
		exit 1
	}
fi
if [ "$release_mode" = "package" ]; then
	[ "$release_format" = "apk" ] || [ "$release_format" = "ipk" ] || {
		error_code=package_release_invalid
		exit 1
	}
	[ -f "$bundle/package-manifest.json" ] || {
		error_code=package_release_incomplete
		exit 1
	}
	package_manifest_schema=$(jsonfilter -i "$bundle/package-manifest.json" -e '@.schema' 2>/dev/null || true)
	[ "$package_manifest_schema" = "opl-netfleet-package-manifest.v2" ] || {
		error_code=package_manifest_invalid
		exit 1
	}
	package_manifest_commit=$(jsonfilter -i "$bundle/package-manifest.json" -e '@.source_commit' 2>/dev/null || true)
	package_manifest_tree=$(jsonfilter -i "$bundle/package-manifest.json" -e '@.source_tree' 2>/dev/null || true)
	[ "$package_manifest_commit" = "$source_commit" ] && [ "$package_manifest_tree" = "$source_tree" ] || {
		error_code=package_manifest_identity_invalid
		exit 1
	}
fi
case "$runtime_payload_digest" in
	????????????????????????????????????????????????????????????????)
		case "$runtime_payload_digest" in *[!0-9a-f]*) runtime_payload_digest="" ;; esac
		;;
	*) runtime_payload_digest="" ;;
esac
if [ "$preserve_state" = "1" ] && [ "$presentation_only" != "1" ]; then
	if [ "$activation_qualified" != "true" ] || [ "${#qualification_digest}" -ne 64 ]; then
		error_code=activation_qualification_required
		exit 1
	fi
	case "$qualification_digest" in
		*[!0-9a-f]*) error_code=activation_qualification_required; exit 1 ;;
	esac
fi
if [ "$instance" = "1" ]; then
		[ "$bundle_instance" = "true" ] && [ "$bundle_schema" = "opl-netfleet-deploy-bundle.v5" ] &&
			[ -f "$bundle/policy.json" ] && [ -f "$bundle/subscriptions.json" ] &&
			[ -f "$bundle/nikki-mixin.yaml" ] && [ -f "$bundle/platform.json" ] || {
		error_code=instance_incomplete
		exit 1
	}
	policy_digest=$(jsonfilter -i "$bundle/bundle.json" -e '@.policy_sha256' 2>/dev/null || true)
	subscriptions_digest=$(jsonfilter -i "$bundle/bundle.json" -e '@.subscriptions_sha256' 2>/dev/null || true)
	mixin_digest=$(jsonfilter -i "$bundle/bundle.json" -e '@.nikki_mixin_sha256' 2>/dev/null || true)
	platform_digest=$(jsonfilter -i "$bundle/bundle.json" -e '@.platform_sha256' 2>/dev/null || true)
	if [ "${#policy_digest}" -ne 64 ] ||
		[ "$(sha256sum "$bundle/policy.json" | awk '{print $1}')" != "$policy_digest" ] ||
		[ "${#subscriptions_digest}" -ne 64 ] ||
		[ "$(sha256sum "$bundle/subscriptions.json" | awk '{print $1}')" != "$subscriptions_digest" ] ||
		[ "${#mixin_digest}" -ne 64 ] ||
		[ "$(sha256sum "$bundle/nikki-mixin.yaml" | awk '{print $1}')" != "$mixin_digest" ] ||
		[ "${#platform_digest}" -ne 64 ] ||
		[ "$(sha256sum "$bundle/platform.json" | awk '{print $1}')" != "$platform_digest" ] ||
		! yq -M -p yaml -o json "$bundle/nikki-mixin.yaml" >/dev/null 2>&1; then
		error_code=instance_identity_invalid
		exit 1
	fi
else
	[ "$bundle_instance" != "true" ] || {
		error_code=instance_mode_required
		exit 1
	}
fi

candidate_dir="$bundle/candidate"
action_dir="$bundle/actions"
mkdir -p "$candidate_dir" "$action_dir"
candidate_archive="$bundle/payload.tar"
if [ "$release_mode" = "source" ]; then
	[ -f "$candidate_archive" ] || { error_code=bundle_incomplete; exit 1; }
	tar -tf "$candidate_archive" >"$bundle/payload.paths"
	while IFS= read -r path; do
		case "$path" in
			/*|../*|*'/../'*|*'/..') error_code=payload_path_invalid; exit 1 ;;
		esac
	done <"$bundle/payload.paths"
	tar -C "$candidate_dir" -xf "$candidate_archive"
	candidate_main="$candidate_dir/usr/libexec/opl-netfleet/main.uc"
	[ -f "$candidate_main" ] || { error_code=candidate_runtime_missing; exit 1; }
	if [ "$bundle_schema" = "opl-netfleet-deploy-bundle.v5" ]; then
		candidate_ruleset_lock="$candidate_dir/etc/opl-netfleet/rulesets.lock.json"
		[ -f "$candidate_ruleset_lock" ] &&
			[ "$(sha256sum "$candidate_ruleset_lock" | awk '{print $1}')" = "$rulesets_lock_digest" ] || {
			error_code=candidate_ruleset_lock_mismatch
			exit 1
		}
	fi
else
	candidate_main=$(root_path /usr/libexec/opl-netfleet/main.uc)
fi
if [ "$bundle_schema" = "opl-netfleet-deploy-bundle.v5" ]; then
	prepare_locked_rulesets || exit 1
else
	rulesets_match=true
fi
if [ "$instance" = "1" ]; then
	if [ "$release_mode" = "source" ] && ! run_action "$candidate_main" validate-schema "$action_dir/preflight-instance-policy.json" "$bundle/policy.json"; then
		error_code=instance_policy_schema_invalid
		exit 1
	fi
	if ! validate_instance_inputs; then
		exit 1
	fi
fi

profile_before=$(current_profile)
[ -n "$profile_before" ] || [ "$instance" = "1" ] || {
	error_code=nikki_profile_unreadable
	exit 1
}
if is_netfleet_profile "$profile_before"; then
	was_active=true
fi
if ! ip -4 route show default 2>/dev/null | grep -q '^default '; then
	error_code=upstream_default_route_missing
	exit 1
fi

netfleet_present=false
preflight_active=false
live_policy=$(root_path /etc/opl-netfleet/policy.json)
old_main=$(root_path /usr/libexec/opl-netfleet/main.uc)
if [ "$instance" = "1" ]; then
	# A fresh/native target has no NetFleet owner to interrogate. The instance
	# schema is already validated above; subscription/runtime validation happens
	# after the declared native baseline is provisioned under the rollback slot.
	preflight_main=$candidate_main
	[ ! -x "$old_main" ] || preflight_main=$old_main
	if [ -f "$live_policy" ] &&
		run_action "$preflight_main" status "$action_dir/preflight-status.json"; then
		netfleet_present=$(jsonfilter -i "$action_dir/preflight-status.json" -e '@.result.runtime.netfleet_present' 2>/dev/null || true)
		preflight_active=$(jsonfilter -i "$action_dir/preflight-status.json" -e '@.result.active' 2>/dev/null || true)
		if { [ "$was_active" = "true" ] || [ "$netfleet_present" = "true" ]; } &&
			! run_action "$preflight_main" probe "$action_dir/preflight-probe.json"; then
			error_code=protected_probe_failed_before_deploy
			exit 1
		fi
	elif [ "$was_active" = "true" ]; then
		error_code=owner_status_unavailable
		exit 1
	fi
else
	# Upgrade mode retains the previous target-local policy and therefore needs
	# a complete owner/probe readback before replacing any bytes.
	if ! run_action "$candidate_main" validate "$action_dir/preflight-validate.json"; then
		error_code=candidate_validate_failed
		exit 1
	fi
	if ! run_action "$candidate_main" status "$action_dir/preflight-status.json"; then
		error_code=owner_status_unavailable
		exit 1
	fi
	if ! run_action "$candidate_main" probe "$action_dir/preflight-probe.json"; then
		error_code=protected_probe_failed_before_deploy
		exit 1
	fi
	netfleet_present=$(jsonfilter -i "$action_dir/preflight-status.json" -e '@.result.runtime.netfleet_present' 2>/dev/null || true)
	preflight_active=$(jsonfilter -i "$action_dir/preflight-status.json" -e '@.result.active' 2>/dev/null || true)
fi

# This is a control-plane-only reconciliation. It intentionally happens after
# the active owner and protected path have been read back, and before the
# identical-install shortcut, so removing the inert row never cycles Nikki.
if [ "$presentation_only" != "1" ] && ! cleanup_default_subscription_placeholder; then
	exit 1
fi

installed_identity=$(root_path /etc/opl-netfleet/installed.json)
identity_matches=false
if [ -f "$installed_identity" ] &&
	[ "$(sha256sum "$installed_identity" | awk '{print $1}')" = "$(sha256sum "$bundle/bundle.json" | awk '{print $1}')" ]; then
	identity_matches=true
fi
candidate_runtime_payload_digest=$(current_runtime_payload_digest 2>/dev/null || true)
runtime_payload_matches=false
if [ -n "$runtime_payload_digest" ] &&
	[ "$candidate_runtime_payload_digest" = "$runtime_payload_digest" ] &&
	verify_installed_runtime_files; then
	runtime_payload_matches=true
fi
policy_matches=false
if [ "$instance" != "1" ] ||
	{ [ -f "$live_policy" ] &&
		{ [ "$(sha256sum "$live_policy" | awk '{print $1}')" = "$policy_digest" ] ||
			json_semantically_equal "$live_policy" "$bundle/policy.json"; }; }; then
	policy_matches=true
fi
mixin_matches=true
if [ "$instance" = "1" ]; then
	live_mixin=$(root_path /etc/nikki/mixin.yaml)
	if [ ! -f "$live_mixin" ] ||
		{ [ "$(sha256sum "$live_mixin" | awk '{print $1}')" != "$mixin_digest" ] &&
			! yaml_semantically_equal "$live_mixin" "$bundle/nikki-mixin.yaml"; } ||
		[ "$(uci -q get nikki.mixin.mixin_file_content 2>/dev/null || true)" != "1" ]; then
		mixin_matches=false
	fi
fi
instance_native_changed=false
if [ "$mixin_matches" != "true" ] || [ "$subscriptions_match" != "true" ] || [ "$platform_matches" != "true" ]; then
	instance_native_changed=true
fi
shortcut_allowed=false
rpcd_timeout_matches=false
if rpcd_timeout_ready; then
	rpcd_timeout_matches=true
fi
if [ "$presentation_only" = "1" ] &&
	{ [ "$instance" != "1" ] || [ "$was_active" != "true" ] ||
	[ "$preflight_active" != "true" ] || [ "$netfleet_present" != "true" ] ||
	[ "$runtime_payload_matches" != "true" ] || [ "$policy_matches" != "true" ] ||
	[ "$mixin_matches" != "true" ] || [ "$subscriptions_match" != "true" ] ||
	[ "$platform_matches" != "true" ] || [ "$rulesets_match" != "true" ] ||
	[ "$rpcd_timeout_matches" != "true" ]; }; then
	error_code=presentation_only_precondition_failed
	exit 1
fi
if [ "$instance" != "1" ] && [ "$rpcd_timeout_matches" = "true" ]; then
	shortcut_allowed=true
elif [ "$preserve_state" = "1" ] && [ "$was_active" = "true" ] &&
	[ "$policy_matches" = "true" ] && [ "$mixin_matches" = "true" ] &&
	[ "$subscriptions_match" = "true" ] && [ "$platform_matches" = "true" ] &&
	[ "$rulesets_match" = "true" ] && [ "$rpcd_timeout_matches" = "true" ]; then
	shortcut_allowed=true
fi
if [ "$shortcut_allowed" = "true" ] && [ "$rulesets_match" = "true" ] && verify_installed_files &&
	{ [ "$was_active" = "true" ] || [ "$netfleet_present" != "true" ]; }; then
	# Identical payload bytes do not justify a data-plane cycle. Reconcile the
	# control-plane loader and provenance in place; --leave-disabled still uses
	# the full disable path when this profile is active.
	if [ "$preserve_state" = "1" ] || [ "$was_active" != "true" ]; then
		service_before_enabled=0
		service_before_running=0
		supervisor_enabled && service_before_enabled=1
		supervisor_running && service_before_running=1
		service_mutated=1
		service_restore_mode=flags
		if ! ensure_rpcd_surface; then
			error_code=rpcd_surface_unavailable
			exit 1
		fi
		install_state=already_installed
		if ! ensure_supervisor; then
			error_code=supervisor_start_failed
			exit 1
			fi
			if [ "$identity_matches" != "true" ]; then
				if ! install_identity; then
					error_code=installed_identity_update_failed
					exit 1
				fi
				install_state=payload_reconciled
			fi
		final_active=$(jsonfilter -i "$action_dir/preflight-status.json" -e '@.result.active' 2>/dev/null || true)
		[ "$final_active" = "true" ] || final_active=false
		service_mutated=0
		service_restore_mode=none
		trap - EXIT
		printf '{"ok":true,"action":"deploy","state":"%s","source_commit":"%s","source_tree":"%s","previous_active":%s,"final_active":%s,"installed_parity":true,"protected_probes":true}\n' \
			"$install_state" "$source_commit" "$source_tree" "$was_active" "$final_active"
		exit 0
	fi
fi

if [ "$preserve_state" = "1" ] && [ "$was_active" = "true" ] &&
	[ "$preflight_active" = "true" ] && [ "$netfleet_present" = "true" ] &&
	[ "$policy_matches" = "true" ] && [ "$mixin_matches" = "true" ] &&
	[ "$subscriptions_match" = "true" ] && [ "$platform_matches" = "true" ] &&
	[ "$rulesets_match" = "true" ] &&
	{ [ "$runtime_payload_matches" = "true" ] || [ ! -x "$old_main" ]; }; then
	# A presentation-only update and a missing control plane both reuse the
	# already healthy active artifact. Candidate status/probe above proves the
	# current data plane before replacing identical runtime bytes plus RPC/LuCI.
	repair_state=control_plane_repaired
	[ "$runtime_payload_matches" != "true" ] || repair_state=presentation_updated
	if ! snapshot_current; then
		error_code=rollback_snapshot_failed
		exit 1
	fi
	stop_supervisor
	control_plane_repair=1
	if ! install_owned_payload; then
		exit 1
	fi
	new_main=$(root_path /usr/libexec/opl-netfleet/main.uc)
	if ! run_action "$new_main" validate "$action_dir/repair-validate.json"; then
		error_code=installed_validate_failed
		exit 1
	fi
	if ! ensure_supervisor; then
		error_code=supervisor_start_failed
		exit 1
	fi
	if ! run_action "$new_main" status "$action_dir/repair-status.json"; then
		error_code=final_owner_status_failed
		exit 1
	fi
	if ! run_action "$new_main" probe "$action_dir/repair-probe.json"; then
		error_code=protected_probe_failed_after_deploy
		exit 1
	fi
	final_active=$(jsonfilter -i "$action_dir/repair-status.json" -e '@.result.active' 2>/dev/null || true)
	[ "$final_active" = "true" ] || {
		error_code=final_active_state_mismatch
		exit 1
	}
	if ! install_identity; then
		error_code=installed_identity_update_failed
		exit 1
	fi
	payload_mutated=0
	trap - EXIT
	printf '{"ok":true,"action":"deploy","state":"%s","source_commit":"%s","source_tree":"%s","previous_active":true,"final_active":true,"installed_parity":true,"protected_probes":true,"rollback":"available"}\n' \
		"$repair_state" "$source_commit" "$source_tree"
	exit 0
fi

if ! snapshot_current; then
	error_code=rollback_snapshot_failed
	exit 1
fi
stop_supervisor

if [ "$was_active" = "true" ] || [ "$netfleet_present" = "true" ]; then
	[ -f "$old_main" ] || {
		error_code=active_runtime_missing
		exit 1
	}
	if ! run_action "$old_main" disable "$action_dir/disable.json"; then
		error_code=disable_failed
		exit 1
	fi
	if is_netfleet_profile "$(current_profile)"; then
		error_code=disable_readback_failed
		exit 1
	fi
	disable_probe_ok=$(jsonfilter -i "$action_dir/disable.json" \
		-e '@.result.protected_probes.ok' 2>/dev/null || true)
		if [ "$instance" != "1" ] && [ "$disable_probe_ok" != "true" ] &&
		! run_action "$candidate_main" probe "$action_dir/native-probe.json"; then
		# No payload was changed. Restore the previously healthy active path once;
		# disable removes provider links, so the old owner must rebuild its staged
		# artifact before a single enable attempt. If that fails, its native
		# Fail-Open result remains authoritative.
		if [ "$was_active" = "true" ] &&
			run_action "$old_main" compile "$action_dir/restore-compile.json" &&
			run_action "$old_main" enable "$action_dir/restore-enable.json" &&
			run_action "$old_main" probe "$action_dir/restored-probe.json"; then
			rollback_state=restored_previous_active_profile
		else
			rollback_state=native_probe_failed_previous_runtime_not_restored
		fi
		error_code=native_baseline_probe_failed
		exit 1
	fi
fi

if ! install_owned_payload; then
	exit 1
fi
if ! install_locked_rulesets; then
	exit 1
fi
if ! install_instance_subscriptions; then
	exit 1
fi
if ! install_declared_mixin; then
	exit 1
fi
if ! install_declared_platform; then
	exit 1
fi
if ! install_declared_policy; then
	exit 1
fi
if ! migrate_evidence_state; then
	error_code=evidence_migration_failed
	exit 1
fi

new_main=$(root_path /usr/libexec/opl-netfleet/main.uc)
if [ "$release_mode" = "package" ] && [ "$instance" = "1" ] &&
	! run_action "$new_main" validate-schema "$action_dir/installed-instance-policy.json" "$bundle/policy.json"; then
	error_code=instance_policy_schema_invalid
	exit 1
fi
if ! run_action "$new_main" validate "$action_dir/validate.json"; then
	error_code=installed_validate_failed
	exit 1
fi
if [ "$instance" = "1" ] && [ "$preserve_state" = "1" ]; then
	native_before_prepare=$(current_profile)
	restart_mode=""
	[ "$instance_native_changed" != "true" ] || restart_mode=restart
	if ! run_action "$new_main" prepare-recovery "$action_dir/prepare-recovery.json" "$native_before_prepare" "$restart_mode"; then
		error_code=recovery_profile_prepare_failed
		error_detail=$(action_error_detail "$action_dir/prepare-recovery.json")
		exit 1
	fi
fi
if ! run_action "$new_main" compile "$action_dir/compile.json"; then
	error_code=compile_failed
	error_detail=$(action_error_detail "$action_dir/compile.json")
	exit 1
fi

expected_active=false
if { [ "$was_active" = "true" ] || [ "$instance" = "1" ]; } && [ "$preserve_state" = "1" ]; then
	expected_active=true
	if ! run_action "$new_main" enable "$action_dir/enable.json"; then
		error_code=enable_failed
		error_detail=$(action_error_detail "$action_dir/enable.json")
		exit 1
	fi
fi
if ! ensure_supervisor; then
	error_code=supervisor_start_failed
	exit 1
fi
if ! run_action "$new_main" status "$action_dir/final-status.json"; then
	error_code=final_owner_status_failed
	exit 1
fi
if [ "$expected_active" = "true" ] && ! run_action "$new_main" probe "$action_dir/final-probe.json"; then
	error_code=protected_probe_failed_after_deploy
	exit 1
fi
final_active=$(jsonfilter -i "$action_dir/final-status.json" -e '@.result.active' 2>/dev/null || true)
[ "$final_active" = "$expected_active" ] || {
	error_code=final_active_state_mismatch
	exit 1
}
verify_installed_files || {
	error_code=final_installed_parity_failed
	exit 1
}
if [ "$bundle_schema" = "opl-netfleet-deploy-bundle.v5" ]; then
	installed_ruleset_lock=$(root_path /etc/opl-netfleet/rulesets.lock.json)
	[ -f "$installed_ruleset_lock" ] &&
		[ "$(sha256sum "$installed_ruleset_lock" | awk '{print $1}')" = "$rulesets_lock_digest" ] &&
		verify_locked_rulesets || {
		error_code=final_ruleset_parity_failed
		exit 1
	}
fi
if [ "$instance" = "1" ] && ! platform_current_matches; then
	error_code=final_platform_readback_failed
	exit 1
fi
if ! install_identity; then
	error_code=installed_identity_update_failed
	exit 1
fi

payload_mutated=0
trap - EXIT
printf '{"ok":true,"action":"deploy","state":"installed","source_commit":"%s","source_tree":"%s","previous_active":%s,"final_active":%s,"instance":%s,"installed_parity":true,"protected_probes":%s,"rollback":"available"}\n' \
	"$source_commit" "$source_tree" "$was_active" "$final_active" "$bundle_instance" "$expected_active"
