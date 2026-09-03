#!/bin/sh
set -eu
umask 077

usage() {
	cat <<'EOF'
Usage: recover-openwrt-local.sh [--check|--repair-var-link]

Local-console recovery helper. It never restarts, powers off, upgrades, flashes,
or changes Nikki. --repair-var-link only preserves an incorrect /var directory
under /root/opl-netfleet-recovery before restoring the OpenWrt /var -> /tmp link.
EOF
}

mode=check
while [ "$#" -gt 0 ]; do
	case "$1" in
		--check) mode=check ;;
		--repair-var-link) mode=repair ;;
		-h|--help) usage; exit 0 ;;
		*) echo "recover-openwrt-local: unknown argument: $1" >&2; exit 2 ;;
	esac
	shift
done

root_prefix=${OPL_NETFLEET_RECOVERY_ROOT:-}
if [ -n "$root_prefix" ]; then
	[ "${OPL_NETFLEET_RECOVERY_TESTING:-}" = 1 ] || exit 2
	case "$root_prefix" in /*) ;; *) exit 2 ;; esac
	[ "$root_prefix" != / ] || exit 2
	root_prefix=${root_prefix%/}
fi
root_path() {
	if [ -n "$root_prefix" ]; then
		printf '%s/%s' "$root_prefix" "${1#/}"
	else
		printf '/%s' "${1#/}"
	fi
}

release=$(root_path /etc/openwrt_release)
[ -f "$release" ] || { echo '{"ok":false,"error":"not_openwrt"}'; exit 1; }
var_path=$(root_path /var)
tmp_path=$(root_path /tmp)
var_state=missing
if [ -L "$var_path" ]; then
	link=$(readlink "$var_path" 2>/dev/null || true)
	if [ "$link" = tmp ]; then var_state=correct_symlink; else var_state=incorrect_symlink; fi
elif [ -d "$var_path" ]; then
	var_state=directory
elif [ -e "$var_path" ]; then
	var_state=unexpected_type
fi

backup=none
if [ "$mode" = repair ] && [ "$var_state" != correct_symlink ]; then
	[ -d "$tmp_path" ] || { echo '{"ok":false,"error":"tmp_missing"}'; exit 1; }
	case "$var_state" in
		directory)
			if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$var_path"; then
				echo '{"ok":false,"error":"var_is_mountpoint"}'
				exit 1
			fi
			backup_root=$(root_path /root/opl-netfleet-recovery)
			mkdir -p "$backup_root"
			backup="$backup_root/var.$$.bak"
			[ ! -e "$backup" ] || { echo '{"ok":false,"error":"backup_exists"}'; exit 1; }
			mv "$var_path" "$backup"
			;;
		missing) : ;;
		*) echo '{"ok":false,"error":"var_not_repairable"}'; exit 1 ;;
	esac
	if ! ln -s tmp "$var_path" || [ "$(readlink "$var_path" 2>/dev/null || true)" != tmp ]; then
		[ "$backup" = none ] || mv "$backup" "$var_path"
		echo '{"ok":false,"error":"var_link_restore_failed"}'
		exit 1
	fi
	var_state=correct_symlink
fi

ubus_ok=false
if [ -z "$root_prefix" ] && command -v ubus >/dev/null 2>&1 && ubus call system board >/dev/null 2>&1; then
	ubus_ok=true
elif [ -n "$root_prefix" ] && [ -S "$(root_path /var/run/ubus/ubus.sock)" ]; then
	ubus_ok=true
fi
profile=unavailable
enabled=unavailable
if [ -z "$root_prefix" ] && command -v uci >/dev/null 2>&1; then
	profile=$(uci -q get nikki.config.profile 2>/dev/null || true)
	enabled=$(uci -q get nikki.config.enabled 2>/dev/null || true)
	[ -n "$profile" ] || profile=unavailable
	[ -n "$enabled" ] || enabled=unavailable
fi
case "$profile" in *[!A-Za-z0-9:._/-]*) profile=unavailable ;; esac
case "$enabled" in 0|1) ;; *) enabled=unavailable ;; esac
mihomo_running=false
[ -z "$root_prefix" ] && command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1 && mihomo_running=true

printf '{"ok":true,"mode":"%s","var_state":"%s","backup":"%s","ubus":%s,"nikki_profile":"%s","nikki_enabled":"%s","mihomo_running":%s}\n' \
	"$mode" "$var_state" "$backup" "$ubus_ok" "$profile" "$enabled" "$mihomo_running"
