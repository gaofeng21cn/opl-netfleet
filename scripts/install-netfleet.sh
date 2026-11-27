#!/bin/sh
set -eu
umask 077

die() {
	printf 'install-netfleet: %s\n' "$1" >&2
	exit 1
}

[ "${NETFLEET_INSTALL_TESTING:-0}" = 1 ] || [ "$(id -u)" = 0 ] ||
	die 'must run as root on OpenWrt'

pkg_mgr=
if command -v apk >/dev/null 2>&1; then
	pkg_mgr=apk
elif command -v opkg >/dev/null 2>&1; then
	pkg_mgr=opkg
else
	die 'OpenWrt APK or OPKG package manager is required'
fi

command -v uci >/dev/null 2>&1 || die 'OpenWrt UCI is required'
command -v jsonfilter >/dev/null 2>&1 || die 'OpenWrt jsonfilter is required'

if [ "$pkg_mgr" = apk ]; then
	# Layout migrations need their own rollback qualification, including optional packages.
	if apk info -e opl-netfleet >/dev/null 2>&1 && ! apk info -e opl-netfleet-kernel >/dev/null 2>&1 && [ ! -e /usr/share/opl-netfleet/shell.json ]; then
		die 'legacy monolith migration requires a qualified package transaction; installed packages were not changed'
	fi
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

if [ "$pkg_mgr" = opkg ] && [ "$install_profile" = full ]; then
	die 'full compatibility engine profile is only available on apk targets'
fi

load_https=0
if [ "$pkg_mgr" = apk ] && [ "$install_profile" = full ] && ! apk info -e opl-netfleet-plugin-https-compat >/dev/null 2>&1; then
	load_https=1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/netfleet-install.XXXXXX")
cleanup() {
	rm -rf -- "$work"
}
trap cleanup EXIT INT TERM

write_release_feed() {
	if [ -n "${NETFLEET_RELEASE_FEED_FILE:-}" ]; then
		release_feed_file=$NETFLEET_RELEASE_FEED_FILE
	elif [ "${NETFLEET_INSTALL_TESTING:-0}" = 1 ]; then
		release_feed_file="$(dirname "${NETFLEET_APK_REPOSITORY_FILE:-${NETFLEET_OPKG_CUSTOMFEEDS_FILE:-$work/release-feed.json}}")/release-feed.json"
	else
		release_feed_file=/etc/opl-netfleet/release-feed.json
	fi
	mkdir -p "$(dirname "$release_feed_file")"
	case "$feed_base" in
		https://*)
			printf '{"schema":"opl-netfleet-release-feed.v1","url":"%s"}\n' "$feed_base" >"$release_feed_file.$$"
			;;
		http://*)
			[ "${NETFLEET_ALLOW_INSECURE_FEED:-0}" = 1 ] || die 'HTTP feed requires NETFLEET_ALLOW_INSECURE_FEED=1'
			printf '{"schema":"opl-netfleet-release-feed.v1","url":"%s","allow_insecure":true}\n' "$feed_base" >"$release_feed_file.$$"
			;;
		*) die 'feed URL must use HTTPS' ;;
	esac
	chmod 0600 "$release_feed_file.$$"
	mv -f "$release_feed_file.$$" "$release_feed_file"
}

fetch() {
	url=$1
	destination=$2
	if command -v curl >/dev/null 2>&1; then
		curl -q -fsSL --connect-timeout 10 --max-time 90 -o "$destination" "$url"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$destination" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$destination" "$url"
	else
		die 'uclient-fetch, wget, or curl is required'
	fi
}

