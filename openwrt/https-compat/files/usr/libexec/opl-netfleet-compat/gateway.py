import ipaddress
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


def prepare(interfaces):
    if exists():
        return
    if not interfaces or not all(isinstance(name, str) and name and len(name) <= 15 for name in interfaces):
        raise ValueError("lan_interfaces_required")
    names = ", ".join(json.dumps(name) for name in interfaces)
    run(["nft", "-f", "-"], input=f"""table inet {TABLE} {{
 set targets4 {{ type ipv4_addr . ipv4_addr . inet_service; flags interval,timeout; timeout {LEASE_SECONDS}s; }}
 set targets6 {{ type ipv6_addr . ipv6_addr . inet_service; flags interval,timeout; timeout {LEASE_SECONDS}s; }}
 chain intercept {{
  type nat hook prerouting priority -152; policy accept;
  iifname {{ {names} }} meta l4proto tcp ip saddr . ip daddr . tcp dport @targets4 redirect to :{PORT}
  iifname {{ {names} }} meta l4proto tcp ip6 saddr . ip6 daddr . tcp dport @targets6 redirect to :{PORT}
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
