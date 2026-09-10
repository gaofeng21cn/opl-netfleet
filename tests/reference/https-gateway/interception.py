import ipaddress
import hashlib
import json
import subprocess
import os
from pathlib import Path
import pwd
import re
import socket
import struct
import sys

from routing import admission, egress_policy


TABLE = "netfleet_compat"
PORT = 18443
LEASE_SECONDS = 10
CLAIM = Path("/var/run/opl-netfleet-core/interception.json")
IDENTITY_PATHS = [Path(path) for path in (
    "/etc/opl-netfleet/native/run/config.yaml", "/etc/config/netfleet",
    "/var/run/opl-netfleet-core/ownership.json", "/etc/opl-netfleet/backend.json",
    "/proc/sys/net/ipv4/ip_local_port_range")]


def run(arguments, *, input=None):
    result = subprocess.run(arguments, input=input, text=True, capture_output=True, timeout=1)
    if result.returncode:
        raise RuntimeError("gateway_command_failed")
    return result.stdout


def exists():
    try:
        run(["nft", "list", "table", "inet", TABLE])
        return True
    except (RuntimeError, subprocess.TimeoutExpired, OSError):
        return False


def prepare(interfaces, dscp_bypass=(), *, uid, owner, excluded_ports=()):
    if not interfaces or len(interfaces) > 16 or not all(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_.:-]{1,15}", name) for name in interfaces):
        raise ValueError("lan_interfaces_required")
    names = ", ".join(json.dumps(name) for name in interfaces)
    if not all(type(value) is int and 0 <= value <= 63 for value in dscp_bypass):
        raise ValueError("invalid_dscp_bypass")
    dscp = ", ".join(str(value) for value in dscp_bypass)
    exclusions = f"ip dscp {{ {dscp} }} return\n  ip6 dscp {{ {dscp} }} return" if dscp else ""
    if not all(type(port) is int and 1 <= port <= 65535 for port in excluded_ports):
        raise ValueError("invalid_source_port_exclusions")
    if excluded_ports:
        exclusions += "\n  tcp sport { " + ", ".join(map(str, excluded_ports)) + " } return"
    engine_uid = uid
    signature = hashlib.sha256(json.dumps([6, interfaces, list(dscp_bypass), engine_uid, owner, list(excluded_ports)]).encode()).hexdigest()
    present = exists()
    if present:
        current = json.loads(run(["nft", "-j", "list", "table", "inet", TABLE]))
        if any(item.get("table", {}).get("comment") == signature for item in current.get("nftables", [])):
            return
    run(["nft", "-f", "-"], input=(f"delete table inet {TABLE}\n" if present else "") + f"""table inet {TABLE} {{
 comment "{signature}"
 set targets4 {{ type ipv4_addr . ipv4_addr . inet_service; flags interval,timeout; timeout {LEASE_SECONDS}s; }}
 set targets6 {{ type ipv6_addr . ipv6_addr . inet_service; flags interval,timeout; timeout {LEASE_SECONDS}s; }}
 chain assign {{
  type filter hook prerouting priority -153; policy accept;
  {exclusions}
  ct status confirmed return
  iifname {{ {names} }} ct state new tcp flags & (syn | ack) == syn ip saddr . ip daddr . tcp dport @targets4 ct mark set ct mark | 0x01000000
  iifname {{ {names} }} ct state new tcp flags & (syn | ack) == syn ip6 saddr . ip6 daddr . tcp dport @targets6 ct mark set ct mark | 0x01000000
 }}
 chain intercept {{
  type nat hook prerouting priority -101; policy accept;
  ct direction original ct mark & 0x01000000 != 0 meta l4proto tcp redirect to :{PORT}
 }}
 chain private_listener {{
  type filter hook input priority -1; policy accept;
  tcp dport {PORT} ct status dnat accept
  tcp dport {PORT} reject with tcp reset
 }}
 chain local_probe {{
  type nat hook output priority -101; policy accept;
  meta skuid {engine_uid} meta priority 6 ip saddr 127.0.0.1 ip daddr 127.0.0.1 tcp dport 18445 redirect to :{PORT}
  meta skuid {engine_uid} meta priority 6 ip6 saddr ::1 ip6 daddr ::1 tcp dport 18445 redirect to :{PORT}
 }}
}}
""")


