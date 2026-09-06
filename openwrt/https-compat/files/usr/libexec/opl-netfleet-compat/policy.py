import ipaddress
import re


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", value):
        raise ValueError("invalid_id")
    return value


def hostname(value):
    if not isinstance(value, str):
        raise ValueError("invalid_domain")
    value = value.rstrip(".").encode("idna").decode("ascii").lower()
    if len(value) > 253 or not all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in value.split(".")):
        raise ValueError("invalid_domain")
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return value
    raise ValueError("domain_required")


def validate(config):
    if not isinstance(config, dict) or config.get("schema") != 1 or type(config.get("enabled")) is not bool:
        raise ValueError("invalid_config")
    devices = config.get("devices")
    rules = config.get("rules")
    if not isinstance(devices, list) or not isinstance(rules, list):
        raise ValueError("invalid_config")
    ids, addresses, identities = set(), set(), set()
    normalized_devices, normalized_rules = [], []
    for device in devices:
        if not isinstance(device, dict):
            raise ValueError("invalid_device")
        identity = identifier(device.get("id"))
        if identity in ids or not isinstance(device.get("name"), str) or not device["name"].strip():
            raise ValueError("invalid_device")
        ids.add(identity)
        entries = device.get("addresses")
        if not isinstance(entries, list) or not entries:
            raise ValueError("device_address_required")
        if not all(isinstance(address, str) for address in entries):
            raise ValueError("invalid_device_address")
        parsed = [str(ipaddress.ip_address(address)) for address in entries]
        if len(set(parsed)) != len(parsed) or addresses.intersection(parsed):
            raise ValueError("duplicate_device_address")
        addresses.update(parsed)
        normalized_devices.append({"id": identity, "name": device["name"], "addresses": parsed})
    rule_ids = set()
    for rule in rules:
        if not isinstance(rule, dict):
            raise ValueError("invalid_rule")
        identity = identifier(rule.get("id"))
        if identity in rule_ids or not isinstance(rule.get("name"), str) or not rule["name"].strip():
            raise ValueError("invalid_rule")
        rule_ids.add(identity)
        if type(rule.get("enabled")) is not bool or rule.get("match") not in ("exact", "suffix") or rule.get("strategy") not in ("h2", "bypass"):
            raise ValueError("invalid_rule")
        port = rule.get("port")
        if type(port) is not int or not 1 <= port <= 65535:
            raise ValueError("invalid_port")
        targets = rule.get("devices")
        if not isinstance(targets, list) or not targets or not all(isinstance(target, str) for target in targets) or len(set(targets)) != len(targets) or not set(targets) <= ids:
            raise ValueError("invalid_rule_devices")
        domain = hostname(rule.get("domain"))
        for device in targets:
            key = (device, port, rule["match"], domain)
            if key in identities:
                raise ValueError("conflicting_rule")
            identities.add(key)
        normalized_rules.append({"id": identity, "name": rule["name"], "enabled": rule["enabled"], "devices": targets,
                                 "domain": domain, "match": rule["match"], "port": port, "strategy": rule["strategy"]})
    return {"schema": 1, "enabled": config["enabled"], "devices": normalized_devices, "rules": normalized_rules}


def select(config, address, domain, port):
    if not config or not config["enabled"] or not domain:
        return None
    try:
        address = str(ipaddress.ip_address(address))
        domain = hostname(domain)
    except (ValueError, UnicodeError):
        return None
    device = next((item["id"] for item in config["devices"] if address in item["addresses"]), None)
    candidates = [rule for rule in config["rules"] if rule["enabled"] and device in rule["devices"] and rule["port"] == port
                  and (domain == rule["domain"] or (rule["match"] == "suffix" and domain.endswith("." + rule["domain"])))]
    return max(candidates, key=lambda rule: (rule["match"] == "exact", len(rule["domain"])), default=None)
