import ipaddress
import hashlib
import json
import subprocess

from recovery import LEASE_SECONDS


TABLE = "netfleet_compat"
PORT = 18443


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


def prepare(interfaces, dscp_bypass=()):
    if not interfaces or not all(isinstance(name, str) and name and len(name) <= 15 for name in interfaces):
        raise ValueError("lan_interfaces_required")
    names = ", ".join(json.dumps(name) for name in interfaces)
    if not all(type(value) is int and 0 <= value <= 63 for value in dscp_bypass):
        raise ValueError("invalid_dscp_bypass")
    dscp = ", ".join(str(value) for value in dscp_bypass)
    exclusions = f"ip dscp {{ {dscp} }} return\n  ip6 dscp {{ {dscp} }} return" if dscp else ""
    signature = hashlib.sha256(json.dumps([2, interfaces, list(dscp_bypass)]).encode()).hexdigest()
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
}}
""")


def bypass():
    if exists():
        run(["nft", "-f", "-"], input=f"flush set inet {TABLE} targets4\nflush set inet {TABLE} targets6\n")


def renew(candidates):
    groups = {4: set(), 6: set()}
    for source, destination, port in candidates:
        source = ipaddress.ip_address(source)
        destination = ipaddress.ip_network(destination)
        if source.version != destination.version or type(port) is not int or not 1 <= port <= 65535:
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
