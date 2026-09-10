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

command -v uci >/dev/null 2>&1 || die 'OpenWrt UCI is required'
command -v jsonfilter >/dev/null 2>&1 || die 'OpenWrt jsonfilter is required'

# Layout migrations need their own rollback qualification, including optional packages.
if apk info -e opl-netfleet >/dev/null 2>&1 && ! apk info -e opl-netfleet-kernel >/dev/null 2>&1; then
	die 'legacy monolith migration requires a qualified package transaction; installed packages were not changed'
fi

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

install_profile=${NETFLEET_INSTALL_PROFILE:-default}
case "$install_profile" in default|full) ;; *) die 'install profile must be default or full' ;; esac
compat_feed=${NETFLEET_COMPAT_FEED_BASE:-$feed_base}
compat_feed=${compat_feed%/}
case "$compat_feed" in
 https://*) ;;
 http://*) [ "${NETFLEET_ALLOW_INSECURE_FEED:-0}" = 1 ] || die 'HTTP compatibility feed requires NETFLEET_ALLOW_INSECURE_FEED=1' ;;
 *) die 'compatibility feed URL must use HTTPS' ;;
esac
case "$compat_feed" in *[[:space:]]*) die 'compatibility feed URL must not contain whitespace' ;; esac

load_https=0
if [ "$install_profile" = full ] && ! apk info -e opl-netfleet-plugin-https-compat >/dev/null 2>&1; then
 load_https=1
fi

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

# Fetch the optional key before changing package sources. A missing full feed
# must not silently degrade a requested full installation to the default set.
if [ "$install_profile" = full ]; then
 fetch "$compat_feed/compat-public-key.pem" "$work/compat-public-key.pem"
 grep -Fq -- '-----BEGIN PUBLIC KEY-----' "$work/compat-public-key.pem" || die 'invalid compatibility public key'
 grep -Fq -- '-----END PUBLIC KEY-----' "$work/compat-public-key.pem" || die 'invalid compatibility public key'
fi

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
if [ "$install_profile" = full ]; then
 cp "$work/compat-public-key.pem" "$keys_dir/.compat-public-key.pem.$$"
 chmod 0644 "$keys_dir/.compat-public-key.pem.$$"
 mv -f "$keys_dir/.compat-public-key.pem.$$" "$keys_dir/compat-public-key.pem"
 printf '%s/compat-packages.adb\n' "$compat_feed" >"$repository_dir/.opl-netfleet-compat.list.$$"
 chmod 0644 "$repository_dir/.opl-netfleet-compat.list.$$"
 mv -f "$repository_dir/.opl-netfleet-compat.list.$$" "$repository_dir/opl-netfleet-compat.list"
fi

for index_attempt in 1 2 3; do
	if apk --timeout 300 update; then break; fi
	[ "$index_attempt" -lt 3 ] || die 'package indexes unavailable; packages were not changed'
	sleep "$((index_attempt * 2))"
done
# Read the candidate product composition so newly added plugins are included too.
apk --no-network query --from none -X "$feed_base/packages.adb" \
	--format json --fields depends opl-netfleet >"$work/product.json"
dependencies=$(jsonfilter -i "$work/product.json" -e '@[*].depends[*]')
set -- opl-netfleet luci-app-netfleet
set -f
for dependency in $dependencies; do
	name=${dependency%%[\<\>\=\~]*}
	case "$name" in
		opl-netfleet-kernel|opl-netfleet-plugin-*)
			case "$name" in *[!a-z0-9-]*) die 'invalid product package name' ;; esac
			set -- "$@" "$name"
			;;
	esac
done
[ "$#" -gt 2 ] || die 'product package dependencies are missing'
if [ "$install_profile" = full ]; then
 set -- "$@" opl-netfleet-plugin-https-compat opl-netfleet-https-compat opl-netfleet-plugin-device-identity
 # Resolve the entire composition before installing any package. No service
 # enable action is issued here; package hooks preserve existing user choices.
 apk --timeout 300 --simulate add "$@" >/dev/null || die 'full installation dependencies unavailable; packages were not changed'
 apk --timeout 300 add "$@"
elif ! apk info -e opl-netfleet >/dev/null 2>&1 || ! apk info -e luci-app-netfleet >/dev/null 2>&1; then
	apk --timeout 300 add opl-netfleet luci-app-netfleet
fi
# Named upgrades leave satisfied system dependencies and newer plugins installed.
apk --timeout 300 upgrade "$@"

# First full installation exposes the optional management page without enabling
# interception. Existing installations retain the administrator's load choice.
if [ "$load_https" = 1 ]; then
 ucode - "$work/load-https.json" <<'UC'
import * as fs from 'fs';
const main='/usr/libexec/opl-netfleet/main.uc';
function quote(value) { return "'"+replace(value, /'/g, "'\\''")+"'"; }
function call(args) {
 const p=fs.popen(`ucode ${main} ${args}`),r=json(p.read('all')),rc=p.close();
 if(rc||r?.ok!==true) die(sprintf('HTTPS management load failed: %J',r));
 return r.result;
}
const row=filter(call('plugins-list').plugins,p=>p.id=='https-compat'&&p.instance=='default')[0];
if(!row) die('HTTPS management package missing');
if(!row.loaded) {
 fs.writefile(ARGV[0],sprintf('%J',{request:{id:row.id,action:'load',revision:row.revision,confirm:true}}));
 fs.chmod(ARGV[0],0600);
 call(`plugin-call ${quote(ARGV[0])}`);
}
UC
fi

printf 'NetFleet packages installed from %s; open LuCI to review and confirm first takeover.\n' "$feed_base"
