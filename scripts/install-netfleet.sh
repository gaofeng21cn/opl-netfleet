#!/bin/sh
set -eu
umask 077

die() {
	printf 'install-netfleet: %s\n' "$1" >&2
	exit 1
}

[ "${NETFLEET_INSTALL_TESTING:-0}" = 1 ] || [ "$(id -u)" = 0 ] ||
	die 'must run as root on OpenWrt'
command -v apk >/dev/null 2>&1 || die 'OpenWrt APK package manager is required'

feed_base=${NETFLEET_FEED_BASE:-https://github.com/gaofeng21cn/opl-netfleet/releases/latest/download}
feed_base=${feed_base%/}
case "$feed_base" in
	https://*) ;;
	http://*) [ "${NETFLEET_ALLOW_INSECURE_FEED:-0}" = 1 ] || die 'HTTP feed requires NETFLEET_ALLOW_INSECURE_FEED=1' ;;
	*) die 'feed URL must use HTTPS' ;;
esac
case "$feed_base" in
	*[[:space:]]*) die 'feed URL must not contain whitespace' ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/netfleet-install.XXXXXX")
cleanup() {
	rm -rf -- "$work"
}
trap cleanup EXIT INT TERM

fetch() {
	url=$1
	destination=$2
	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$destination" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$destination" "$url"
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 -o "$destination" "$url"
	else
		die 'uclient-fetch, wget, or curl is required'
	fi
}

key_name=opl-netfleet-apk.pem
key_download="$work/$key_name"
fetch "$feed_base/$key_name" "$key_download"
[ -s "$key_download" ] || die 'downloaded APK public key is empty'
grep -Fq -- '-----BEGIN PUBLIC KEY-----' "$key_download" || die 'downloaded APK public key is invalid'
grep -Fq -- '-----END PUBLIC KEY-----' "$key_download" || die 'downloaded APK public key is invalid'

keys_dir=${NETFLEET_APK_KEYS_DIR:-/etc/apk/keys}
repository_file=${NETFLEET_APK_REPOSITORY_FILE:-/etc/apk/repositories.d/opl-netfleet.list}
repository_dir=$(dirname "$repository_file")
mkdir -p "$keys_dir" "$repository_dir"

key_target="$keys_dir/$key_name"
key_staged="$keys_dir/.$key_name.$$"
repository_staged="$repository_dir/.opl-netfleet.list.$$"
cp "$key_download" "$key_staged"
chmod 0644 "$key_staged"
printf '%s/packages.adb\n' "$feed_base" >"$repository_staged"
chmod 0644 "$repository_staged"
mv -f "$key_staged" "$key_target"
mv -f "$repository_staged" "$repository_file"

apk --timeout 300 update
apk --timeout 300 add --upgrade opl-netfleet luci-app-netfleet

printf 'NetFleet packages installed from %s; open LuCI to review and confirm first takeover.\n' "$feed_base"
