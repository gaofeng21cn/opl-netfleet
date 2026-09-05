#!/bin/sh
set -eu
umask 077

source_commit=${1:?}
source_tree=${2:?}
manifest_sha=${3:?}
probe_port=${4:?}
feed_url=${5:?}
fixture=/tmp/netfleet-runtime-fixture
candidate=$fixture/feed-readback
probe_url=https://netfleet-probe.test:$probe_port/generate_204
stage=feed_readback

finish() {
	rc=$?
	trap - EXIT INT TERM
	if [ "$rc" -eq 0 ] && [ "$stage" != complete ]; then
		echo "OpenWrt package qualification exited before completion at stage: $stage" >&2
		rc=1
	fi
	if [ "$rc" -ne 0 ]; then
		echo "OpenWrt package qualification failed at stage: $stage" >&2
		for path in "$candidate/manifest.json" "$fixture/package-onboarding.json" \
			"$fixture/package-apply.json" "$fixture/package-disable.json" \
			"$fixture/package-status.json" \
			"$fixture/package-info.after" \
			"$fixture/package-rpcd-direct.json" "$fixture/package-rpcd-ubus.txt" \
			"$fixture/package-helper-primary.log" "$fixture/package-helper-reserve.log" \
			/tmp/opl-netfleet-onboarding/*.json /etc/opl-netfleet/policy.json \
			/etc/nikki/profiles/opl-netfleet/mvp.manifest.json; do
			[ ! -s "$path" ] || { echo "--- $path" >&2; cat "$path" >&2; }
		done
		ps w >&2 || true
		netstat -lnt >&2 || true
		tail -n 100 "$fixture/package-manager.log" >&2 || true
		logread | tail -n 100 >&2 || true
	fi
	exit "$rc"
}
trap finish EXIT INT TERM

mkdir -p "$candidate"
uclient-fetch -q -O "$candidate/manifest.json" "$feed_url/manifest.json"
uclient-fetch -q -O "$candidate/install-netfleet.sh" "$feed_url/install-netfleet.sh"
uclient-fetch -q -O "$candidate/FILES.sha256" "$feed_url/FILES.sha256"
[ "$(sha256sum "$candidate/manifest.json" | awk '{print $1}')" = "$manifest_sha" ]
[ "$(jsonfilter -i "$candidate/manifest.json" -e '@.source_commit')" = "$source_commit" ]
[ "$(jsonfilter -i "$candidate/manifest.json" -e '@.source_tree')" = "$source_tree" ]
[ "$(jsonfilter -i "$candidate/manifest.json" -e '@.package_format')" = apk ]
[ "$(jsonfilter -i "$candidate/manifest.json" -e '@.package_arch')" = noarch ]
[ "$(jsonfilter -i "$candidate/manifest.json" -e '@.build_target_arch')" = aarch64_generic ]

runtime_apk=$(ucode -e '
	import { readfile } from "fs";
	const manifest = json(readfile(ARGV[0]));
	print(manifest?.artifact_files?.["opl-netfleet"] ?? "");
' "$candidate/manifest.json")
luci_apk=$(ucode -e '
	import { readfile } from "fs";
	const manifest = json(readfile(ARGV[0]));
	print(manifest?.artifact_files?.["luci-app-netfleet"] ?? "");
' "$candidate/manifest.json")
case "$runtime_apk $luci_apk" in
	*/*|*'..'*) exit 1 ;;
esac
bootstrap_sha=$(jsonfilter -i "$candidate/manifest.json" -e '@.feed_bootstrap.sha256')
[ "$(sha256sum "$candidate/install-netfleet.sh" | awk '{print $1}')" = "$bootstrap_sha" ]
files_sha=$(jsonfilter -i "$candidate/manifest.json" -e '@.files_manifest.sha256')
[ "$(sha256sum "$candidate/FILES.sha256" | awk '{print $1}')" = "$files_sha" ]

# Source deployments predate package ownership and exercise APK's protected
# /etc path migration. The runtime post-install must promote only these package
# baselines while leaving the user policy outside its write set.
printf '{"legacy":true}\n' >/etc/opl-netfleet/policy.example.json
printf '{"legacy":true}\n' >/etc/opl-netfleet/policy-sources/base-v1.json
printf '{"legacy":true}\n' >/etc/opl-netfleet/rulesets.lock.json
policy_before=absent
if [ -e /etc/opl-netfleet/policy.json ]; then
	policy_before=$(sha256sum /etc/opl-netfleet/policy.json | awk '{print $1}')
