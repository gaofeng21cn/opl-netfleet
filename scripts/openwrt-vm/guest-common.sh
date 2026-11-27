#!/bin/sh
# Shared helper boilerplate for disposable OpenWrt VM qualification scripts.
set -eu
umask 077

_NETFLEET_GUEST_COMMON=1
main=${main:-/usr/libexec/opl-netfleet/main.uc}
gateway=${gateway:-$main}
lock=${lock:-/var/lock/opl-netfleet-deploy.lock}
stage=${stage:-precondition}

guest_stage() {
	stage=$1
	printf 'OpenWrt guest %s | %s\n' "${0##*/}" "$stage" >&2
}

assert_json() { [ "$(jsonfilter -i "$1" -e "$2")" = "$3" ]; }
digest() { sha256sum "$1" | awk '{print $1}'; }

run_locked() {
	_lock=$1
	shift
	(
		exec 9>"$_lock"
		flock 9
		"$@" 9>&-
	)
}

run_main() {
	run_locked "$lock" ucode "$main" "$@"
}

guest_check_receipt() { :; }
guest_on_failure() { :; }
guest_cleanup() { :; }

guest_finish() {
	rc=$?
	trap - EXIT INT TERM
	set +e
	if [ "$rc" -eq 0 ]; then
		guest_check_receipt || rc=1
	fi
	if [ "$rc" -ne 0 ]; then
		guest_on_failure "$rc"
	fi
	guest_cleanup "$rc"
	exit "$rc"
}

guest_setup_trap() {
	trap guest_finish EXIT INT TERM
}
