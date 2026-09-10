#!/bin/sh
set -eu
[ "${NETFLEET_ISOLATED_NATIVE_TEST:-}" = 1 ] || exit 2
helper=${1:-/out/neighbor-native}
ip netns add nf-neighbor-client
trap 'ip link del nf-observe 2>/dev/null || true; ip netns del nf-neighbor-client' EXIT
ip link add nf-observe type veth peer name nf-client
ip link set nf-observe address 02:00:00:00:00:fe
ip link set nf-client netns nf-neighbor-client
ip -n nf-neighbor-client link set nf-client address 02:00:00:00:00:01
ip link set nf-observe up
ip -n nf-neighbor-client link set nf-client up
# Keep the client's forwarding and firewall independent of the router.
ip netns exec nf-neighbor-client sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null
ip -6 address add fe80::fe/64 dev nf-observe nodad
ip -n nf-neighbor-client -6 address add 2001:db8:7::1/64 dev nf-client nodad
"$helper" nf-observe fe80::fe 02:00:00:00:00:fe -- 2001:db8:7::1 > /tmp/neighbor-result.json
ucode -e 'import * as fs from "fs"; const rows=json(fs.readfile("/tmp/neighbor-result.json")); if (length(rows)!=1 || rows[0][0]!="2001:db8:7::1" || rows[0][1]!="02:00:00:00:00:01") die(sprintf("NA verification failed: %J",rows));'
ip -n nf-neighbor-client -6 address del 2001:db8:7::1/64 dev nf-client
ip -n nf-neighbor-client -6 address add 2001:db8:7::2/64 dev nf-client nodad
"$helper" nf-observe fe80::fe 02:00:00:00:00:fe -- 2001:db8:7::1 2001:db8:7::2 > /tmp/neighbor-result.json
ucode -e 'import * as fs from "fs"; const rows=json(fs.readfile("/tmp/neighbor-result.json")); if (length(rows)!=1 || rows[0][0]!="2001:db8:7::2") die(sprintf("address rotation failed: %J",rows));'
printf '%s\n' 'Native Neighbor Solicitation / Advertisement and address rotation passed'