def bypass():
    if exists():
        run(["nft", "-f", "-"], input=f"flush set inet {TABLE} targets4\nflush set inet {TABLE} targets6\n")


def renew(candidates):
    if not isinstance(candidates, list) or len(candidates) > 4096:
        raise ValueError("lease_candidate_limit")
    groups = {4: set(), 6: set()}
    for source, destination, port in candidates:
        if not isinstance(source, str) or not isinstance(destination, str) or '%' in source or '%' in destination:
            raise ValueError("invalid_lease_candidate")
        source = ipaddress.ip_address(source)
        destination = ipaddress.ip_network(destination)
        if (source.is_unspecified or source.is_loopback or source.is_multicast or source.is_link_local
                or source.version != destination.version or type(port) is not int or not 1 <= port <= 65535):
            raise ValueError("invalid_lease_candidate")
        groups[source.version].add(f"{source} . {destination} . {port} timeout {LEASE_SECONDS}s")
    batch = ""
    for family, values in groups.items():
        batch += f"flush set inet {TABLE} targets{family}\n"
        if values:
            batch += f"add element inet {TABLE} targets{family} {{ {', '.join(sorted(values))} }}\n"
    run(["nft", "-f", "-"], input=batch)


def status():
    if not exists():
        return {"intercepting": False, "leases": 0}
    result = json.loads(run(["nft", "-j", "list", "table", "inet", TABLE]))
    leases = 0
    for item in result.get("nftables", []):
        for element in item.get("set", {}).get("elem", []):
            if element.get("elem", {}).get("expires", 0) > 0:
                leases += 1
    return {"intercepting": leases > 0, "leases": leases}


def remove():
    if exists():
        run(["nft", "delete", "table", "inet", TABLE])
    CLAIM.unlink(missing_ok=True)


def network_lock_held():
    target = Path("/var/lock/opl-netfleet-deploy.lock").stat()
    parent = os.getppid()
    for _ in range(64):
        if not parent:
            return False
        process = Path(f"/proc/{parent}")
        try:
            if process.stat().st_uid != 0:
                return False
            for info in (process / "fdinfo").iterdir():
                try:
                    fd = (process / "fd" / info.name).stat()
                    if ((fd.st_dev, fd.st_ino) == (target.st_dev, target.st_ino)
                            and re.search(r"lock:.*FLOCK\s+ADVISORY\s+WRITE\s", info.read_text())):
                        return True
                except OSError:
                    continue
            match = re.search(r"\nPPid:\s*(\d+)", (process / "status").read_text())
            parent = int(match[1]) if match else 0
        except OSError:
            return False
    return False


def descriptor(value):
    if not isinstance(value, dict) or set(value) != {"owner", "service", "instance", "user"}:
        raise ValueError("lease_owner_invalid")
    if not all(isinstance(item, str) and re.fullmatch(r"[a-z][a-z0-9-]{0,47}", item) for item in value.values()):
        raise ValueError("lease_owner_invalid")


def listener_owned(pid, uid):
    if type(pid) is not int or pid < 1:
        return False
    process = Path(f"/proc/{pid}")
    try:
        credentials = re.search(r"\nUid:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", (process / "status").read_text())
        if not credentials or set(map(int, credentials.groups())) != {uid}:
            return False
        sockets = {os.readlink(fd) for fd in (process / "fd").iterdir() if fd.is_symlink()}
        found = False
        for family in ("tcp", "tcp6"):
            for row in (process / "net" / family).read_text().splitlines()[1:]:
                fields = row.split()
                if fields[3] != "0A" or int(fields[1].split(":")[1], 16) != PORT:
                    continue
                if f"socket:[{fields[9]}]" not in sockets or int(fields[7]) != uid:
                    return False
                found = True
        return found
    except (OSError, ValueError):
        return False


