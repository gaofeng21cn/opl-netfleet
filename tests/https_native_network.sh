#!/bin/sh
# Disposable OpenWrt only: installed packages, real procd/gateway and TLS wire.
set -eu
umask 077
test -f /tmp/netfleet-compat-vm-authorized
test -z "$(pidof mihomo 2>/dev/null || true)"
upgrade=${2:-}
[ -n "$upgrade" ] || ! command -v python3 >/dev/null
work=/tmp/https-native-network
probe_port=${1:-}
mkdir -p "$work"
: >"$work/timing.log"
cp /etc/config/netfleet "$work/netfleet.before"
cp /etc/hosts "$work/hosts.before"
cp /etc/ssl/certs/ca-certificates.crt "$work/ca.before"
stage=topology
origin_pid=
manager_pid=
engine_pid=
finish() {
    rc=$?
    trap - EXIT INT TERM
    set +e
    [ -z "$manager_pid" ] || kill -CONT "$manager_pid" 2>/dev/null
    [ -z "$engine_pid" ] || kill -CONT "$engine_pid" 2>/dev/null
    if [ "$rc" -ne 0 ]; then
        echo "Native network failure: $stage" >&2
        ucode /tmp/tests/https_native_guest.uc state >&2
        logread -e opl-netfleet-core | tail -20 >&2
        for file in "$work"/*.log; do tail -20 "$file" >&2; done
    fi
    ucode /tmp/tests/https_native_guest.uc disable >/dev/null 2>&1
    /etc/init.d/opl-netfleet-core stop >/dev/null 2>&1
    [ -z "$origin_pid" ] || kill "$origin_pid"
    ubus call network.interface.nfcompat remove >/dev/null 2>&1
    ip netns del nfcompat-client
    ip netns del nfcompat-origin
    ip link del nfcompat0 2>/dev/null
    ip link del nfcompat-up 2>/dev/null
    nft delete table inet native_compat_fixture
    uci -q delete firewall.nfcompatfixture
    uci -q delete firewall.nfcompatfixture_forward
    /etc/init.d/firewall reload >/dev/null 2>&1
    cp "$work/netfleet.before" /etc/config/netfleet
    cp "$work/hosts.before" /etc/hosts
    cp "$work/ca.before" /etc/ssl/certs/ca-certificates.crt
    exit "$rc"
}
trap finish EXIT INT TERM
ip netns add nfcompat-client
ip link add nfcompat0 type veth peer name nfcompat1
ip link set nfcompat1 netns nfcompat-client
ip link set nfcompat0 up
ip -6 addr add fe80::c0/64 dev nfcompat0 nodad
ip -n nfcompat-client link set lo up
ip -n nfcompat-client link set nfcompat1 address 02:77:00:00:00:02
ip -n nfcompat-client link set nfcompat1 up
ip -n nfcompat-client addr add 10.77.0.2/24 dev nfcompat1
ip -n nfcompat-client -6 addr add 2001:db8:77::2/64 dev nfcompat1 nodad
ip -n nfcompat-client -6 addr add fe80::c1/64 dev nfcompat1 nodad
ip netns exec nfcompat-client sysctl -qw net.ipv6.conf.all.forwarding=0
ubus call network add_dynamic '{"name":"nfcompat","proto":"static","device":"nfcompat0","ipaddr":["10.77.0.1/24"],"ip6addr":["2001:db8:77::1/64"]}' >"$work/netifd.log"
ip -n nfcompat-client route add default via 10.77.0.1
ip -n nfcompat-client -6 route add default via 2001:db8:77::1
ip netns add nfcompat-origin
ip link add nfcompat-up type veth peer name nfcompat-wan
ip link set nfcompat-wan netns nfcompat-origin
ip link set nfcompat-up up
ip addr add 10.78.0.1/24 dev nfcompat-up
ip -6 addr add 2001:db8:78::1/64 dev nfcompat-up nodad
ip -n nfcompat-origin link set lo up
ip -n nfcompat-origin link set nfcompat-wan up
ip -n nfcompat-origin addr add 10.78.0.2/24 dev nfcompat-wan
ip -n nfcompat-origin -6 addr add 2001:db8:78::2/64 dev nfcompat-wan nodad
ip -n nfcompat-origin addr add 198.51.100.10/32 dev lo
ip -n nfcompat-origin -6 addr add 2001:db8:88::10/128 dev lo nodad
ip -n nfcompat-origin route add default via 10.78.0.1
ip -n nfcompat-origin -6 route add default via 2001:db8:78::1
ip route add 198.51.100.10/32 via 10.78.0.2
ip -6 route add 2001:db8:88::10/128 via 2001:db8:78::2
uci set firewall.nfcompatfixture=zone
uci set firewall.nfcompatfixture.name=nfcompatfixture
uci add_list firewall.nfcompatfixture.device=nfcompat0
uci add_list firewall.nfcompatfixture.device=nfcompat-up
uci set firewall.nfcompatfixture.input=ACCEPT
uci set firewall.nfcompatfixture.output=ACCEPT
uci set firewall.nfcompatfixture.forward=ACCEPT
uci set firewall.nfcompatfixture_forward=forwarding
uci set firewall.nfcompatfixture_forward.src=nfcompatfixture
uci set firewall.nfcompatfixture_forward.dest=lan
/etc/init.d/firewall reload >"$work/firewall.log" 2>&1
# Reject a direct forwarded route. Successful requests must pass through Mihomo.
nft -f - <<'EOF'
table inet native_compat_fixture {
 chain postrouting {
  type nat hook postrouting priority 101; policy accept;
  ip saddr 10.78.0.2 ip daddr 192.168.1.2 oifname "br-lan" masquerade
 }
 chain forward {
  type filter hook forward priority -1; policy accept;
  iifname "nfcompat0" ip daddr 198.51.100.10 counter reject
  iifname "nfcompat0" ip6 daddr 2001:db8:88::10 counter reject
 }
}
EOF
stage=origin
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=wire.example \
 -addext 'subjectAltName=DNS:wire.example,DNS:other.example' -keyout "$work/origin.key" -out "$work/origin.crt" >"$work/cert.log" 2>&1
cat "$work/origin.key" "$work/origin.crt" >"$work/origin.pem"
cat "$work/origin.crt" >>/etc/ssl/certs/ca-certificates.crt
chmod 0644 /etc/ssl/certs/ca-certificates.crt
printf '\n198.51.100.10 wire.example\n2001:db8:88::10 wire.example\n' >>/etc/hosts
cat >"$work/origin.cfg" <<EOF
global
 maxconn 128
defaults
 mode http
 timeout connect 3s
 timeout client 30s
 timeout server 30s
frontend origin
 bind 0.0.0.0:443 ssl crt $work/origin.pem alpn h2,http/1.1
 bind [::]:443 v6only ssl crt $work/origin.pem alpn h2,http/1.1
 http-request return status 200 content-type text/plain lf-string "wire-ok" hdr X-Upstream-Protocol %[ssl_fc_alpn] unless { path_beg /compat-wire/ }
EOF
if [ -n "$probe_port" ]; then
    cat >>"$work/origin.cfg" <<EOF
 http-response set-header X-Upstream-Protocol %[ssl_fc_alpn]
 default_backend host_fixture
backend host_fixture
 server host 192.168.1.2:$probe_port ssl verify required ca-file /tmp/local-probe.crt
EOF
fi
ip netns exec nfcompat-origin /usr/libexec/opl-netfleet-compat/haproxy -db -f "$work/origin.cfg" >"$work/origin.log" 2>&1 &
origin_pid=$!
stage=core
mkdir -p /etc/opl-netfleet/native/profiles /etc/opl-netfleet/native/run /var/run/opl-netfleet-core
chmod 0700 /etc/opl-netfleet/native /etc/opl-netfleet/native/profiles /etc/opl-netfleet/native/run /var/run/opl-netfleet-core
printf '{"rules":["SRC-PORT,41641,DIRECT","MATCH,DIRECT"],"hosts":{"wire.example":"198.51.100.10"}}\n' >/etc/opl-netfleet/native/profiles/compat-wire.json
chmod 0600 /etc/opl-netfleet/native/profiles/compat-wire.json
uci set netfleet.config.enabled=1
uci set netfleet.config.profile=file:compat-wire.json
uci set netfleet.mixin.api_secret=native-isolated-fixture
uci delete netfleet.proxy.lan_inbound_interface
uci add_list netfleet.proxy.lan_inbound_interface=nfcompat
uci commit netfleet
/etc/init.d/opl-netfleet-core start >"$work/core.log" 2>&1
for attempt in $(seq 1 20); do
    ucode /usr/libexec/opl-netfleet/main.uc native-gateway-status >"$work/gateway.json"
    [ "$(jsonfilter -i "$work/gateway.json" -e '@.result.ready')" != true ] || break
    sleep 1
done
test "$(jsonfilter -i "$work/gateway.json" -e '@.result.ready')" = true
base_pid=$(pidof mihomo)
sha256sum /etc/config/netfleet /etc/opl-netfleet/native/run/config.yaml >"$work/base.sha256"
probe() {
    family=$1
    expected=$2
    domain=${3:-wire.example}
    source=${4:-}
    destination=198.51.100.10
    [ "$family" != 6 ] || destination='[2001:db8:88::10]'
    ip netns exec nfcompat-client curl -fsS --noproxy '*' --http1.1 --connect-timeout 3 --max-time 8 \
        ${source:+--interface "$source"} --cacert "$work/client-ca.pem" --resolve "$domain:443:$destination" \
        -D "$work/headers" -o "$work/body" -w "$family $expected %{time_starttransfer} %{time_total}\n" "https://$domain/wire" >>"$work/timing.log"
    grep -iq "^x-upstream-protocol: $expected" "$work/headers" || return 1
    test "$(cat "$work/body")" = wire-ok
}
wait_intercepting() {
    for attempt in $(seq 1 95); do
        # Long package/idle tests can outlive IPv4 neighbour evidence. Generate
        # real ARP-confirmed traffic instead of injecting identity cache entries.
        if [ "$((attempt % 5))" = 1 ]; then
            ping -c 1 -W 1 -I nfcompat0 10.77.0.2 >/dev/null 2>&1 || true
        fi
        ucode /tmp/tests/https_native_guest.uc state >"$work/state.json"
        if [ "$(jsonfilter -i "$work/state.json" -e '@.intercepting')" = true ] &&
            jsonfilter -i "$work/state.json" -e '@.device_addresses.mac[*]' | grep -qx '10.77.0.2'; then
            # Published address evidence can precede the next lease transaction.
            if probe 4 h2 && probe 6 h2; then return 0; fi
        fi
        sleep 1
    done
    return 1
}
processes() {
    ubus call service list '{"name":"opl-netfleet-compat"}' >"$work/procd.json"
    engine_pid=$(jsonfilter -i "$work/procd.json" -e '@["opl-netfleet-compat"].instances.engine.pid')
    manager_pid=$(jsonfilter -i "$work/procd.json" -e '@["opl-netfleet-compat"].instances.manager.pid')
    test -n "$engine_pid"
    test -n "$manager_pid"
}
resources() {
    ucode /tmp/tests/https_native_metrics.uc capture >"$work/$1.json"
}
cp "$work/origin.crt" "$work/client-ca.pem"
stage=baseline_wire
probe 4 http/1.1
probe 6 http/1.1
if [ -n "$upgrade" ]; then . /tmp/tests/https_native_upgrade.sh; fi
stage=compat_enable
ucode /tmp/tests/https_native_guest.uc network-enable >"$work/enable.log"
cat /etc/opl-netfleet/compatibility/ca/mitmproxy-ca-cert.pem >>"$work/client-ca.pem"
wait_intercepting
stage=converted_wire
processes
sh /tmp/tests/https_native_probe_pair.sh "$manager_pid" "$base_pid" >"$work/probe-pair.log" 2>&1
probe 4 h2
probe 6 h2
probe 4 http/1.1 other.example
probe 6 http/1.1 other.example
ip -n nfcompat-client addr add 10.77.0.4/24 dev nfcompat1
probe 4 http/1.1 wire.example 10.77.0.4
test "$(pidof mihomo)" = "$base_pid"
sha256sum -c "$work/base.sha256"
stage=address_following
ucode /tmp/tests/https_native_guest.uc network-identity >"$work/identity.log"
wait_intercepting
probe 4 h2
probe 6 h2
revision=$(jsonfilter -i "$work/state.json" -e '@.revision')
processes
identity_engine_pid=$engine_pid
ip -n nfcompat-client -6 addr add 2001:db8:77::22/64 dev nfcompat1 nodad
# First connection can use the original path until locally confirmed.
probe 6 http/1.1 wire.example 2001:db8:77::22
for attempt in $(seq 1 60); do
    ucode /tmp/tests/https_native_guest.uc state >"$work/state.json"
    if jsonfilter -i "$work/state.json" -e '@.device_addresses.mac[*]' | grep -qx '2001:db8:77::22'; then break; fi
    sleep 1
done
jsonfilter -i "$work/state.json" -e '@.device_addresses.mac[*]' | grep -qx '2001:db8:77::22'
wait_intercepting
test "$(jsonfilter -i "$work/state.json" -e '@.revision')" = "$revision"
for attempt in $(seq 1 95); do
    if probe 6 h2 wire.example 2001:db8:77::22; then break; fi
    sleep 1
done
probe 6 h2 wire.example 2001:db8:77::22
processes
test "$engine_pid" = "$identity_engine_pid"
stage=identity_evidence_loss
ucode /tmp/tests/https_native_guest.uc network-source-disable >"$work/identity-disabled.log"
sleep 11
probe 4 http/1.1
probe 6 http/1.1
processes
test "$engine_pid" = "$identity_engine_pid"
ucode /tmp/tests/https_native_guest.uc network-source-enable >"$work/identity-enabled.log"
wait_intercepting
probe 4 h2
probe 6 h2
processes
test "$engine_pid" = "$identity_engine_pid"
stage=resources
if [ -n "$probe_port" ]; then
    stage=streaming_wire
    wire() {
        ip netns exec nfcompat-client curl --noproxy '*' --http1.1 --connect-timeout 3 --max-time 15 \
            --cacert "$work/client-ca.pem" --resolve 'wire.example:443:198.51.100.10' "$@"
    }
    for size in 70 2048; do
        dd if=/dev/urandom of="$work/upload.bin" bs=1024 count="$size" 2>/dev/null
        expected_hash=$(sha256sum "$work/upload.bin" | awk '{print $1}')
        wire -fsS -H 'Content-Type: image/png' --data-binary "@$work/upload.bin" \
            -D "$work/upload.headers" 'https://wire.example/compat-wire/echo?fixture=1' >"$work/upload.json"
        test "$(jsonfilter -i "$work/upload.json" -e '@.sha256')" = "$expected_hash"
        test "$(jsonfilter -i "$work/upload.json" -e '@.bytes')" = "$((size * 1024))"
        test "$(jsonfilter -i "$work/upload.json" -e '@.content_type')" = image/png
        test "$(jsonfilter -i "$work/upload.json" -e '@.path')" = '/compat-wire/echo?fixture=1'
        grep -iq '^x-upstream-protocol: h2' "$work/upload.headers"
    done
    wire -fsSN 'https://wire.example/compat-wire/events' >"$work/events.txt" &
    stream_pid=$!
    sleep 1
    kill -0 "$stream_pid"
    grep -q '^data: 0$' "$work/events.txt"
    wait "$stream_pid"
    test "$(grep -c '^data:' "$work/events.txt")" = 30
    cancelled=0
    wire -sSN --max-time 0.5 'https://wire.example/compat-wire/events' >"$work/cancelled.txt" 2>"$work/cancelled.log" || cancelled=$?
    test "$cancelled" = 28
    for code in 401 429; do
        test "$(wire -sS -o /dev/null -D "$work/error.headers" -w '%{http_code}' "https://wire.example/compat-wire/$code")" = "$code"
        grep -iq '^retry-after: 7' "$work/error.headers"
    done
    probe 4 h2
fi
stage=resources
if [ -f /tmp/compat-runtime/upgrade.json ]; then
    stage=plugin_update
    . /tmp/tests/https_native_package_cycle.sh
fi
if [ -f /tmp/netfleet-compat-benchmark ]; then
    stage=benchmark
    . /tmp/tests/https_benchmark.sh
fi
resources idle-before
sleep 20
resources idle-after
for attempt in $(seq 1 20); do probe 4 h2; done
resources load-after
ucode /tmp/tests/https_native_metrics.uc report "$work" >"$work/performance.json"
stage=profile
NETFLEET_COMPAT_PROFILE=1 /etc/init.d/opl-netfleet-compat start
wait_intercepting
sleep 60
cp /var/run/opl-netfleet-compat/profile.json "$work/profile.json"
/etc/init.d/opl-netfleet-compat start
wait_intercepting
stage=gateway_epoch_change
cp /etc/opl-netfleet/native/run/config.yaml "$work/profile-epoch-before.json"
flock -w 10 /var/lock/opl-netfleet-deploy.lock ucode - <<'UC'
import * as fs from 'fs';
const p='/etc/opl-netfleet/native/run/config.yaml',v=json(fs.readfile(p));
push(v.rules,'SRC-IP-CIDR,10.77.0.0/24,DIRECT');fs.writefile(p+'.new',sprintf('%J',v));fs.rename(p+'.new',p);
UC
sleep 7
probe 4 http/1.1
probe 6 http/1.1
cp "$work/profile-epoch-before.json" /etc/opl-netfleet/native/run/config.yaml
wait_intercepting
probe 4 h2
stage=manager_stall
processes
kill -STOP "$manager_pid"
sleep 11
probe 4 http/1.1
probe 6 http/1.1
test "$(pidof mihomo)" = "$base_pid"
kill -CONT "$manager_pid"
sleep 2
probe 4 http/1.1
wait_intercepting
probe 4 h2
stage=simultaneous_stall
processes
kill -STOP "$manager_pid" "$engine_pid"
sleep 11
probe 4 http/1.1
probe 6 http/1.1
kill -CONT "$engine_pid" "$manager_pid"
wait_intercepting
probe 6 h2
stage=engine_crash
processes
kill -KILL "$engine_pid"
engine_pid=
sleep 11
probe 4 http/1.1
test "$(pidof mihomo)" = "$base_pid"
ucode /tmp/tests/https_native_guest.uc state >"$work/crash-state.json"
test "$(jsonfilter -i "$work/crash-state.json" -e '@.recovery.latched')" = true
ucode /tmp/tests/https_native_guest.uc recover >"$work/recover.log"
wait_intercepting
probe 4 h2
stage=latched_rule
# Fault fixture publishes only rule state under the ordinary mutation lock.
flock -w 10 /var/lock/opl-netfleet-deploy.lock ucode - <<'UC'
import * as fs from 'fs';
const path='/var/run/opl-netfleet-compat/state.json',state=json(fs.readfile(path));
state.rule_recovery.wire.latched=true;fs.writefile(path+'.new',sprintf('%J',state));fs.rename(path+'.new',path);
UC
sleep 12
rule_probe_before=$(jsonfilter -i /var/run/opl-netfleet-compat/state.json -e '@.rule_recovery.wire.probe.at')
sleep 12
test "$(jsonfilter -i /var/run/opl-netfleet-compat/state.json -e '@.rule_recovery.wire.probe.at')" = "$rule_probe_before"
probe 4 http/1.1
ucode - <<'UC'
import * as fs from 'fs';
const main='/usr/libexec/opl-netfleet/main.uc',p=fs.popen('ucode '+main+' compatibility-get'),v=json(p.read('all'));
if(p.close()||!v.ok)die('state_read_failed');
fs.writefile('/tmp/rule-recover.json',sprintf('%J',{request:{revision:v.result.revision,operation:'recover',rule:'wire'}}));
if(system('ucode '+main+' compatibility-probe /tmp/rule-recover.json >/dev/null'))die('rule_recover_failed');
fs.unlink('/tmp/rule-recover.json');
UC
wait_intercepting
probe 4 h2
stage=resource_pressure
. /tmp/tests/https_native_resource_pressure.sh
stage=disabled_wire
ucode /tmp/tests/https_native_guest.uc disable >"$work/disable.log"
probe 4 http/1.1
probe 6 http/1.1
test "$(pidof mihomo)" = "$base_pid"
sha256sum -c "$work/base.sha256"
echo 'native installed network: dual-stack H1 -> h2, original routing, address following, manager/engine stalls, third-fault latch, recovery and disabled bypass passed'