if [ "$pkg_mgr" = opkg ]; then
	command -v usign >/dev/null 2>&1 || die 'OpenWrt usign is required for opkg signature verification'
	command -v gzip >/dev/null 2>&1 || die 'gzip is required for opkg feed verification'

	opkg_key_name=opl-netfleet-usign.pub
	fetch "$feed_base/$opkg_key_name" "$work/$opkg_key_name"
	[ -s "$work/$opkg_key_name" ] || die 'downloaded usign public key is empty'
	grep -Fq -- 'untrusted comment:' "$work/$opkg_key_name" || die 'downloaded usign public key is invalid'
	key_id=$(usign -F -p "$work/$opkg_key_name" 2>/dev/null || true)
	case "$key_id" in
		''|*[!0-9a-f]*) die 'invalid usign key fingerprint' ;;
	esac
	[ "${#key_id}" -eq 16 ] || die 'invalid usign key fingerprint length'

	fetch "$feed_base/Packages.gz" "$work/Packages.gz"
	fetch "$feed_base/Packages.sig" "$work/Packages.sig"
	gzip -dc "$work/Packages.gz" >"$work/Packages" || die 'downloaded Packages.gz is corrupted'
	usign -V -p "$work/$opkg_key_name" -x "$work/Packages.sig" -m "$work/Packages" >/dev/null 2>&1 ||
		die 'opkg feed index signature verification failed'

	opkg_keys_dir=${NETFLEET_OPKG_KEYS_DIR:-/etc/opkg/keys}
	opkg_feeds_file=${NETFLEET_OPKG_CUSTOMFEEDS_FILE:-/etc/opkg/customfeeds.conf}
	mkdir -p "$opkg_keys_dir" "$(dirname "$opkg_feeds_file")"

	cp "$work/$opkg_key_name" "$opkg_keys_dir/.$key_id.$$"
	chmod 0644 "$opkg_keys_dir/.$key_id.$$"
	mv -f "$opkg_keys_dir/.$key_id.$$" "$opkg_keys_dir/$key_id"

	feeds_staged="$opkg_feeds_file.$$"
	if [ -f "$opkg_feeds_file" ]; then
		grep -Ev '^[[:space:]]*src(/gz)?[[:space:]]+opl_netfleet([[:space:]]|$)' "$opkg_feeds_file" >"$feeds_staged" || true
	else
		: >"$feeds_staged"
	fi
	printf 'src/gz opl_netfleet %s\n' "$feed_base" >>"$feeds_staged"
	chmod 0644 "$feeds_staged"
	mv -f "$feeds_staged" "$opkg_feeds_file"

	write_release_feed

	for index_attempt in 1 2 3; do
		if opkg update; then break; fi
		[ "$index_attempt" -lt 3 ] || die 'opkg package indexes unavailable; packages were not changed'
		sleep "$((index_attempt * 2))"
	done

	set -- opl-netfleet luci-app-netfleet
	if opkg list-installed mihomo-meta 2>/dev/null | grep -Eq '^mihomo-meta '; then
		set -- "$@" mihomo-meta
	elif [ ! -e /etc/init.d/nikki ] && { { ! command -v mihomo >/dev/null 2>&1 && [ ! -e /usr/bin/mihomo ]; } || { [ -L /usr/bin/mihomo ] && [ "$(readlink /usr/bin/mihomo 2>/dev/null || true)" = /usr/libexec/mihomo ]; }; }; then
		set -- "$@" mihomo-meta
	fi

	to_install=
	to_upgrade=
	for pkg in "$@"; do
		if opkg list-installed "$pkg" 2>/dev/null | grep -Eq "^${pkg} "; then
			to_upgrade="$to_upgrade $pkg"
		else
			to_install="$to_install $pkg"
		fi
	done
	if [ -n "$to_install" ]; then
		opkg install $to_install
	fi
	if [ -n "$to_upgrade" ]; then
		opkg upgrade $to_upgrade
	fi
	printf 'NetFleet packages installed from %s; open LuCI to review and confirm first takeover.\n' "$feed_base"
	exit 0
fi

