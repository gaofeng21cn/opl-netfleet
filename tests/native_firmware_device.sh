#!/bin/sh
# Run only in a disposable OpenWrt guest. This does not flash firmware.
set -eu
[ "${NETFLEET_DISPOSABLE_GUEST:-}" = 1 ] || exit 2
control=/usr/libexec/netfleet-firmware/control.uc
helper=/usr/libexec/opl-netfleet-firmware
version=$(ubus call system board | jsonfilter -e '@.release.version')
ucode -c -o /tmp/firmware-control.uc "$control"
"$helper" describe >/tmp/firmware-description.json
for url in http://example.org/store/a https://example.org/store/a 'https://sysupgrade.openwrt.org/store/../a'; do
 if ucode "$control" admit "$url" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$version" >/dev/null 2>&1; then exit 1; fi
done
ucode "$control" admit https://sysupgrade.openwrt.org/store/test/image.bin aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$version"
for other in 24.10.9 26.1.0 SNAPSHOT; do
 if ucode "$control" admit https://sysupgrade.openwrt.org/store/test/image.bin aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$other" >/dev/null 2>&1; then exit 1; fi
done
mkdir -p /etc/opl-netfleet/native/subscriptions
printf '%s\n' private-test-subscription >/etc/opl-netfleet/native/subscriptions/test.yaml
printf '%s\n' 'config netfleet test' >/etc/config/netfleet
printf '%s\n' '#!/bin/sh /etc/rc.common' 'START=99' >/etc/init.d/nikki
chmod +x /etc/init.d/nikki
/etc/init.d/nikki disable
ucode "$control" prepare "$version"
/etc/init.d/nikki enable
printf '%s\n' changed >/etc/opl-netfleet/native/subscriptions/test.yaml
if "$helper" restore >/dev/null 2>&1; then exit 1; fi
[ -f /etc/opl-netfleet/firmware/pending.json ]
[ ! -f /etc/opl-netfleet/firmware/last.json ]
printf '%s\n' private-test-subscription >/etc/opl-netfleet/native/subscriptions/test.yaml
"$helper" restore
! /etc/init.d/nikki enabled
[ ! -f /etc/opl-netfleet/firmware/pending.json ]
[ "$(jsonfilter -i /etc/opl-netfleet/firmware/last.json -e '@.ok')" = true ]
sysupgrade -b /tmp/firmware-preservation.tgz >/dev/null
tar -tzf /tmp/firmware-preservation.tgz | grep -qx etc/opl-netfleet/native/subscriptions/test.yaml
[ "$(tar -xOzf /tmp/firmware-preservation.tgz etc/opl-netfleet/native/subscriptions/test.yaml)" = private-test-subscription ]
printf '%s\n' '{"ok":true,"checks":["ucode_compile","public_repository_projection","download_admission","private_input_tamper_refused","restore_inputs","disabled_service_preserved","native_sysupgrade_archive_roundtrip"]}'
