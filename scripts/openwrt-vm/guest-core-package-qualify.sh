#!/bin/sh
set -eu
umask 077
p=/tmp/netfleet-core-package
main=/usr/libexec/opl-netfleet/main.uc
root=/etc/opl-netfleet/package-transactions
version=$(jsonfilter -i "$p/core-manifest.json" -e '@.version')
arch=$(jsonfilter -i "$p/core-manifest.json" -e '@.architecture')
name=$(jsonfilter -i "$p/core-manifest.json" -e '@.name')
sha=$(jsonfilter -i "$p/core-manifest.json" -e '@.sha256')
[ "$arch" = aarch64_cortex-a53 ]
[ "$(sha256sum "$p/$name" | cut -d ' ' -f1)" = "$sha" ]
apk verify "$p/$name"
mkdir "$p/extracted"
apk extract --destination "$p/extracted" "$p/$name" >/dev/null
cmp "$p/extracted/usr/libexec/mihomo" /usr/libexec/mihomo
cp /usr/libexec/mihomo "$p/before-core"
cp /etc/apk/arch "$p/before-arch"
cp /etc/apk/world "$p/before-world"
cp "$p/rollback/keys/"* /etc/apk/keys/
sha256sum /etc/config/netfleet /etc/opl-netfleet/policy.json /etc/opl-netfleet/native/subscriptions/setup.yaml >"$p/before-inputs"
# This architecture setting belongs only to the isolated guest. Never apply it
# to a real target; the production package must match that target as it stands.
/etc/init.d/opl-netfleet stop
/etc/init.d/opl-netfleet-core stop
printf '%s\n' "$arch" aarch64_generic >/etc/apk/arch
printf '%s\n' "$p/rollback/packages.adb" >/etc/apk/repositories.d/netfleet-core-fixture.list
apk --no-network --repositories-file /dev/null -X "$p/rollback/packages.adb" add mihomo-meta=1.19.29 >/dev/null
# Reproduce the existing field condition: old package record, newer binary.
cp "$p/before-core" /usr/libexec/mihomo
/etc/init.d/opl-netfleet-core start
/etc/init.d/opl-netfleet start
sleep 3
# The ARM64 reference guest also accepts its existing generic base packages;
# the candidate itself must carry the exact Cortex-A53 architecture above.
/etc/init.d/opl-netfleet stop
/etc/init.d/opl-netfleet-core stop
apk --no-network --repositories-file /dev/null add "$p/$name" >"$p/install.log" 2>&1
/etc/init.d/opl-netfleet-core start
/etc/init.d/opl-netfleet start
sleep 3
[ "$(apk query --installed --format json --fields version mihomo-meta | jsonfilter -e '@[0].version')" = "$version" ]
cmp "$p/before-core" /usr/libexec/mihomo
ucode "$main" status >"$p/status.json"
[ "$(jsonfilter -i "$p/status.json" -e '@.result.active')" = true ]
[ "$(jsonfilter -i "$p/status.json" -e '@.result.runtime.lan_runtime.dns_ready')" = true ]
[ "$(jsonfilter -i "$p/status.json" -e '@.result.runtime.lan_runtime.transparent_proxy_ready')" = true ]
ucode "$main" probe >"$p/probe.json"
[ "$(jsonfilter -i "$p/probe.json" -e '@.result.ok')" = true ]
sha256sum -c "$p/before-inputs"
# Package rollback plus preserved pre-existing binary drift. The unchanged
# automatic transaction recovery is covered by the bound base qualification.
/etc/init.d/opl-netfleet stop
/etc/init.d/opl-netfleet-core stop
apk --no-network --repositories-file /dev/null -X "$p/rollback/packages.adb" add mihomo-meta=1.19.29 >"$p/rollback.log" 2>&1
cp "$p/before-core" /usr/libexec/mihomo
/etc/init.d/opl-netfleet-core start
/etc/init.d/opl-netfleet start
sleep 3
cmp "$p/before-core" /usr/libexec/mihomo
ucode "$main" probe >"$p/rollback-probe.json"
[ "$(jsonfilter -i "$p/rollback-probe.json" -e '@.result.ok')" = true ]
[ "$(apk query --installed --format json --fields version mihomo-meta | jsonfilter -e '@[0].version')" = 1.19.29 ]
sha256sum -c "$p/before-inputs"
# Restore guest package baseline so the surrounding setup suite can finish.
/etc/init.d/opl-netfleet stop
/etc/init.d/opl-netfleet-core stop
cp "$p/before-arch" /etc/apk/arch
rm /etc/apk/repositories.d/netfleet-core-fixture.list
apk --timeout 60 add mihomo-meta=1.19.30-r1 >/dev/null
cp "$p/before-world" /etc/apk/world
/etc/init.d/opl-netfleet-core start
/etc/init.d/opl-netfleet start
printf '{"ok":true,"package_sha256":"%s","architecture":"%s","install":true,"rollback":true,"same_binary":true,"dns_proxy":true}\n' "$sha" "$arch" >"$p/qualification.json"