fi

stage=install
real_apk=$(command -v apk)
[ -x "$real_apk" ]
PATH="$fixture/bin:$PATH"
export PATH
: >"$fixture/package-manager.log"
printf 'apk_command=%s\n' "$real_apk" >>"$fixture/package-manager.log"
"$real_apk" list --manifest >"$fixture/package-manifest.before"
# Require the feed to satisfy the real core dependency on first installation.
[ -z "$(pidof mihomo || true)" ]
rm -f /usr/bin/mihomo
cp "$fixture/bin/yq" /usr/bin/yq
env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin yq --version | grep -Fq 'v4.53.6'
# Keep a satisfied but older dependency to catch accidental recursive upgrades.
# The executable above remains the real yq; only fixture package metadata is old.
"$real_apk" --timeout 300 add --virtual yq=0.0.1-r1 \
	>>"$fixture/package-manager.log" 2>&1
NETFLEET_FEED_BASE="$feed_url" NETFLEET_ALLOW_INSECURE_FEED=1 \
	sh "$candidate/install-netfleet.sh" >>"$fixture/package-manager.log" 2>&1
"$real_apk" info -e mihomo-meta >>"$fixture/package-manager.log" 2>&1
[ "$(readlink /usr/bin/mihomo)" = /usr/libexec/mihomo ]
env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin mihomo -v | grep -Fq 'v1.19.30'
core_sha=$(sha256sum /usr/libexec/mihomo | awk '{print $1}')
[ "$(cat /etc/apk/repositories.d/opl-netfleet.list)" = "$feed_url/packages.adb" ]
[ -s /etc/apk/keys/opl-netfleet-apk.pem ]
! /etc/init.d/opl-netfleet enabled >/dev/null 2>&1
! /etc/init.d/opl-netfleet running >/dev/null 2>&1
if [ "$policy_before" = absent ]; then
	[ ! -e /etc/opl-netfleet/policy.json ]
else
	[ -f /etc/opl-netfleet/policy.json ]
	[ "$(sha256sum /etc/opl-netfleet/policy.json | awk '{print $1}')" = "$policy_before" ]
fi

stage=feed_upgrade
before_upgrade=$("$real_apk" list --manifest)
NETFLEET_FEED_BASE="$feed_url" NETFLEET_ALLOW_INSECURE_FEED=1 \
	sh "$candidate/install-netfleet.sh" >>"$fixture/package-manager.log" 2>&1
after_upgrade=$("$real_apk" list --manifest)
[ "$after_upgrade" = "$before_upgrade" ]
[ "$(sha256sum /usr/libexec/mihomo | awk '{print $1}')" = "$core_sha" ]
"$real_apk" list --manifest | grep -Fqx 'yq 0.0.1-r1'

stage=package_database
version=$(jsonfilter -i "$candidate/manifest.json" -e '@.package_version')
release=$(jsonfilter -i "$candidate/manifest.json" -e '@.package_release')
installed_manifest=$("$real_apk" list --manifest)
printf '%s\n' "$installed_manifest" >"$fixture/package-manifest.after"
"$real_apk" info -e opl-netfleet luci-app-netfleet >"$fixture/package-info.after" 2>&1
printf '%s\n' "$installed_manifest" >>"$fixture/package-manager.log"
printf '%s\n' "$installed_manifest" | grep -Fqx "opl-netfleet $version-r$release"
printf '%s\n' "$installed_manifest" | grep -Fqx "luci-app-netfleet $version-r$release"
for package_name in opl-netfleet luci-app-netfleet; do
	"$real_apk" list --installed "$package_name" |
		grep -Eq "^${package_name}-${version}-r${release}[[:space:]]+noarch([[:space:]]|$)"
done
[ ! -e /etc/opl-netfleet/policy.example.json.apk-new ]
[ ! -e /etc/opl-netfleet/policy-sources/base-v1.json.apk-new ]
[ ! -e /etc/opl-netfleet/rulesets.lock.json.apk-new ]
rpcd_timeout=$(uci -q get 'rpcd.@rpcd[0].timeout')
[ "$rpcd_timeout" -ge 300 ]
uhttpd_timeout=$(uci -q get 'uhttpd.main.script_timeout')
[ "$uhttpd_timeout" -ge 300 ]

