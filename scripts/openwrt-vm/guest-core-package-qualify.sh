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
printf '%s\n' "$arch" >/etc/apk/arch
printf '%s\n' "$p/rollback/packages.adb" >/etc/apk/repositories.d/netfleet-core-fixture.list
apk --no-network --repositories-file /dev/null -X "$p/rollback/packages.adb" add mihomo-meta=1.19.29 >/dev/null
# Reproduce the existing field condition: old package record, newer binary.
cp "$p/before-core" /usr/libexec/mihomo
/etc/init.d/opl-netfleet-core start
/etc/init.d/opl-netfleet start
sleep 3
mkdir -p "$root/archives"
rm -f "$root/archives/$name"
cp "$p/$name" "$root/archives/$name"
chmod 600 "$root/archives/$name"
ubus -t 20 call opl-netfleet components_update "{\"component\":\"mihomo\",\"version\":\"$version\"}" >"$p/start.json"
[ "$(jsonfilter -i "$p/start.json" -e '@.ok')" = true ]
id=$(jsonfilter -i "$p/start.json" -e '@.result.operation.id')
[ -n "$id" ]
for attempt in $(seq 1 120); do
  ubus -t 10 call opl-netfleet operation_get '{}' >"$p/operation.json"
  state=$(jsonfilter -i "$p/operation.json" -e '@.result.packages.state')
  case "$state" in succeeded) break ;; failed|interrupted) cat "$root/$id/log" >&2; exit 1 ;; esac
  sleep 1
done
[ "$state" = succeeded ]
[ "$(apk query --installed --format json --fields version mihomo-meta | jsonfilter -e '@[0].version')" = "$version" ]
cmp "$p/before-core" /usr/libexec/mihomo
ucode "$main" status >"$p/status.json"
[ "$(jsonfilter -i "$p/status.json" -e '@.result.active')" = true ]
[ "$(jsonfilter -i "$p/status.json" -e '@.result.runtime.lan_runtime.dns_ready')" = true ]
[ "$(jsonfilter -i "$p/status.json" -e '@.result.runtime.lan_runtime.transparent_proxy_ready')" = true ]
ucode "$main" probe >"$p/probe.json"
[ "$(jsonfilter -i "$p/probe.json" -e '@.result.ok')" = true ]
sha256sum -c "$p/before-inputs"
# Exercise the retained rollback through the same components owner.
ucode -e 'import {create} from "/usr/libexec/opl-netfleet/kernel/host.uc"; import {create as adapter} from "/usr/libexec/opl-netfleet/adapters/openwrt.uc"; import * as fs from "fs"; const path=ARGV[0]; const j=json(fs.readfile(path)); j.phase="recovering"; j.write_started=true; fs.writefile(path,sprintf("%J",j));' "$root/$id/journal.json"
printf '{"id":"%s"}\n' "$id" >"$root/pending.json"
ubus -t 120 call opl-netfleet components_recover "{\"id\":\"$id\"}" >"$p/recover.json"
[ "$(jsonfilter -i "$p/recover.json" -e '@.ok')" = true ]
for attempt in $(seq 1 120); do
  [ "$(jsonfilter -i "$root/$id/journal.json" -e '@.phase')" != rolled_back ] || break
  sleep 1
done
[ "$(jsonfilter -i "$root/$id/journal.json" -e '@.phase')" = rolled_back ]
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
apk --no-network add mihomo-meta=1.19.30-r1 >/dev/null
cp "$p/before-world" /etc/apk/world
/etc/init.d/opl-netfleet-core start
/etc/init.d/opl-netfleet start
printf '{"ok":true,"package_sha256":"%s","architecture":"%s","install":true,"rollback":true,"same_binary":true,"dns_proxy":true}\n' "$sha" "$arch" >"$p/qualification.json"
