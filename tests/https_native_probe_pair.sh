#!/bin/sh
# Actual kernel/TLS path in the disposable guest; do not suspend production.
set -eu
test -f /tmp/netfleet-compat-vm-authorized
manager=${1:?}; base=${2:?}
helper=/usr/libexec/opl-netfleet-compat/tls-probe
uid=$(id -u netfleet-compat)
run=/var/run/opl-netfleet-compat
out=/tmp/native-probe-pair.json
cleanup() {
 rc=$?; trap - EXIT INT TERM
 nft delete table inet compat_probe_fixture >/dev/null 2>&1 || true
 kill -CONT "$manager" 2>/dev/null || true
 exit "$rc"
}
trap cleanup EXIT INT TERM
kill -STOP "$manager"
"$helper" local-pair "$run" "$uid" >"$out"
test "$(jsonfilter -i "$out" -e '@.ipv4.ok')" = true
test "$(jsonfilter -i "$out" -e '@.ipv6.ok')" = true
nft -f - <<'NFT'
table inet compat_probe_fixture {
 chain reject_probe { type filter hook output priority -110; policy accept; }
}
NFT
for family in 4 6; do
 if [ "$family" = 4 ]; then
  nft add rule inet compat_probe_fixture reject_probe ip daddr 127.0.0.1 tcp dport 18445 reject
 else
  nft add rule inet compat_probe_fixture reject_probe ip6 daddr ::1 tcp dport 18445 reject
 fi
 if "$helper" local-pair "$run" "$uid" >"$out"; then exit 1; fi
 test "$(jsonfilter -i "$out" -e "@.ipv$family.ok")" = false
 nft flush chain inet compat_probe_fixture reject_probe
done
"$helper" local-pair "$run" "$uid" >"$out"
test "$(jsonfilter -i "$out" -e '@.ipv4.ok')" = true
test "$(jsonfilter -i "$out" -e '@.ipv6.ok')" = true
test "$(pidof mihomo)" = "$base"
echo 'dual-stack probe: real TLS, independent stack failure, recovery and stable base passed'
