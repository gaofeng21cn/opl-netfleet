#!/bin/sh
set -eu
[ "${NETFLEET_ISOLATED_NATIVE_TEST:-}" = 1 ] || exit 2
mkdir -p /etc/opl-netfleet/native/run /var/run/opl-netfleet-core /var/lock /usr/libexec/opl-netfleet-compat
printf '%s' '{"rules":["MATCH,DIRECT"]}' > /etc/opl-netfleet/native/run/config.yaml
nft add table inet base_fixture
cc -Os -Wall -Wextra -Werror /src/tests/native-listener.c -o /tmp/native-listener
/tmp/native-listener &
listener=$!
trap 'kill "$listener" 2>/dev/null || true; nft delete table inet netfleet_compat 2>/dev/null || true; nft delete table inet base_fixture' EXIT
# Wait only for the fixture listener to be visible in procfs.
for attempt in 1 2 3 4 5; do
 [ -r /proc/$listener/status ] && sleep .05
done
ucode /src/tests/interception_native_kernel.uc "$listener"
nft list table inet base_fixture >/dev/null