# OpenWrt APK invokes wget through PATH. Keep the reliable curl transport local
# to this installer; APK still authenticates all indexes and package contents.
if command -v curl >/dev/null 2>&1; then
	mkdir "$work/apk-fetch"
	cat >"$work/apk-fetch/wget" <<'FETCH'
#!/bin/sh
set -eu
limit=90
destination=-
url=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-q) shift ;;
		-T) limit=$2; shift 2 ;;
		-O) destination=$2; shift 2 ;;
		http://*|https://*) [ -z "$url" ] || exit 2; url=$1; shift ;;
		*) exit 2 ;;
	esac
done
case "$limit" in ''|*[!0-9]*) exit 2 ;; esac
[ "$limit" -gt 0 ] || limit=90
[ -n "$url" ] || exit 2
exec curl -q -fsSL --proto '=http,https' --proto-redir '=http,https' \
	--connect-timeout 10 --max-time "$limit" --output "$destination" "$url"
FETCH
	chmod 0700 "$work/apk-fetch/wget"
	PATH="$work/apk-fetch:$PATH"
	export PATH
fi

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
 # Fail before persisting a dead optional source. The package manager verifies
 # this index with its supplied public key before any repository change.
 fetch "$compat_feed/compat-packages.adb" "$work/compat-packages.adb"
 mkdir "$work/trusted"
 cp "$work/compat-public-key.pem" "$work/trusted/compat-public-key.pem"
 apk verify --keys-dir "$work/trusted" "$work/compat-packages.adb" >/dev/null || die 'invalid compatibility signed index'
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
write_release_feed
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
	--format json --fields depends,provides opl-netfleet >"$work/product.json"
dependencies=$(jsonfilter -i "$work/product.json" -e '@[*].depends[*]' 2>/dev/null || true)
provides=$(jsonfilter -i "$work/product.json" -e '@[*].provides[*]' 2>/dev/null || true)
set -- opl-netfleet luci-app-netfleet
set -f
has_legacy=0
for dependency in $dependencies; do
	name=${dependency%%[\<\>\=\~]*}
	case "$name" in
		opl-netfleet-kernel|opl-netfleet-plugin-*)
			case "$name" in *[!a-z0-9-]*) die 'invalid product package name' ;; esac
			set -- "$@" "$name"
			has_legacy=1
			;;
	esac
done
set +f
if [ "$has_legacy" = 0 ]; then
	is_thin_shell=0
	for cap in $provides; do
		case "${cap%%=*}" in
			netfleet-plugin-api-v1) is_thin_shell=1 ;;
		esac
	done
	[ "$is_thin_shell" = 1 ] || die 'product package dependencies are missing'
	if apk info -e mihomo-meta >/dev/null 2>&1; then
		set -- "$@" mihomo-meta
	elif [ ! -e /etc/init.d/nikki ] && { { ! command -v mihomo >/dev/null 2>&1 && [ ! -e /usr/bin/mihomo ]; } || { [ -L /usr/bin/mihomo ] && [ "$(readlink /usr/bin/mihomo 2>/dev/null || true)" = /usr/libexec/mihomo ]; }; }; then
		set -- "$@" mihomo-meta
	fi
fi
if [ "$install_profile" = full ]; then
	if [ "$has_legacy" = 1 ]; then
		set -- "$@" opl-netfleet-plugin-https-compat opl-netfleet-https-compat opl-netfleet-plugin-device-identity
	else
		set -- "$@" opl-netfleet-https-compat opl-netfleet-plugin-device-identity
	fi
	# Resolve the entire composition before installing any package. No service
	# enable action is issued here; package hooks preserve existing user choices.
	apk --timeout 300 --simulate add "$@" >/dev/null || die 'full installation dependencies unavailable; packages were not changed'
	apk --timeout 300 add "$@"
	apk --timeout 300 upgrade "$@"
