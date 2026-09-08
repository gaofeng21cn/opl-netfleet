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
main=/usr/libexec/opl-netfleet/main.uc
legacy_upgraded=false
legacy_source_commit=
legacy_source_tree=
legacy_artifacts='[]'
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
			"$fixture"/lifecycle-*.json "$fixture"/lifecycle-*.log \
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

owner_locked() {
	(
		exec 9>/var/lock/opl-netfleet-deploy.lock
		flock 9
		"$@" 9>&-
	)
}
package_transaction() {
	owner_locked "$real_apk" --no-network add "$@" >>"$fixture/package-manager.log" 2>&1
}
lifecycle_snapshot() {
	sha256sum /etc/config/nikki /etc/opl-netfleet/policy.json \
		/etc/nikki/subscriptions/base.yaml /etc/nikki/subscriptions/alpha.yaml \
		/etc/nikki/subscriptions/beta.yaml /etc/nikki/profiles/OPL-NetFleet.json \
		/etc/nikki/profiles/opl-netfleet/mvp.manifest.json >"$fixture/${1}.inputs"
	for path in /etc/config/netfleet /etc/opl-netfleet/backend.json; do
		if [ -f "$path" ]; then
			sha256sum "$path" >>"$fixture/${1}.inputs"
		else
			printf 'absent %s\n' "$path" >>"$fixture/${1}.inputs"
		fi
	done
	curl -fsS --connect-timeout 2 --max-time 5 -H 'Authorization: Bearer netfleet-vm-fixture' \
		http://127.0.0.1:9090/proxies >"$fixture/${1}.proxies"
	ucode -e 'import { readfile } from "fs";
		const proxies = json(readfile(ARGV[0])).proxies;
		const result = {}; for (let name in sort(keys(proxies)))
			if (proxies[name].type == "Selector") result[name] = proxies[name].now;
		printf("%J\n", result);' "$fixture/${1}.proxies" >"$fixture/${1}.routes"
}
lifecycle_restored() {
	ucode "$main" status >"$fixture/lifecycle-status.json"
	[ "$(jsonfilter -i "$fixture/lifecycle-status.json" -e '@.result.active')" = true ]
	/etc/init.d/opl-netfleet running >/dev/null 2>&1
	/etc/init.d/nikki running >/dev/null 2>&1
	ucode "$main" probe >"$fixture/lifecycle-probe.json"
	[ "$(jsonfilter -i "$fixture/lifecycle-probe.json" -e '@.result.ok')" = true ]
	lifecycle_snapshot after
	cmp "$fixture/${1}.inputs" "$fixture/after.inputs"
	cmp "$fixture/${1}.routes" "$fixture/after.routes"
	for marker in .kernel .kernel-plugins .coordinator; do
		[ ! -e "/var/run/opl-netfleet-plugin-maintenance/$marker" ]
	done
	for record in /var/run/opl-netfleet-plugin-maintenance/.resources/*.json \
		/var/run/opl-netfleet-plugin-maintenance/*/state.json; do
		[ ! -e "$record" ]
	done
	[ ! -e /var/run/opl-netfleet-mihomo-handoff/state.json ]
	[ ! -e /tmp/opl-netfleet-package-upgrade-state ]
	[ ! -e /tmp/opl-netfleet-microkernel-migration ]
}

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

stage=kernel_only_install
real_apk=$(command -v apk)
[ -x "$real_apk" ]
PATH="$fixture/bin:$PATH"
export PATH
: >"$fixture/package-manager.log"
printf 'apk_command=%s\n' "$real_apk" >>"$fixture/package-manager.log"
"$real_apk" list --manifest >"$fixture/package-manifest.before"
! "$real_apk" info -e opl-netfleet-kernel >/dev/null 2>&1
[ -z "$(pidof mihomo || true)" ]
saved_runtime=$fixture/kernel-only-source
mkdir -p "$saved_runtime"
mv /usr/libexec/opl-netfleet "$saved_runtime/runtime"
mv /usr/share/opl-netfleet "$saved_runtime/shared"
mv /etc/opl-netfleet "$saved_runtime/configuration"
mv /usr/libexec/opl-netfleet-plugin-package "$saved_runtime/package-helper"
[ ! -e /etc/opl-netfleet ]
kernel_apk=$(jsonfilter -i "$candidate/manifest.json" -e '@.artifact_files["opl-netfleet-kernel"]')
uclient-fetch -q -O "$candidate/$kernel_apk" "$feed_url/$kernel_apk"
uclient-fetch -q -O /etc/apk/keys/opl-netfleet-apk.pem "$feed_url/opl-netfleet-apk.pem"
[ "$(sha256sum /etc/apk/keys/opl-netfleet-apk.pem | awk '{print $1}')" = \
	"$(jsonfilter -i "$candidate/manifest.json" -e '@.apk_public_key.sha256')" ]