stage=package_contents
"$real_apk" info -L opl-netfleet | grep -Fqx 'usr/libexec/opl-netfleet/main.uc'
"$real_apk" info -L opl-netfleet | grep -Fqx 'usr/share/opl-netfleet/build.json'
build_identity=/usr/share/opl-netfleet/build.json
[ "$(jsonfilter -i "$build_identity" -e '@.schema')" = opl-netfleet-package-build.v1 ]
[ "$(jsonfilter -i "$build_identity" -e '@.version')" = "$version" ]
[ "$(jsonfilter -i "$build_identity" -e '@.source_commit')" = "$source_commit" ]
[ "$(jsonfilter -i "$build_identity" -e '@.source_tree')" = "$source_tree" ]
view_version=$(printf '%s' "$version" | tr '.' '_')
"$real_apk" info -L luci-app-netfleet | grep -Fqx "www/luci-static/resources/view/netfleet/overview-v${view_version}.js"

stage=installed_bytes
while read -r expected path extra; do
	[ -n "$expected" ] || continue
	[ -z "${extra:-}" ]
	[ -f "/$path" ] || { echo "Package file missing: /$path" >&2; exit 1; }
	[ "$(sha256sum "/$path" | awk '{print $1}')" = "$expected" ] || {
		echo "Package file mismatch: /$path" >&2
		exit 1
	}
done <"$candidate/FILES.sha256"
ucode -e '
	import { readfile } from "fs";
	const menu = json(readfile(ARGV[0]));
	exit(menu?.["admin/services/netfleet/overview"]?.action?.path == ARGV[1] ? 0 : 1);
' /usr/share/luci/menu.d/luci-app-netfleet.json "netfleet/overview-v${view_version}"
ucode -e '
	import { readfile } from "fs";
	const acl = json(readfile(ARGV[0]));
	const grant = acl?.["luci-app-netfleet"];
	const reads = grant?.read?.ubus?.["opl-netfleet"] ?? [];
	const writes = grant?.write?.ubus?.["opl-netfleet"] ?? [];
	for (let method in ["status", "probe", "native_setup_get", "migration_get", "subscriptions_get"])
		if (index(reads, method) < 0) exit(1);
	for (let method in ["native_setup_apply", "migration_apply", "subscriptions_set", "subscriptions_refresh"])
		if (index(writes, method) < 0 || index(reads, method) >= 0) exit(1);
' /usr/share/rpcd/acl.d/luci-app-netfleet.json

stage=rpcd
/usr/libexec/rpcd/opl-netfleet list >"$fixture/package-rpcd-direct.json"

# Package qualification restarts rpcd outside the runtime fixture's PATH, so
# model the target's real WAN contract in netifd instead of relying on its ubus
# shim. The VM's host route remains the actual upstream path.
uci -q delete network.wan || true
uci set network.wan=interface
uci set network.wan.proto=none
uci set network.wan.device=br-lan
uci commit network
ifup wan
wan_ready=false
for attempt in $(seq 1 20); do
	if [ "$(ubus call network.interface.wan status 2>/dev/null |
		jsonfilter -e '@.up' 2>/dev/null || true)" = true ]; then
		wan_ready=true
		break
	fi
	sleep 1
done
[ "$wan_ready" = true ]
ip -4 route show default | grep -q '^default '

/etc/init.d/rpcd restart >/dev/null 2>&1
rpc_ready=false
for attempt in $(seq 1 20); do
	ubus -v list opl-netfleet >"$fixture/package-rpcd-ubus.txt" 2>/dev/null || true
	if grep -q onboarding_apply "$fixture/package-rpcd-ubus.txt"; then
		rpc_ready=true
		break
	fi
	sleep 1
done
[ "$rpc_ready" = true ]

stage=onboarding_prepare
/etc/init.d/opl-netfleet stop >/dev/null 2>&1 || true
/etc/init.d/opl-netfleet disable >/dev/null 2>&1 || true
/etc/init.d/nikki stop >/dev/null 2>&1 || true
rm -f /etc/opl-netfleet/policy.json /etc/opl-netfleet/evidence.json \
	/var/lib/opl-netfleet/events.json /etc/nikki/profiles/OPL-NetFleet.json \
	/etc/nikki/profiles/opl-netfleet/mvp.json \
	/etc/nikki/profiles/opl-netfleet/mvp.manifest.json
