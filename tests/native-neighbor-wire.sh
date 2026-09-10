#!/bin/sh
set -eu
[ "${NETFLEET_ISOLATED_NATIVE_TEST:-}" = 1 ] || exit 2
ip link add nf-observe type veth peer name nf-client
trap 'ip link del nf-observe 2>/dev/null || true' EXIT
ip link set nf-observe address 02:00:00:00:00:fe
ip link set nf-client address 02:00:00:00:00:01
ip link set nf-observe up
ip link set nf-client up
ip -6 address add fe80::fe/64 dev nf-observe nodad
ip -6 address add 2001:db8:7::1/64 dev nf-client nodad
/out/neighbor-native nf-observe fe80::fe 02:00:00:00:00:fe -- 2001:db8:7::1 > /tmp/neighbor-result.json
ucode -e 'import * as fs from "fs"; const rows=json(fs.readfile("/tmp/neighbor-result.json")); if (length(rows)!=1 || rows[0][0]!="2001:db8:7::1" || rows[0][1]!="02:00:00:00:00:01") die(sprintf("NA verification failed: %J",rows));'
ip -6 address del 2001:db8:7::1/64 dev nf-client
ip -6 address add 2001:db8:7::2/64 dev nf-client nodad
/out/neighbor-native nf-observe fe80::fe 02:00:00:00:00:fe -- 2001:db8:7::1 2001:db8:7::2 > /tmp/neighbor-result.json
ucode -e 'import * as fs from "fs"; const rows=json(fs.readfile("/tmp/neighbor-result.json")); if (length(rows)!=1 || rows[0][0]!="2001:db8:7::2") die(sprintf("address rotation failed: %J",rows));'
printf '%s\n' 'Native Neighbor Solicitation / Advertisement and address rotation passed'