def epoch(network):
    digest = hashlib.sha256()
    for path in IDENTITY_PATHS:
        digest.update(path.read_bytes() if path.exists() else b"")
        digest.update(b"\0")
    for key in ("core_pid", "engine_pid"):
        pid = network.get(key)
        path = Path(f"/proc/{pid}/stat")
        digest.update(path.read_bytes().rsplit(b") ", 1)[-1].split()[19] if path.exists() else b"")
        digest.update(str(pid).encode() + b"\0")
    return digest.hexdigest()


def egress(profile):
    policy = egress_policy(profile, list(map(int, IDENTITY_PATHS[-1].read_text().split())))
    if policy["port_range"]:
        lower, upper = policy["port_range"]
        value = struct.pack("I", (upper << 16) | lower)
        try:
            for family in (socket.AF_INET, socket.AF_INET6):
                with socket.socket(family, socket.SOCK_STREAM) as sock:
                    sock.setsockopt(socket.IPPROTO_IP, 51, value)
                    if sock.getsockopt(socket.IPPROTO_IP, 51, 4) != value:
                        raise OSError("port range readback failed")
        except OSError:
            raise ValueError("egress_port_range_unsupported") from None
    return policy


def dispatch(owner, request, network):
    descriptor(owner)
    if not isinstance(request, dict) or set(request) - {"action", "epoch", "candidates"}:
        raise ValueError("lease_request_invalid")
    action = request.get("action")
    if action == "status":
        return status()
    if action == "snapshot":
        profile = json.loads(IDENTITY_PATHS[0].read_bytes()) if IDENTITY_PATHS[0].exists() else {}
        reason = admission(profile, network)
        policy = None
        if not reason:
            try:
                policy = egress(profile)
            except ValueError as error:
                reason = str(error)
        return {**network, "epoch": epoch(network), "reason": reason, "egress": policy}
    if action not in ("prepare", "renew", "bypass", "remove"):
        raise ValueError("lease_action_invalid")
    if not network_lock_held():
        raise ValueError("lease_network_lock_required")
    claimed = json.loads(CLAIM.read_bytes()) if CLAIM.exists() else None
    if claimed and claimed != owner:
        raise ValueError("lease_owner_conflict")
    if action in ("bypass", "remove"):
        (bypass if action == "bypass" else remove)()
        return status()
    profile = json.loads(IDENTITY_PATHS[0].read_bytes()) if IDENTITY_PATHS[0].exists() else {}
    reason = admission(profile, network)
    if reason:
        bypass()
        raise ValueError(reason)
    if request.get("epoch") != epoch(network):
        raise ValueError("lease_gateway_changed")
    uid = pwd.getpwnam(owner["user"]).pw_uid
    if uid == 0:
        raise ValueError("lease_unprivileged_listener_required")
    if not listener_owned(network.get("engine_pid"), uid):
        bypass()
        raise ValueError("lease_listener_unconfirmed")
    # The backend offers one transparent TCP slot. A second owner cannot replace
    # the active listener, mark or table; additional slots require platform support.
    if claimed is None:
        CLAIM.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = CLAIM.with_suffix('.new')
        with temporary.open("w") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(owner, stream)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(CLAIM)
    policy = egress(profile)
    prepare(network["interfaces"], network.get("dscp_bypass", []), uid=uid, owner=owner,
            excluded_ports=policy["excluded_ports"])
    if action == "renew":
        renew(request.get("candidates"))
    return status()


if __name__ == "__main__":
    try:
        envelope = json.loads(Path(sys.argv[1]).read_bytes())
        print(json.dumps({"ok": True, "result": dispatch(envelope["owner"], envelope["request"], envelope["network"])}))
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, subprocess.SubprocessError) as error:
        code = str(error) if isinstance(error, ValueError) and re.fullmatch(r"[a-z_]+", str(error)) else "lease_operation_failed"
        print(json.dumps({"ok": False, "error": code}))
        sys.exit(1)