rm -rf "$fixture/package-helper-primary" "$fixture/package-helper-reserve"
grep -Fq 'www.gstatic.com' /etc/hosts || printf '192.168.1.2 www.gstatic.com\n' >>/etc/hosts
nft add table ip netfleet_vm_probe
nft 'add chain ip netfleet_vm_probe output { type nat hook output priority -100; policy accept; }'
nft add rule ip netfleet_vm_probe output ip daddr 192.168.1.2 tcp dport 443 \
	dnat to "192.168.1.2:$probe_port"
"$fixture/bin/netfleet-test-primary" -d "$fixture/package-helper-primary" \
	-f "$fixture/helper-primary.json" >"$fixture/package-helper-primary.log" 2>&1 &
"$fixture/bin/netfleet-test-reserve" -d "$fixture/package-helper-reserve" \
	-f "$fixture/helper-reserve.json" >"$fixture/package-helper-reserve.log" 2>&1 &
helpers_ready=false
for attempt in $(seq 1 20); do
	if curl -fsS --socks5-hostname 127.0.0.1:1081 --connect-timeout 2 --max-time 5 \
		"$probe_url" >/dev/null && \
		curl -fsS --socks5-hostname 127.0.0.1:1082 --connect-timeout 2 --max-time 5 \
			"$probe_url" >/dev/null; then
		helpers_ready=true
		break
	fi
	[ "$attempt" -lt 20 ] || exit 1
	sleep 1
done
[ "$helpers_ready" = true ]
cat >/etc/nikki/subscriptions/base.yaml <<'EOF'
mixed-port: 7890
tproxy-port: 7892
allow-lan: true
external-controller: 0.0.0.0:9090
secret: netfleet-vm-fixture
mode: rule
log-level: info
ipv6: false
hosts:
  www.gstatic.com: 192.168.1.2
proxies:
  - name: Base SOCKS
    type: socks5
    server: 127.0.0.1
    port: 1081
proxy-groups:
  - name: VM Egress
    type: select
    proxies:
      - Base SOCKS
      - DIRECT
rules:
  - MATCH,VM Egress
EOF
cat >/etc/nikki/subscriptions/alpha.yaml <<'EOF'
proxies:
  - name: Alpha Japan 01
    type: socks5
    server: 127.0.0.1
    port: 1081
  - name: Alpha Singapore 01
    type: socks5
    server: 127.0.0.1
    port: 1081
EOF
cat >/etc/nikki/subscriptions/beta.yaml <<'EOF'
proxies:
  - name: Beta Japan 01
    type: socks5
    server: 127.0.0.1
    port: 1082
  - name: Beta Singapore 01
    type: socks5
    server: 127.0.0.1
    port: 1082
EOF
uci set nikki.config.enabled=1
uci set nikki.config.profile=subscription:base
uci set nikki.mixin.api_secret=netfleet-vm-fixture
uci set nikki.mixin.api_listen=0.0.0.0:9090
uci set nikki.mixin.allow_lan=1
uci set nikki.mixin.dns_enabled=1
uci set nikki.mixin.dns_listen='[::]:1053'
uci commit nikki
yq -M -p yaml -o json /etc/nikki/subscriptions/base.yaml >/dev/null
yq -M -p yaml -o json /etc/nikki/subscriptions/alpha.yaml >/dev/null
yq -M -p yaml -o json /etc/nikki/subscriptions/beta.yaml >/dev/null
/etc/init.d/nikki start >/dev/null 2>&1
runtime_ready=false
for attempt in $(seq 1 20); do
	if /etc/init.d/nikki running >/dev/null 2>&1 && \
		curl -fsS --connect-timeout 2 --max-time 3 \
			-H 'Authorization: Bearer netfleet-vm-fixture' http://127.0.0.1:9090/version >/dev/null; then
		runtime_ready=true
		break
	fi
	sleep 1
done
[ "$runtime_ready" = true ]
[ "$(uci -q get nikki.config.enabled)" = 1 ]
[ "$(uci -q get nikki.config.profile)" = subscription:base ]
[ -s /etc/nikki/subscriptions/base.yaml ]
[ -s /etc/nikki/subscriptions/alpha.yaml ]
[ -s /etc/nikki/subscriptions/beta.yaml ]
[ ! -e /etc/nikki/profiles/OPL-NetFleet.json ]
[ ! -e /etc/nikki/profiles/opl-netfleet/mvp.json ]
[ ! -e /etc/nikki/profiles/opl-netfleet/mvp.manifest.json ]