owner_locked "$real_apk" --timeout 300 add "$candidate/$kernel_apk" >>"$fixture/package-manager.log" 2>&1
[ -d /etc/opl-netfleet ]
[ ! -e /usr/share/opl-netfleet/system.json ]
stage=kernel_only_service_lifecycle
mkdir -p /usr/libexec/opl-netfleet/plugins
cp -R /tmp/examples/plugins/host-info /usr/libexec/opl-netfleet/plugins/host-info
for plugin_action in load reload unload; do
	ucode "$main" plugins-list >"$fixture/lifecycle-kernel-inventory.json"
	plugin_revision=$(jsonfilter -i "$fixture/lifecycle-kernel-inventory.json" -e '@.result.plugins[0].revision')
	[ "$(jsonfilter -i "$fixture/lifecycle-kernel-inventory.json" -e '@.result.plugins[0].id')" = host-info ]
	[ -n "$plugin_revision" ]
	printf '{"request":{"id":"host-info","action":"%s","confirm":true,"revision":"%s"}}\n' \
		"$plugin_action" "$plugin_revision" >"$fixture/kernel-only-request.json"
	ucode "$main" plugin-call "$fixture/kernel-only-request.json" >"$fixture/lifecycle-kernel-$plugin_action.json"
	[ "$(jsonfilter -i "$fixture/lifecycle-kernel-$plugin_action.json" -e '@.ok')" = true ]
	[ -f /etc/opl-netfleet/system.json ]
	if [ "$plugin_action" != unload ]; then
		ucode "$main" host-info >"$fixture/lifecycle-kernel-feature.json"
		[ "$(jsonfilter -i "$fixture/lifecycle-kernel-feature.json" -e '@.ok')" = true ]
	fi
done
if ucode "$main" host-info >"$fixture/lifecycle-kernel-unloaded.json"; then exit 1; fi
"$real_apk" del opl-netfleet-kernel >>"$fixture/package-manager.log" 2>&1
[ ! -e "$main" ]
rm -rf /usr/libexec/opl-netfleet /usr/share/opl-netfleet /etc/opl-netfleet
mv "$saved_runtime/runtime" /usr/libexec/opl-netfleet
mv "$saved_runtime/shared" /usr/share/opl-netfleet
mv "$saved_runtime/configuration" /etc/opl-netfleet
mv "$saved_runtime/package-helper" /usr/libexec/opl-netfleet-plugin-package
rmdir "$saved_runtime"

# Source deployments predate package ownership and exercise APK's protected
# /etc path migration. The configuration plugin must promote only these package
# baselines while leaving the user policy outside its write set.
printf '{"legacy":true}\n' >/etc/opl-netfleet/policy.example.json
printf '{"legacy":true}\n' >/etc/opl-netfleet/policy-sources/base-v1.json
printf '{"legacy":true}\n' >/etc/opl-netfleet/rulesets.lock.json
policy_before=absent
if [ -e /etc/opl-netfleet/policy.json ]; then
	policy_before=$(sha256sum /etc/opl-netfleet/policy.json | awk '{print $1}')
fi

stage=install
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
printf '%s\n' "$installed_manifest" >>"$fixture/package-manager.log"
ucode -e '
	import { readfile } from "fs";
	for (let artifact in json(readfile(ARGV[0])).artifacts)
		printf("%s %s-r%s\n", artifact.package, artifact.version, artifact.release);