elif [ "$has_legacy" = 0 ] && apk info -e opl-netfleet-kernel >/dev/null 2>&1; then
	# Migrate 28-pkg installation (opl-netfleet-kernel + 24 built-in plugin APKs) to Release Bundle thin shell.
	mkdir -p "$work/apks"
	apk --timeout 300 fetch --output "$work/apks" "$@" >/dev/null ||
		die 'failed to fetch thin-shell packages; existing installation was not changed'
	for pkg_file in "$work/apks"/*.apk; do
		[ -f "$pkg_file" ] || die 'thin-shell package download missing; existing installation was not changed'
		apk --no-network verify "$pkg_file" >/dev/null ||
			die 'thin-shell package signature verification failed; existing installation was not changed'
	done
	upgrade_state=/tmp/opl-netfleet-package-upgrade-state
	[ ! -e "$upgrade_state" ] || die 'previous package upgrade state is incomplete; refusing migration'
	backend=nikki-mihomo
	if [ -e /etc/opl-netfleet/backend.json ]; then
		backend=$(jsonfilter -i /etc/opl-netfleet/backend.json -e '@.kind') || die 'cannot read backend identity'
	fi
	case "$backend" in nikki-mihomo|native-mihomo) ;; *) die "invalid backend identity: $backend" ;; esac
	was_enabled=0; was_running=0; core_enabled=0; core_running=0
	if [ -x /etc/init.d/opl-netfleet ]; then
		/etc/init.d/opl-netfleet enabled >/dev/null 2>&1 && was_enabled=1 || true
		/etc/init.d/opl-netfleet running >/dev/null 2>&1 && was_running=1 || true
	fi
	if [ "$backend" = native-mihomo ] && [ -x /etc/init.d/opl-netfleet-core ]; then
		/etc/init.d/opl-netfleet-core enabled >/dev/null 2>&1 && core_enabled=1 || true
		/etc/init.d/opl-netfleet-core running >/dev/null 2>&1 && core_running=1 || true
	fi
	umask 077
	printf '%s %s %s %s %s\n' "$backend" "$was_enabled" "$was_running" "$core_enabled" "$core_running" >"$upgrade_state" ||
		die 'cannot snapshot service state before migration'
	: >/tmp/opl-netfleet-microkernel-migration || die 'cannot mark migration state'
	if [ -x /etc/init.d/opl-netfleet ] && /etc/init.d/opl-netfleet running >/dev/null 2>&1; then
		/etc/init.d/opl-netfleet stop >/dev/null 2>&1 || die 'failed to stop opl-netfleet before migration'
	fi
	if [ "$backend" = native-mihomo ] && [ -x /etc/init.d/opl-netfleet-core ] && /etc/init.d/opl-netfleet-core running >/dev/null 2>&1; then
		/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1 || die 'failed to stop opl-netfleet-core before migration'
	fi
	legacy_del='opl-netfleet-kernel'
	for inst in $(apk info 2>/dev/null | grep -E '^opl-netfleet-plugin-' || true); do
		[ "$inst" = opl-netfleet-plugin-device-identity ] && continue
		legacy_del="$legacy_del $inst"
	done
	negated=
	for p in $legacy_del; do
		negated="$negated !$p"
	done
	if ! apk --timeout 300 add --upgrade "$@" $negated; then
		apk --no-network del $legacy_del || die 'failed to remove legacy built-in plugin packages'
		apk --no-network add --upgrade "$work/apks"/*.apk || die 'failed to install verified thin-shell packages after legacy removal'
	fi
	[ -e /usr/share/opl-netfleet/shell.json ] && [ -f /usr/share/opl-netfleet/current/runtime/kernel/host.uc ] ||
		die 'thin-shell migration post-install layout verification failed'
elif ! apk info -e opl-netfleet >/dev/null 2>&1 || ! apk info -e luci-app-netfleet >/dev/null 2>&1; then
	apk --timeout 300 add "$@"
	apk --timeout 300 upgrade "$@"
else
	apk --timeout 300 upgrade "$@"
fi

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
