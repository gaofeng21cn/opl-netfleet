"""Conservative admission before replacing a LAN connection with router egress."""


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
            if not gateway.get("preserve_source_port"):
                return "source_port_not_preserved"
        elif kind == "RULE-SET":
            provider = profile.get("rule-providers", {}).get(fields[1] if len(fields) > 1 else "", {})
            if provider.get("behavior") not in ("domain", "ipcidr"):
                return "rule_provider_not_equivalent"
        elif kind not in safe:
            return "source_or_unsupported_routing_rule"
    return None
