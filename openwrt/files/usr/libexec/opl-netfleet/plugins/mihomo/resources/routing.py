"""Gateway-owned admission for replacing a LAN connection with router egress."""

import re


def source_ports(profile):
    ports = set()
    for rule in profile.get("rules", []):
        if isinstance(rule, str) and rule.startswith("SRC-PORT,"):
            fields = rule.split(",")
            if len(fields) != 3 or not re.fullmatch(r"[0-9]{1,5}", fields[1]) or not 1 <= int(fields[1]) <= 65535:
                raise ValueError("source_port_rule_unsupported")
            ports.add(int(fields[1]))
    return sorted(ports)


def egress_policy(profile, ephemeral):
    excluded = source_ports(profile)
    if not excluded:
        return {"excluded_ports": [], "port_range": None}
    lower, upper = ephemeral
    if not 1 <= lower < upper <= 65535:
        raise ValueError("egress_port_range_unavailable")
    boundaries = [lower - 1, *[port for port in excluded if lower <= port <= upper], upper + 1]
    ranges = [(left + 1, right - 1) for left, right in zip(boundaries, boundaries[1:]) if right - left > 2]
    if not ranges:
        raise ValueError("egress_port_range_unavailable")
    return {"excluded_ports": excluded, "port_range": list(max(ranges, key=lambda pair: pair[1] - pair[0]))}


def admission(profile, gateway):
    if gateway.get("backend") != "native-mihomo" or not gateway.get("ready"):
        return "native_gateway_not_ready"
    if gateway.get("compatibility_ownership_guard") is not True:
        return "native_ownership_guard_missing"
    if not gateway.get("router_proxy") or not gateway.get("lan_proxy"):
        return "router_lan_paths_differ"
    if gateway.get("source_bypass"):
        return "source_bypass_not_equivalent"
    if gateway.get("custom_lan_access"):
        return "lan_access_not_equivalent"
    if profile.get("listeners") or profile.get("sub-rules"):
        return "custom_listeners_or_subrules"
    safe = {"DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX", "GEOSITE",
            "IP-CIDR", "IP-CIDR6", "IP-SUFFIX", "IP-ASN", "GEOIP", "DST-PORT", "NETWORK", "MATCH"}
    for rule in profile.get("rules", []):
        if not isinstance(rule, str):
            return "routing_rule_unreadable"
        fields = rule.split(",")
        kind = fields[0]
        if kind == "SRC-PORT":
            try:
                source_ports({"rules": [rule]})
            except ValueError as error:
                return str(error)
        elif kind == "RULE-SET":
            provider = profile.get("rule-providers", {}).get(fields[1] if len(fields) > 1 else "", {})
            if provider.get("behavior") not in ("domain", "ipcidr"):
                return "rule_provider_not_equivalent"
        elif kind not in safe:
            return "source_or_unsupported_routing_rule"
    return None