stage=onboarding_get
ubus call opl-netfleet onboarding_get '{}' >"$fixture/package-onboarding.json"
[ "$(jsonfilter -i "$fixture/package-onboarding.json" -e '@.result.required')" = true ]
[ "$(jsonfilter -i "$fixture/package-onboarding.json" -e '@.result.ready')" = true ]
revision=$(jsonfilter -i "$fixture/package-onboarding.json" -e '@.result.revision')
[ -n "$revision" ]

stage=onboarding_apply
ubus -t 300 call opl-netfleet onboarding_apply \
	"{\"request\":{\"revision\":\"$revision\",\"confirmed\":true}}" >"$fixture/package-apply.json"
[ "$(jsonfilter -i "$fixture/package-apply.json" -e '@.result.state')" = active ]
cat >/etc/opl-netfleet/installed.json <<'EOF'
{"product_version":"0.0.1","source_commit":"0000000000000000000000000000000000000000","source_tree":"1111111111111111111111111111111111111111"}
EOF
ubus call opl-netfleet status '{}' >"$fixture/package-status.json"
[ "$(jsonfilter -i "$fixture/package-status.json" -e '@.result.build.version')" = "$version" ]
[ "$(jsonfilter -i "$fixture/package-status.json" -e '@.result.build.source_commit')" = "$source_commit" ]
[ "$(jsonfilter -i "$fixture/package-status.json" -e '@.result.build.source_tree')" = "$source_tree" ]
rm -f /etc/opl-netfleet/installed.json
[ "$(uci -q get nikki.config.profile)" = file:OPL-NetFleet.json ]
/etc/init.d/opl-netfleet status >/dev/null 2>&1

stage=probe_rpc
ubus call opl-netfleet probe '{}' >"$fixture/package-probe.json"
[ "$(jsonfilter -i "$fixture/package-probe.json" -e '@.ok')" = true ]
[ "$(jsonfilter -i "$fixture/package-probe.json" -e '@.result.ok')" = true ]

stage=disable
ubus call opl-netfleet disable '{}' >"$fixture/package-disable.json"
[ "$(jsonfilter -i "$fixture/package-disable.json" -e '@.result.state')" = native_profile ]
[ "$(uci -q get nikki.config.profile)" = subscription:base ]
/etc/init.d/nikki running >/dev/null 2>&1

stage=uninstall
"$real_apk" del luci-app-netfleet opl-netfleet >>"$fixture/package-manager.log" 2>&1
! "$real_apk" info -e opl-netfleet >/dev/null 2>&1
! "$real_apk" info -e luci-app-netfleet >/dev/null 2>&1
[ "$(uci -q get nikki.config.profile)" = subscription:base ]
/etc/init.d/nikki running >/dev/null 2>&1
[ ! -e /etc/nikki/profiles/OPL-NetFleet.json ]
[ ! -e /etc/nikki/profiles/opl-netfleet/mvp.json ]
[ ! -e /etc/nikki/profiles/opl-netfleet/mvp.manifest.json ]
[ ! -e /usr/libexec/opl-netfleet/main.uc ]
[ ! -e /usr/share/luci/menu.d/luci-app-netfleet.json ]

stage=complete
printf '{"ok":true,"source_commit":"%s","source_tree":"%s","manifest_sha256":"%s","package_version":"%s","package_release":"%s","package_format":"apk","package_arch":"noarch","build_target_arch":"aarch64_generic","checks":{"manifest":true,"signing_key":true,"feed_bootstrap":true,"feed_install":true,"feed_install_inactive":true,"feed_upgrade_transaction":true,"package_database":true,"package_metadata":true,"installed_bytes":true,"package_build_identity":true,"package_identity_precedence":true,"luci_menu":true,"rpcd_acl":true,"rpcd_methods":true,"onboarding_get":true,"onboarding_apply":true,"probe_rpc":true,"disable_native":true,"uninstall":true,"active_artifact_removed":true}}\n' \
	"$source_commit" "$source_tree" "$manifest_sha" "$version" "$release"
