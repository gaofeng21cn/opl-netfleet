#!/bin/sh
set -eu
umask 077

version=25.12.5
image_name="openwrt-${version}-armsr-armv8-generic-ext4-combined-efi.img.gz"
image_sha=d7dcf013547e8be28006d83ce2c2232cd065755b803f4a5ee6b2e22391cfbc76
image_url="https://downloads.openwrt.org/releases/${version}/targets/armsr/armv8/${image_name}"
core_lock=${NETFLEET_WORKSPACE:?}/openwrt/mihomo-meta/source.json
mihomo_name=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["filename"])' "$core_lock")
mihomo_sha=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$core_lock")
mihomo_url=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["api_url"])' "$core_lock")
yq_name=yq_linux_arm64-v4.53.6
yq_sha=88a1016bc1d657375a35864e4f44b6f333df8ff97b559f51bba0adcb2169df09
yq_url=https://api.github.com/repos/mikefarah/yq/releases/assets/522028007
source_commit=${NETFLEET_SOURCE_COMMIT:?}
source_tree=${NETFLEET_SOURCE_TREE:?}
receipt=${NETFLEET_RECEIPT:?}
workspace=${NETFLEET_WORKSPACE:?}
cache=${NETFLEET_VM_CACHE:?}
firmware=${NETFLEET_QEMU_FIRMWARE:?}
qemu_version=${NETFLEET_QEMU_VERSION:?}
package_archive=${NETFLEET_PACKAGE_ARCHIVE:-}
package_manifest_sha=${NETFLEET_PACKAGE_MANIFEST_SHA256:-}
lane_mode=${NETFLEET_VM_LANE:-all}
case "$lane_mode" in all|native|setup|migration|runtime|package|compatibility) ;; *) echo 'Unknown VM lane' >&2; exit 1 ;; esac
[ "$lane_mode" != package ] || [ -n "$package_archive" ] || { echo 'Package lane requires candidate' >&2; exit 1; }
if { [ -z "$package_archive" ] && [ -n "$package_manifest_sha" ]; } ||
	{ [ -n "$package_archive" ] && [ -z "$package_manifest_sha" ]; }; then
	echo "Package archive and manifest identity must be provided together" >&2
	exit 1
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/netfleet-openwrt-vm.XXXXXX")
ssh_key="$work/id_ed25519"
serial_socket="$work/serial.sock"
qemu_log="$work/qemu.log"
ports=$(python3 - <<'PY'
import socket

sockets = []
for _ in range(3):
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sockets.append(sock)
print(*(sock.getsockname()[1] for sock in sockets))
PY
)
ssh_port=${ports%% *}
remaining_ports=${ports#* }
probe_port=${remaining_ports%% *}
feed_port=${remaining_ports##* }
stage=assets
probe_pid=
feed_pid=
qemu_pid=
now_ms() {
	python3 -c 'import time; print(time.time_ns() // 1000000)'
}
sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

total_started_ms=$(now_ms)
assets_started_ms=$total_started_ms

cleanup() {
	if [ -n "$qemu_pid" ]; then
		kill "$qemu_pid" >/dev/null 2>&1 || true
		wait "$qemu_pid" >/dev/null 2>&1 || true
	fi
	if [ -n "$probe_pid" ]; then
		kill "$probe_pid" >/dev/null 2>&1 || true
		wait "$probe_pid" >/dev/null 2>&1 || true
	fi
	if [ -n "$feed_pid" ]; then
		kill "$feed_pid" >/dev/null 2>&1 || true
		wait "$feed_pid" >/dev/null 2>&1 || true
	fi
	rm -rf -- "$work"
}
finish() {
	rc=$?
	trap - EXIT INT TERM
	if [ "$rc" -ne 0 ]; then
		echo "OpenWrt qualification failed at stage: $stage" >&2
		for dump in "$work"/*-result.json "$work"/*-result.stderr "$qemu_log"; do
			[ ! -s "$dump" ] || { echo "--- $dump" >&2; cat "$dump" >&2; }
		done
		if [ "${NETFLEET_VM_DEBUG_KEEP:-0}" = 1 ]; then
			printf 'Debug VM retained: work=%s ssh_port=%s qemu_pid=%s probe_pid=%s feed_pid=%s\n' \
				"$work" "$ssh_port" "$qemu_pid" "$probe_pid" "$feed_pid" >&2
			printf '%s\n' 'No qualification receipt: stop these exact processes and remove this directory after debugging.' >&2
			exit "$rc"
		fi
	fi
	cleanup
	exit "$rc"
}
trap finish EXIT INT TERM

mkdir -p "$work" "$cache"
cached="$cache/$image_name"
if [ ! -f "$cached" ] || [ "$(sha256_file "$cached")" != "$image_sha" ]; then
	temporary="$cached.tmp.$$"
	rm -f -- "$temporary"
	curl -fsSL --retry 3 --connect-timeout 15 "$image_url" -o "$temporary"
	[ "$(sha256_file "$temporary")" = "$image_sha" ] || {
		rm -f -- "$temporary"
		echo "OpenWrt image checksum mismatch" >&2
		exit 1
	}
	mv "$temporary" "$cached"
fi

fetch_asset() {
	asset_name=$1
	asset_sha=$2
	asset_url=$3
	asset_cached="$cache/$asset_name"
	if [ ! -f "$asset_cached" ] || [ "$(sha256_file "$asset_cached")" != "$asset_sha" ]; then
		asset_temporary="$asset_cached.tmp.$$"
		rm -f -- "$asset_temporary"
		curl -fsSL --retry 3 --connect-timeout 15 -H 'Accept: application/octet-stream' \
			"$asset_url" -o "$asset_temporary"
		[ "$(sha256_file "$asset_temporary")" = "$asset_sha" ] || {
			rm -f -- "$asset_temporary"
			echo "Pinned runtime asset checksum mismatch: $asset_name" >&2
			exit 1
		}
		mv "$asset_temporary" "$asset_cached"
	fi
	cp "$asset_cached" "$work/$asset_name"
}

fetch_asset "$mihomo_name" "$mihomo_sha" "$mihomo_url"
fetch_asset "$yq_name" "$yq_sha" "$yq_url"
tar -cf "$work/runtime-source.tar" -C "$workspace" \
	openwrt/Makefile \
	openwrt/https-compat \
	openwrt/files/usr/libexec/opl-netfleet \
	openwrt/files/etc/init.d/opl-netfleet \
	openwrt/files/etc/init.d/opl-netfleet-core \
	openwrt/files/etc/config/netfleet \
	openwrt/files/usr/share/opl-netfleet/nikki \
	openwrt/files/etc/opl-netfleet/policy-sources/base-v1.json \
	openwrt/files/etc/opl-netfleet/rulesets.lock.json tests
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
	-keyout "$work/local-probe-ca.key" -out "$work/local-probe.crt" \
	-subj '/CN=NetFleet QEMU Test CA' \
	-addext basicConstraints=critical,CA:TRUE \
	-addext keyUsage=critical,keyCertSign,cRLSign >/dev/null 2>&1
openssl req -newkey rsa:2048 -sha256 -nodes \
	-keyout "$work/local-probe-server.key" -out "$work/local-probe-server.csr" \
	-subj /CN=www.gstatic.com >/dev/null 2>&1
cat >"$work/local-probe-server.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:netfleet-probe.test,DNS:www.gstatic.com,IP:192.168.1.2
EOF
openssl x509 -req -sha256 -days 1 \
	-in "$work/local-probe-server.csr" \
	-CA "$work/local-probe.crt" -CAkey "$work/local-probe-ca.key" -CAcreateserial \
	-extfile "$work/local-probe-server.ext" \
	-out "$work/local-probe-server.crt" >/dev/null 2>&1
python3 - "$work/local-probe-server.crt" "$work/local-probe-server.key" "$probe_port" >"$work/local-probe.log" 2>&1 <<'PY' &
import http.server
import json
import ssl
import sys
from urllib.parse import urlsplit, parse_qs


class Handler(http.server.BaseHTTPRequestHandler):
    # Mihomo URLTest uses HEAD; curl business probes use GET.
    def do_HEAD(self):
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path.startswith("/native-subscriptions/"):
            if parse_qs(url.query).get("token") != ["vm-only-credential"]:
                self.send_error(403)
                return
            kind = url.path.rsplit("/", 1)[-1]
            if kind == "redirect":
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1/blocked-downgrade")
                self.end_headers()
                return
            if kind == "missing":
                self.send_error(404)
                return
            body = json.dumps({"proxies": [{"name": "native-region-node", "type": "socks5",
                "server": "127.0.0.1", "port": 1081, "udp": True}],
                "dns": {"enable": True, "nameserver": ["udp://127.0.0.1:1054"]},
                "mixed-port": 1111, "rules": ["MATCH,REJECT"]}).encode()
            if kind == "setup":
                body = json.dumps({"proxies": [{"name": "JP Japan setup-node", "type": "socks5",
                    "server": "198.18.1.2", "port": 1081, "udp": True}],
                    "proxy-groups": [{"name": "Outbound", "type": "select", "proxies": ["JP Japan setup-node"]}],
                    "rules": ["MATCH,Outbound"]}).encode()
            elif kind == "invalid":
                body = b"proxies: [not valid yaml"
            elif kind == "bad-node":
                body = b'{"proxies":[{"name":"bad","type":"not-a-proxy"}]}'
            elif kind == "empty":
                body = b'{"proxies":[]}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Subscription-Userinfo", "upload=1024; download=2048; total=104857600; expire=0")
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(204)
        self.end_headers()

    def log_message(self, _format, *_args):
        pass


class TLSServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128

    def process_request_thread(self, request, client_address):
        try:
            tls_request = self.context.wrap_socket(request, server_side=True)
        except (ssl.SSLError, OSError):
            self.shutdown_request(request)
            return
        super().process_request_thread(tls_request, client_address)


server = TLSServer(("0.0.0.0", int(sys.argv[3])), Handler)
server.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
server.context.load_cert_chain(sys.argv[1], sys.argv[2])
server.serve_forever()
PY
probe_pid=$!
probe_ready() {
	kill -0 "$probe_pid" >/dev/null 2>&1 || return 1
	for method in GET HEAD; do
		[ "$(curl -sS --request "$method" --cacert "$work/local-probe.crt" \
			--resolve "192.168.1.2:$probe_port:127.0.0.1" -o /dev/null -w '%{http_code}' \
			"https://192.168.1.2:$probe_port/generate_204" || true)" = 204 ] || return 1
	done
}
wait_for_probe() {
	for attempt in $(seq 1 20); do
		probe_ready && return 0
		[ "$attempt" -lt 20 ] || { cat "$work/local-probe.log" >&2; return 1; }
		sleep 1
	done
}
wait_for_probe

feed_url=
if [ -n "$package_archive" ]; then
	feed_dir=$work/package-feed
	mkdir -p "$feed_dir"
	tar -C "$feed_dir" -xf "$package_archive"
	[ "$(sha256_file "$feed_dir/manifest.json")" = "$package_manifest_sha" ] || {
		echo "OpenWrt qualification package manifest mismatch" >&2
		exit 1
	}
	if [ "$lane_mode" = all ] || [ "$lane_mode" = setup ]; then
		python3 "$workspace/scripts/openwrt-vm/component-fixtures.py" "$feed_dir" "$feed_dir/components-fixtures"
	fi
	python3 -m http.server "$feed_port" --bind 0.0.0.0 --directory "$feed_dir" \
		>"$work/package-feed.log" 2>&1 &
	feed_pid=$!
	for attempt in $(seq 1 20); do
		if curl -fsS --connect-timeout 2 "http://127.0.0.1:$feed_port/manifest.json" >/dev/null; then
			break
		fi
		[ "$attempt" -lt 20 ] || { cat "$work/package-feed.log" >&2; exit 1; }
		sleep 1
	done
	feed_url="http://192.168.1.2:$feed_port"
fi
assets_elapsed_ms=$(($(now_ms) - assets_started_ms))

ssh-keygen -q -t ed25519 -N '' -f "$ssh_key"
image_elapsed_ms=0
boot_elapsed_ms=0
transfer_elapsed_ms=0
boot_clean_vm() {
if [ -n "$qemu_pid" ]; then
	kill "$qemu_pid" >/dev/null 2>&1 || true
	wait "$qemu_pid" >/dev/null 2>&1 || true
	qemu_pid=
fi
rm -f "$serial_socket"
stage=qemu_boot
image_started_ms=$(now_ms)
set +e
gzip -dc "$cached" >"$work/openwrt.img"
gzip_status=$?
set -e
case "$gzip_status" in
	0|2) ;;
	*) echo "OpenWrt image decompression failed" >&2; exit 1 ;;
esac
qemu-img info --output=json "$work/openwrt.img" >/dev/null
# The official root is too small for atomic core replacement. Resize offline;
# preserve its PARTUUID, which the boot command line uses to locate root.
partition=$(sgdisk -i 2 "$work/openwrt.img")
root_start=$(printf '%s\n' "$partition" | awk '/^First sector:/ { print $3 }')
root_sectors=$(printf '%s\n' "$partition" | awk '/^Partition size:/ { print $3 }')
root_uuid=$(printf '%s\n' "$partition" | awk '/^Partition unique GUID:/ { print $4 }')
[ -n "$root_start" ] && [ -n "$root_sectors" ] && [ -n "$root_uuid" ] || exit 1
dd if="$work/openwrt.img" of="$work/root.ext4" bs=512 skip="$root_start" count="$root_sectors" 2>/dev/null
fsck_result=0
e2fsck -pf "$work/root.ext4" || fsck_result=$?
[ "$fsck_result" -le 1 ] || exit 1
resize2fs "$work/root.ext4" 256M
qemu-img resize -f raw "$work/openwrt.img" 512M >/dev/null
sgdisk -e -a 1 -d 2 -n "2:$root_start:+256M" -u "2:$root_uuid" -t 2:8300 "$work/openwrt.img" >/dev/null
dd if="$work/root.ext4" of="$work/openwrt.img" bs=512 seek="$root_start" conv=notrunc 2>/dev/null
rm "$work/root.ext4"
image_elapsed_ms=$((image_elapsed_ms + $(now_ms) - image_started_ms))

[ -f "$firmware" ] || { echo "AArch64 QEMU EFI firmware not found" >&2; exit 1; }
boot_started_ms=$(now_ms)

vm_memory=512
[ "$lane_mode" != compatibility ] || vm_memory=768
qemu-system-aarch64 \
	-accel hvf \
	-machine virt \
	-cpu host \
	-m "$vm_memory" \
	-smp 2 \
	-bios "$firmware" \
	-drive "file=$work/openwrt.img,format=raw,if=none,id=drive0" \
	-device virtio-blk-device,drive=drive0 \
	-netdev "user,id=net0,net=192.168.1.0/24,hostfwd=tcp:127.0.0.1:${ssh_port}-192.168.1.1:22" \
	-device virtio-net-device,netdev=net0 \
	-display none \
	-serial "unix:$serial_socket,server=on,wait=off" \
	-monitor none \
	-no-reboot >"$qemu_log" 2>&1 &
qemu_pid=$!

python3 - "$serial_socket" "$ssh_key.pub" <<'PY'
from pathlib import Path
import socket
import sys
import time

socket_path = sys.argv[1]
public_key = Path(sys.argv[2]).read_text().strip()
deadline = time.monotonic() + 150
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
while True:
    try:
        sock.connect(socket_path)
        break
    except (FileNotFoundError, ConnectionRefusedError):
        if time.monotonic() >= deadline:
            raise SystemExit("serial socket did not become available")
        time.sleep(1)

sock.settimeout(1)
buffer = b""
while time.monotonic() < deadline:
    sock.sendall(b"\n")
    try:
        chunk = sock.recv(65536)
        if chunk:
            buffer = (buffer + chunk)[-262144:]
    except TimeoutError:
        pass
    if b"root@OpenWrt" in buffer or b"root@openwrt" in buffer:
        break
    time.sleep(1)
else:
    raise SystemExit("OpenWrt serial console did not reach a root shell")

command = (
    "mkdir -p /etc/dropbear; "
    f"printf '%s\\n' '{public_key}' >/etc/dropbear/authorized_keys; "
    "chmod 600 /etc/dropbear/authorized_keys; /etc/init.d/dropbear restart; "
    "echo NETFLEET_VM_READY\n"
)
sock.sendall(command.encode())
marker = b""
while time.monotonic() < deadline:
    try:
        marker += sock.recv(65536)
    except TimeoutError:
        continue
    if b"NETFLEET_VM_READY" in marker.splitlines():
        break
else:
    raise SystemExit("OpenWrt SSH bootstrap did not complete")
sock.close()
PY

ssh_common="-i $ssh_key -p $ssh_port -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
for attempt in $(seq 1 30); do
	if ssh $ssh_common root@127.0.0.1 \
		'test "$(uname -m)" = aarch64 && test "$(readlink /var)" = tmp && ubus call system board >/dev/null && /etc/init.d/rpcd status >/dev/null' >/dev/null 2>&1; then
		break
	fi
	[ "$attempt" -lt 30 ] || { echo "OpenWrt SSH did not become ready" >&2; exit 1; }
	sleep 1
done

boot_elapsed_ms=$((boot_elapsed_ms + $(now_ms) - boot_started_ms))
runner_arch=$(uname -m)
guest_arch=$(ssh $ssh_common root@127.0.0.1 uname -m)
stage=transfer
transfer_started_ms=$(now_ms)
tar -cf - -C "$workspace/scripts" deploy-openwrt-remote.sh \
	-C "$workspace/scripts/openwrt-vm" guest-qualify.sh guest-runtime-qualify.sh guest-package-qualify.sh \
	guest-native-qualify.sh guest-setup-qualify.sh guest-migration-qualify.sh guest-components-qualify.sh \
	guest-compatibility-qualify.sh \
	-C "$work" runtime-source.tar local-probe.crt "$mihomo_name" "$yq_name" |
ssh $ssh_common root@127.0.0.1 'tar -C /tmp -xf -'
expected_transfer=$(printf '%s\n' \
	"$(sha256_file "$workspace/scripts/deploy-openwrt-remote.sh")" \
	"$(sha256_file "$workspace/scripts/openwrt-vm/guest-qualify.sh")" \
	"$(sha256_file "$workspace/scripts/openwrt-vm/guest-runtime-qualify.sh")" \
	"$(sha256_file "$workspace/scripts/openwrt-vm/guest-package-qualify.sh")" \
	"$(sha256_file "$workspace/scripts/openwrt-vm/guest-native-qualify.sh")" \
	"$(sha256_file "$workspace/scripts/openwrt-vm/guest-setup-qualify.sh")" \
	"$(sha256_file "$workspace/scripts/openwrt-vm/guest-migration-qualify.sh")" \
	"$(sha256_file "$workspace/scripts/openwrt-vm/guest-components-qualify.sh")" \
	"$(sha256_file "$work/runtime-source.tar")" \
	"$(sha256_file "$work/local-probe.crt")" \
	"$(sha256_file "$work/$mihomo_name")" \
	"$(sha256_file "$work/$yq_name")")
actual_transfer=$(ssh $ssh_common root@127.0.0.1 \
	"sha256sum /tmp/deploy-openwrt-remote.sh /tmp/guest-qualify.sh /tmp/guest-runtime-qualify.sh /tmp/guest-package-qualify.sh /tmp/guest-native-qualify.sh /tmp/guest-setup-qualify.sh /tmp/guest-migration-qualify.sh /tmp/guest-components-qualify.sh /tmp/runtime-source.tar /tmp/local-probe.crt /tmp/$mihomo_name /tmp/$yq_name | awk '{print \$1}'")
[ "$actual_transfer" = "$expected_transfer" ] || {
	echo "OpenWrt qualification source transfer mismatch" >&2
	exit 1
}
ssh $ssh_common root@127.0.0.1 'tar -C /tmp -xf /tmp/runtime-source.tar && rm -f /tmp/runtime-source.tar'
transfer_elapsed_ms=$((transfer_elapsed_ms + $(now_ms) - transfer_started_ms))
}
run_guest() {
	result_name=$1
	guest_kind=$2
	stage=${result_name}_guest
	guest_started_ms=$(now_ms)
	guest_script=guest-${guest_kind}-qualify.sh
	guest_arguments="'$probe_port'"
	case "$guest_kind" in
		management) guest_script=guest-qualify.sh; guest_arguments= ;;
		package) guest_arguments="'$package_manifest_sha' '$probe_port' '$feed_url'" ;;
		native|setup|migration)
			ssh $ssh_common root@127.0.0.1 "touch /tmp/netfleet-${guest_kind}-vm-authorized" ;;
	esac
	if [ "$guest_kind" = setup ] && [ -n "$package_archive" ]; then
		guest_arguments="$guest_arguments '$feed_url'"
	fi
	if ! ssh $ssh_common root@127.0.0.1 \
		"sh /tmp/$guest_script '$source_commit' '$source_tree' $guest_arguments" \
		>"$work/$result_name-result.json" 2>"$work/$result_name-result.stderr"; then
		cat "$work/$result_name-result.stderr" >&2
		exit 1
	fi
	printf '%s\n' "$(($(now_ms) - guest_started_ms))" >"$work/$result_name-ms"
	ssh $ssh_common root@127.0.0.1 \
		'test "$(readlink /var)" = tmp && ubus call system board >/dev/null && test -S /var/run/ubus/ubus.sock'
	wait_for_probe
}

if [ "$lane_mode" = all ] || [ "$lane_mode" = native ]; then
	boot_clean_vm
	run_guest native native
fi
if [ "$lane_mode" = compatibility ]; then
	boot_clean_vm
	stage=compatibility_transfer
	COPYFILE_DISABLE=1 tar -cf "$work/compat-runtime.tar" -C "${NETFLEET_COMPAT_RUNTIME:?}" vendor
	compat_runtime_sha=$(sha256_file "$work/compat-runtime.tar")
	ssh $ssh_common root@127.0.0.1 'cat >/tmp/compat-runtime.tar' <"$work/compat-runtime.tar"
	actual_sha=$(ssh $ssh_common root@127.0.0.1 'sha256sum /tmp/compat-runtime.tar' | awk '{print $1}')
	[ "$actual_sha" = "$compat_runtime_sha" ] || exit 1
	ssh $ssh_common root@127.0.0.1 'mkdir -p /tmp/compat-runtime && tar -xf /tmp/compat-runtime.tar -C /tmp/compat-runtime && rm /tmp/compat-runtime.tar'
	run_guest compatibility compatibility
fi
if [ "$lane_mode" = all ] || [ "$lane_mode" = setup ]; then
	boot_clean_vm
	run_guest setup setup
fi
if [ "$lane_mode" = all ] || [ "$lane_mode" = runtime ] || [ "$lane_mode" = migration ]; then
	boot_clean_vm
	run_guest management management
	run_guest runtime runtime
	if [ "$lane_mode" != runtime ]; then run_guest migration migration; fi
fi
# Package installation needs the pre-migration Nikki fixture, including its
# helper processes and caches; recreate it instead of undoing a native cutover.
if [ -n "$package_archive" ] && { [ "$lane_mode" = all ] || [ "$lane_mode" = package ]; }; then
	boot_clean_vm
	run_guest package-management management
	run_guest package-runtime runtime
	run_guest package package
fi

stage=receipt
total_elapsed_ms=$(($(now_ms) - total_started_ms))
python3 - "$receipt" "$source_commit" "$source_tree" "$version" "$image_sha" \
	"$work" "$mihomo_sha" "$yq_sha" "$runner_arch" "$guest_arch" "$qemu_version" \
	"$assets_elapsed_ms" "$image_elapsed_ms" "$boot_elapsed_ms" "$transfer_elapsed_ms" \
	"$total_elapsed_ms" "$lane_mode" "$package_manifest_sha" <<'PY'
import json
from pathlib import Path
import sys

work = Path(sys.argv[6])
mode = sys.argv[17]
package_sha = sys.argv[18]
required = {
    "all": {"native", "setup", "management", "runtime", "migration"},
    "native": {"native"}, "setup": {"setup"},
    "runtime": {"management", "runtime"},
    "migration": {"management", "runtime", "migration"},
    "package": {"package-management", "package-runtime", "package"},
    "compatibility": {"compatibility"},
}[mode]
if package_sha and mode == "all":
    required |= {"package-management", "package-runtime", "package"}
lanes = {}
for name in sorted(required):
    result = json.loads((work / f"{name}-result.json").read_text())
    checks = result.get("checks")
    if not (result.get("ok") is True
            and result.get("source_commit") == sys.argv[2]
            and result.get("source_tree") == sys.argv[3]
            and isinstance(checks, dict) and checks
            and all(item is True for item in checks.values())):
        raise SystemExit(f"OpenWrt {name} qualification returned an invalid receipt")
    if name == "package" and result.get("manifest_sha256") != package_sha:
        raise SystemExit("OpenWrt package qualification manifest mismatch")
    lanes[name] = result
runtime = lanes.get("runtime", lanes.get("package-runtime", {}))
management = lanes.get("management", lanes.get("package-management", {}))
value = {
    "schema": "opl-netfleet-openwrt-vm-qualification.v1",
    "qualified": mode == "all",
    "source_commit": sys.argv[2],
    "source_tree": sys.argv[3],
    "openwrt_version": sys.argv[4],
    "openwrt_image_sha256": sys.argv[5],
    "checks": {
        "boot": True,
        "ssh": True,
        "var_symlink": True,
        "ubus": True,
        **management.get("checks", {}),
        **runtime.get("checks", {}),
        **{f"{name}.{key}": passed for name, result in lanes.items()
           for key, passed in result["checks"].items()},
    },
    "metrics": runtime.get("metrics", {}),
    "runtime": runtime.get("runtime", {}),
    "lanes": lanes,
    "runtime_assets": {
        "mihomo_sha256": sys.argv[7],
        "yq_sha256": sys.argv[8],
    },
    "platform": {
        "runner_arch": sys.argv[9],
        "guest_arch": sys.argv[10],
        "qemu_system": "aarch64",
        "accelerator": "hvf",
        "qemu_version": sys.argv[11],
    },
    "qualification_metrics": {
        "assets_ms": int(sys.argv[12]),
        "image_ms": int(sys.argv[13]),
        "boot_ms": int(sys.argv[14]),
        "transfer_ms": int(sys.argv[15]),
        "total_ms": int(sys.argv[16]),
        **{f"{name}_guest_ms": int((work / f"{name}-ms").read_text()) for name in lanes},
    },
}
if "package" in lanes:
    value["schema"] = "opl-netfleet-openwrt-vm-qualification.v2"
    value["package_qualified"] = mode == "all"
    value["package"] = lanes["package"]
if mode != "all":
    value.update(schema="opl-netfleet-openwrt-vm-diagnostic.v1", diagnostic_passed=True,
                 diagnostic_lane=mode)
target = Path(sys.argv[1])
temporary = target.with_name(target.name + ".tmp")
temporary.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
temporary.replace(target)
PY