' "$candidate/manifest.json" >"$fixture/product-packages.txt"
: >"$fixture/package-info.after"
while read -r package_name package_version; do
	"$real_apk" info -e "$package_name" >>"$fixture/package-info.after" 2>&1
	printf '%s\n' "$installed_manifest" | grep -Fqx "$package_name $package_version"
	"$real_apk" list --installed "$package_name" |
		grep -Eq "^${package_name}-${package_version}[[:space:]]+noarch([[:space:]]|$)"
done <"$fixture/product-packages.txt"
[ ! -e /etc/opl-netfleet/policy.example.json.apk-new ]
[ ! -e /etc/opl-netfleet/policy-sources/base-v1.json.apk-new ]
[ ! -e /etc/opl-netfleet/rulesets.lock.json.apk-new ]
rpcd_timeout=$(uci -q get 'rpcd.@rpcd[0].timeout')
[ "$rpcd_timeout" -ge 300 ]
uhttpd_timeout=$(uci -q get 'uhttpd.main.script_timeout')
[ "$uhttpd_timeout" -ge 300 ]

stage=package_contents
"$real_apk" info -L opl-netfleet-kernel | grep -Fqx 'usr/libexec/opl-netfleet/main.uc'
"$real_apk" info -L opl-netfleet-kernel | grep -Fqx 'usr/libexec/opl-netfleet/kernel/host.uc'
"$real_apk" info -L opl-netfleet | grep -Fqx 'usr/share/opl-netfleet/build.json'
"$real_apk" info -L opl-netfleet | grep -Fqx 'usr/share/opl-netfleet/system.json'
while read -r package_name package_version; do
	case "$package_name" in
		opl-netfleet-plugin-*)
			plugin_id=${package_name#opl-netfleet-plugin-}
			"$real_apk" info -L "$package_name" |
				grep -Fqx "usr/libexec/opl-netfleet/plugins/$plugin_id/manifest.json"
			;;
	esac
done <"$fixture/product-packages.txt"
[ ! -d /usr/libexec/opl-netfleet/application ]
[ ! -d /usr/libexec/opl-netfleet/domain ]
[ ! -d /usr/libexec/opl-netfleet/platform ]
build_identity=/usr/share/opl-netfleet/build.json
[ "$(jsonfilter -i "$build_identity" -e '@.schema')" = opl-netfleet-package-build.v1 ]
[ "$(jsonfilter -i "$build_identity" -e '@.version')" = "$version" ]
[ "$(jsonfilter -i "$build_identity" -e '@.source_commit')" = "$source_commit" ]
[ "$(jsonfilter -i "$build_identity" -e '@.source_tree')" = "$source_tree" ]
view_version=$(ucode -e 'import { readfile } from "fs";
	const artifacts = json(readfile(ARGV[0])).artifacts;
	print(replace(filter(artifacts, item => item.package == "luci-app-netfleet")[0].version, /\./g, "_"));
' "$candidate/manifest.json")
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
# The fixture supplies Nikki's files from source. Give its still-running owner
# the package dependencies used by its Mihomo process and restart script.
"$real_apk" --no-network add --virtual netfleet-vm-nikki-dependencies \
	mihomo ip-full kmod-nft-socket kmod-nft-tproxy coreutils-timeout unzip \
	>>"$fixture/package-manager.log" 2>&1
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

stage=plugin_package_upgrade
uclient-fetch -q -O "$fixture/lifecycle-fixture.json" "$feed_url/components-fixtures/fixture.json"
uclient-fetch -q -O /etc/apk/keys/netfleet-component-fixture.pem \
	"$feed_url/components-fixtures/component-fixture.pem"
lifecycle_snapshot lifecycle-before
cp /etc/apk/world "$fixture/lifecycle-world.before"
for package_name in opl-netfleet-plugin-dashboard opl-netfleet-kernel; do
	package_old=$(ucode -e 'import { readfile } from "fs";
		print(json(readfile(ARGV[0])).package_versions[ARGV[1]].old);' \
		"$fixture/lifecycle-fixture.json" "$package_name")
	package_current=$(ucode -e 'import { readfile } from "fs";
		print(json(readfile(ARGV[0])).package_versions[ARGV[1]].current);' \
		"$fixture/lifecycle-fixture.json" "$package_name")
	stage=upgrade_$package_name
	uclient-fetch -q -O "$candidate/$package_name-$package_old.apk" \
		"$feed_url/components-fixtures/good/$package_name-$package_old.apk"
	uclient-fetch -q -O "$candidate/$package_name-$package_current.apk" \
		"$feed_url/$package_name-$package_current.apk"
	core_before=$(cat /var/run/nikki/mihomo.pid)
	scheduler_before=$(ubus call service list '{"name":"opl-netfleet"}' |
		jsonfilter -e '@["opl-netfleet"].instances.*.pid')
	package_transaction "$candidate/$package_name-$package_old.apk"
	"$real_apk" list --manifest | grep -Fqx "$package_name $package_old"
	lifecycle_restored lifecycle-before
	package_transaction "$candidate/$package_name-$package_current.apk"
	"$real_apk" list --manifest | grep -Fqx "$package_name $package_current"
	lifecycle_restored lifecycle-before
	if [ "$package_name" = opl-netfleet-plugin-dashboard ]; then
		[ "$(cat /var/run/nikki/mihomo.pid)" = "$core_before" ]
		[ "$(ubus call service list '{"name":"opl-netfleet"}' |
			jsonfilter -e '@["opl-netfleet"].instances.*.pid')" = "$scheduler_before" ]
	fi
done
"$real_apk" --no-network del opl-netfleet-plugin-dashboard opl-netfleet-kernel \
	>>"$fixture/package-manager.log" 2>&1
cmp /etc/apk/world "$fixture/lifecycle-world.before"

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

if [ "$(jsonfilter -i "$fixture/lifecycle-fixture.json" -e '@.legacy.key_sha256')" ]; then
	stage=legacy_monolith_install
	uclient-fetch -q -O /etc/apk/keys/netfleet-legacy-fixture.pem \
		"$feed_url/components-fixtures/legacy/baseline.pem"
	[ "$(sha256sum /etc/apk/keys/netfleet-legacy-fixture.pem | awk '{print $1}')" = \
		"$(jsonfilter -i "$fixture/lifecycle-fixture.json" -e '@.legacy.key_sha256')" ]
	ucode -e 'import { readfile } from "fs";
		for (let artifact in json(readfile(ARGV[0])).legacy.artifacts)
			printf("%s %s\n", artifact.sha256, artifact.name);' \
		"$fixture/lifecycle-fixture.json" >"$fixture/legacy-files.txt"
	legacy_packages=
	while read -r expected filename; do
		case "$filename" in */*|*..*|"") exit 1 ;; esac
		uclient-fetch -q -O "$candidate/$filename" "$feed_url/components-fixtures/legacy/$filename"
		[ "$(sha256sum "$candidate/$filename" | awk '{print $1}')" = "$expected" ]
		legacy_packages="$legacy_packages $candidate/$filename"
	done <"$fixture/legacy-files.txt"
	legacy_dependencies=$(jsonfilter -i "$fixture/lifecycle-fixture.json" -e '@.legacy.system_dependencies[*]')
	if [ -n "$legacy_dependencies" ]; then
		owner_locked "$real_apk" --timeout 300 add $legacy_dependencies >>"$fixture/package-manager.log" 2>&1
	fi
	# The core may have been autoremove'd with the new product; resolve the old
	# product's real system dependencies from the same configured signed feeds.
	owner_locked "$real_apk" --timeout 300 add $legacy_packages >>"$fixture/package-manager.log" 2>&1
	[ -f /usr/libexec/opl-netfleet/application/native_gateway.uc ]
	[ ! -e /usr/libexec/opl-netfleet/kernel/host.uc ]
	[ "$(jsonfilter -i /usr/share/opl-netfleet/build.json -e '@.source_commit')" = \
		"$(jsonfilter -i "$fixture/lifecycle-fixture.json" -e '@.legacy.build.source_commit')" ]
	legacy_source_commit=$(jsonfilter -i /usr/share/opl-netfleet/build.json -e '@.source_commit')
	legacy_source_tree=$(jsonfilter -i /usr/share/opl-netfleet/build.json -e '@.source_tree')
	legacy_artifacts=$(ucode -e 'import { readfile } from "fs"; printf("%J", json(readfile(ARGV[0])).legacy.artifacts);' "$fixture/lifecycle-fixture.json")
	stage=legacy_monolith_activate
	owner_locked ucode "$main" compile >"$fixture/lifecycle-legacy-compile.json"
	[ "$(jsonfilter -i "$fixture/lifecycle-legacy-compile.json" -e '@.ok')" = true ]
	owner_locked ucode "$main" enable >"$fixture/lifecycle-legacy-enable.json"
	[ "$(jsonfilter -i "$fixture/lifecycle-legacy-enable.json" -e '@.ok')" = true ]
	/etc/init.d/opl-netfleet enable
	/etc/init.d/opl-netfleet start
	/etc/init.d/opl-netfleet running >/dev/null 2>&1
	lifecycle_snapshot legacy-before
	stage=legacy_monolith_upgrade
	current_packages=
	while read -r package_name package_version; do
		filename=$package_name-$package_version.apk
		uclient-fetch -q -O "$candidate/$filename" "$feed_url/$filename"
		current_packages="$current_packages $candidate/$filename"
	done <"$fixture/product-packages.txt"
	package_transaction $current_packages
	lifecycle_restored legacy-before
	/etc/init.d/opl-netfleet enabled >/dev/null 2>&1
	for directory in application domain platform; do
		[ ! -e "/usr/libexec/opl-netfleet/$directory" ]
	done
	[ -f /usr/libexec/opl-netfleet/adapters/openwrt.uc ]
	[ ! -e /usr/libexec/opl-netfleet/adapters/runtime.uc ]
	while read -r package_name package_version; do
		"$real_apk" list --manifest | grep -Fqx "$package_name $package_version"
	done <"$fixture/product-packages.txt"
	owner_locked ucode "$main" disable >"$fixture/lifecycle-legacy-disable.json"
	if "$real_apk" info -e opl-netfleet-https-compat >/dev/null 2>&1; then
		! nft list table inet netfleet_compat >/dev/null 2>&1
		timeout 60 "$real_apk" --no-network del opl-netfleet-https-compat >>"$fixture/package-manager.log" 2>&1
	fi
	product_packages=$(awk '{print $1}' "$fixture/product-packages.txt")
	"$real_apk" del $product_packages >>"$fixture/package-manager.log" 2>&1
	[ ! -e "$main" ]
	/etc/init.d/nikki running >/dev/null 2>&1
	legacy_upgraded=true
fi

stage=complete
printf '{"ok":true,"source_commit":"%s","source_tree":"%s","manifest_sha256":"%s","package_version":"%s","package_release":"%s","package_format":"apk","package_arch":"noarch","build_target_arch":"aarch64_generic","lifecycle":{"legacy_monolith_upgrade":%s,"legacy_source_commit":"%s","legacy_source_tree":"%s","legacy_artifacts":%s},"checks":{"manifest":true,"signing_key":true,"kernel_only_package_install":true,"kernel_only_service_lifecycle":true,"feed_bootstrap":true,"feed_install":true,"feed_install_inactive":true,"feed_upgrade_transaction":true,"package_database":true,"package_metadata":true,"installed_bytes":true,"package_build_identity":true,"package_identity_precedence":true,"luci_menu":true,"rpcd_acl":true,"rpcd_methods":true,"onboarding_get":true,"onboarding_apply":true,"probe_rpc":true,"independent_plugin_upgrade":true,"independent_plugin_keeps_owners_running":true,"kernel_upgrade":true,"lifecycle_restores_routes_and_private_inputs":true,"disable_native":true,"uninstall":true,"active_artifact_removed":true}}\n' \
	"$source_commit" "$source_tree" "$manifest_sha" "$version" "$release" "$legacy_upgraded" "$legacy_source_commit" "$legacy_source_tree" "$legacy_artifacts"
