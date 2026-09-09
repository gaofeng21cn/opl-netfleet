"""Network-owned address evidence. No consumer policy or firewall writes."""
import fcntl
import hashlib
import hmac
from http.cookies import SimpleCookie
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit, quote
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))

BASE = Path("/etc/opl-netfleet/device-identity")
RUN = Path("/var/run/opl-netfleet-device-identity")
INTERVAL = 30
TTL = 120
MAX_BODY = 2 * 1024 * 1024
DEFAULT = {"enabled": False, "source": "local", "interfaces": []}


def read(path, default=None):
    try:
        return json.loads(path.read_bytes())
    except (OSError, ValueError):
        return default


def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def mac(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}", value):
        raise ValueError("invalid_device_mac")
    if int(value[:2], 16) & 1 or value.lower() == "00:00:00:00:00:00":
        raise ValueError("invalid_device_mac")
    return value.lower()


def address(value):
    if not isinstance(value, str) or "%" in value:
        return None
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return None
    if ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_unspecified or getattr(ip, "ipv4_mapped", None):
        return None
    return str(ip)


def validate(value, previous=None):
    if not isinstance(value, dict) or value.get("source") not in ("local", "unifi") or type(value.get("enabled")) is not bool:
        raise ValueError("invalid_source_config")
    result = {"enabled": value["enabled"], "source": value["source"]}
    if value["source"] == "local":
        interfaces = value.get("interfaces", [])
        if (not isinstance(interfaces, list) or len(interfaces) > 16 or
                any(not isinstance(item, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,15}", item) for item in interfaces)):
            raise ValueError("invalid_source_interfaces")
        if value["enabled"] and not interfaces:
            raise ValueError("source_interface_required")
        return {**result, "interfaces": sorted(set(interfaces))}
    endpoint = value.get("endpoint", "")
    if not isinstance(endpoint, str):
        raise ValueError("invalid_controller_url")
    url = urlsplit(endpoint)
    if (url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment
            or url.path not in ("", "/") or len(endpoint) > 256):
        raise ValueError("invalid_controller_url")
    port = url.port
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("invalid_controller_url")
    site = value.get("site", "default")
    username = value.get("username", "")
    pin = value.get("certificate_sha256", "")
    if not isinstance(site, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", site):
        raise ValueError("invalid_controller_site")
    if not isinstance(username, str) or not 1 <= len(username) <= 128:
        raise ValueError("controller_username_required")
    if not isinstance(pin, str) or pin and not re.fullmatch(r"[0-9a-fA-F]{64}", pin):
        raise ValueError("invalid_controller_fingerprint")
    result.update(endpoint=endpoint.rstrip("/"), site=site, username=username, certificate_sha256=pin.lower())
    password = value.get("password")
    if password is None and previous and all(result.get(key) == previous.get(key) for key in ("source", "endpoint", "site", "username", "certificate_sha256")):
        password = previous.get("password")
    if not isinstance(password, str) or not 1 <= len(password) <= 1024:
        raise ValueError("controller_password_required")
    return {**result, "password": password}


def binding(config):
    return digest({key: value for key, value in config.items() if key not in ("enabled", "password", "username")})


def revision(config):
    # A public revision must not act as an offline password verifier.
    key = read(BASE / "revision-key.json")
    return hmac.new(bytes.fromhex(key), json.dumps(config, sort_keys=True).encode(), hashlib.sha256).hexdigest() if key else None


def request(config, path, method="GET", body=None, cookie=None):
    import http.client
    import ssl

    url = urlsplit(config["endpoint"])
    pin = config.get("certificate_sha256")
    context = ssl.create_default_context()
    if pin:
        # Pinning replaces CA validation only for this explicitly enrolled controller.
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    connection = http.client.HTTPSConnection(url.hostname, url.port or 443, context=context, timeout=1.5)
    try:
        connection.connect()
        if pin and hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest() != pin:
            raise ValueError("controller_certificate_changed")
        headers = {"Accept": "application/json"}
        if cookie:
            headers["Cookie"] = cookie
        if body is not None:
            headers["Content-Type"] = "application/json"
        connection.request(method, path, json.dumps(body).encode() if body is not None else None, headers)
        response = connection.getresponse()
        raw = response.read(MAX_BODY + 1)
        if len(raw) > MAX_BODY:
            raise ValueError("controller_response_too_large")
        cookies = SimpleCookie()
        for key, value in response.getheaders():
            if key.lower() == "set-cookie":
                cookies.load(value)
        # Never follow redirects or include response bodies in diagnostics.
        return response.status, raw, "; ".join(f"{key}={value.value}" for key, value in cookies.items())
    finally:
        connection.close()


def unifi(config, now):
    session = read(RUN / "session.json", {})
    cookie = session.get("cookie") if session.get("revision") == revision(config) else None
    path = f"/proxy/network/v2/api/site/{quote(config['site'], safe='')}/clients/active?includeTrafficUsage=false&includeUnifiDevices=false"
    status, raw, _ = request(config, path, cookie=cookie) if cookie else (401, None, None)
    if status == 401:
        status, _, cookie = request(config, "/api/auth/login", "POST", {"username": config["username"], "password": config["password"], "rememberMe": False})
        if status != 200 or not cookie:
            raise ValueError("controller_authentication_failed")
        atomic(RUN / "session.json", {"revision": revision(config), "cookie": cookie})
        status, raw, _ = request(config, path, cookie=cookie)
    if status in (401, 403):
        raise ValueError("controller_access_denied")
    if status != 200:
        raise ValueError("controller_request_failed")
    rows = json.loads(raw)
    if not isinstance(rows, list) or len(rows) > 1024:
        raise ValueError("controller_response_invalid")
    devices = []
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("controller_response_invalid")
        try:
            identity = mac(row.get("mac"))
        except ValueError:
            continue
        seen = row.get("last_seen")
        ipv6 = row.get("ipv6_address")
        if type(seen) not in (float, int) or seen > now + 5 or now - seen >= TTL:
            continue
        complete = isinstance(ipv6, list) and all(isinstance(ip, str) for ip in ipv6)
        addresses = [address(ip) for ip in [row.get("ip"), *(ipv6 if complete else [])]] if complete else []
        devices.append({"mac": identity, "name": str(row.get("hostname") or row.get("name") or identity)[:128],
                        "addresses": sorted({ip for ip in addresses if ip}), "ttl": min(TTL, max(0, TTL - (now - seen))),
                        "reason": None if complete else "controller_ipv6_data_missing"})
    return devices


def ip_command(*args):
    result = subprocess.run(["ip", "-j", *args], capture_output=True, timeout=0.5, check=True)
    if len(result.stdout) > MAX_BODY:
        raise ValueError("local_response_too_large")
    return json.loads(result.stdout)


def local(config, now):
    from neighbor import observe

    devices = {}
    observed_at = time.monotonic()
    neighbours = ip_command("neigh", "show")[:1024]
    for row in neighbours:
        if row.get("dev") not in config["interfaces"] or not set(row.get("state", [])) & {"REACHABLE", "DELAY", "PROBE"}:
            continue
        ip = address(row.get("dst"))
        try:
            identity = mac(row.get("lladdr"))
        except ValueError:
            continue
        if not ip:
            continue
        routes = ip_command("route", "get", ip)
        if (len(routes) != 1 or routes[0].get("gateway") or routes[0].get("dev") != row["dev"]
                or routes[0].get("type", "unicast") != "unicast"):
            continue
        item = devices.setdefault(identity, {"mac": identity, "name": identity, "addresses": [], "ttl": TTL, "reason": None})
        item["addresses"].append(ip)
    links = []
    for row in ip_command("address", "show"):
        if row.get("ifname") not in config["interfaces"] or "UP" not in row.get("flags", []):
            continue
        sources = [ip["local"] for ip in row.get("addr_info", [])
                   if ip.get("family") == "inet6" and ip.get("scope") == "link"
                   and not ip.get("tentative") and not ip.get("dadfailed")]
        if sources and row.get("address"):
            links.append((row["ifname"], sources[0], mac(row["address"])))
    if not links:
        raise ValueError("local_observation_interface_unavailable")
    current = read(RUN / "cache.json", {})
    previous = current.get("devices", []) if current.get("revision") == revision(config) else []
    candidates = sorted({ip for value in [
        *(row.get("dst") for row in neighbours),
        *(ip for row in previous for ip in row.get("addresses", [])),
        *connection_addresses(),
    ] if (ip := address(value)) and ipaddress.ip_address(ip).version == 6})
    cursor = read(RUN / "cursor.json", 0) % max(1, len(candidates))
    selected = (candidates[cursor:] + candidates[:cursor])[:64]
    confirmed = observe(links, selected)
    atomic(RUN / "cursor.json", cursor + len(selected))
    for item in devices.values():
        item["address_expires"] = {ip: observed_at + TTL for ip in item["addresses"]}
    for old in previous:
        for ip in old["addresses"]:
            expiry = old.get("address_expires", {}).get(ip, current["monotonic"] + old["ttl"])
            if ip in selected or not observed_at < expiry <= observed_at + TTL:
                continue
            item = devices.setdefault(old["mac"], {"mac": old["mac"], "name": old["name"], "addresses": [],
                                                   "ttl": TTL, "reason": None, "address_expires": {}})
            if ip not in item["addresses"]:
                item["addresses"].append(ip)
                item["address_expires"][ip] = expiry
    ownership = {}
    for ip, identity in confirmed:
        ownership.setdefault(ip, set()).add(identity)
    # Revalidated addresses replace neighbour-cache claims, including conflicts.
    for item in devices.values():
        item["addresses"] = [ip for ip in item["addresses"] if ip not in selected]
    for ip, identities in ownership.items():
        for identity in identities:
            item = devices.setdefault(identity, {"mac": identity, "name": identity, "addresses": [], "ttl": TTL,
                                                  "reason": None, "address_expires": {}})
            item["addresses"].append(ip)
            item["address_expires"][ip] = observed_at + TTL
    for item in devices.values():
        item["addresses"] = sorted(set(item["addresses"]))
        item["address_expires"] = {ip: item["address_expires"][ip] for ip in item["addresses"]}
    return list(devices.values())


def connection_addresses():
    result = subprocess.run(["conntrack", "-L", "-f", "ipv6", "-o", "xml"],
                            capture_output=True, timeout=0.8, check=True)
    if len(result.stdout) > MAX_BODY:
        raise ValueError("local_response_too_large")
    try:
        root = ET.fromstring(result.stdout)
    except ET.ParseError as error:
        raise ValueError("local_connections_invalid") from error
    return [row.text for row in root.findall("./flow/meta[@direction='original']/layer3/src") if row.text]


def unique_devices(devices):
    ownership, identities = {}, {}
    for device in devices:
        identities[device["mac"]] = identities.get(device["mac"], 0) + 1
        for ip in device["addresses"]:
            ownership.setdefault(ip, set()).add(device["mac"])
    result = []
    for device in devices:
        conflict = identities[device["mac"]] != 1
        accepted = [] if conflict else [ip for ip in device["addresses"] if len(ownership[ip]) == 1]
        result.append({**device, "addresses": accepted,
                       "reason": "address_identity_conflict" if conflict or len(accepted) != len(device["addresses"]) else device["reason"]})
    return result


def status(config):
    loaded = read(BASE / "loaded.json", False) is True
    cache = read(RUN / "cache.json", {})
    same = cache.get("revision") == revision(config)
    now = time.monotonic()
    age = now - cache.get("monotonic", -TTL)
    fresh = loaded and config["enabled"] and same and 0 <= age < TTL
    devices = []
    for row in cache.get("devices", []) if same else []:
        remaining = {ip: expiry - now for ip in row["addresses"]
                     if (expiry := row.get("address_expires", {}).get(ip, cache["monotonic"] + row["ttl"])) > now}
        devices.append({**{key: value for key, value in row.items() if key != "address_expires"},
                        "addresses": sorted(remaining) if fresh else [],
                        "expires_in": max(0, math.ceil(min(remaining.values(), default=0))) if fresh else 0,
                        "reason": row["reason"] if fresh and (remaining or row["reason"]) else "address_evidence_expired"})
    error = read(RUN / "attempt.json", {})
    error = error if error.get("revision") == revision(config) else {}
    reason = "source_disabled" if not loaded or not config["enabled"] else error.get("reason") or (None if fresh else "address_evidence_expired")
    return {"loaded": loaded, "ready": loaded, "source_ready": bool(fresh), "config_revision": revision(config), "binding": binding(config),
            "config": {key: value for key, value in config.items() if key != "password"},
            "credential_present": bool(config.get("password")), "reason": reason, "last_attempt": error.get("at"),
            "last_success": cache.get("at") if same else None, "devices": devices}


def publish(config):
    """Owner-published read contract; never expose configuration or credentials."""
    cache = read(RUN / "cache.json", {})
    now = time.monotonic()
    valid = (read(BASE / "loaded.json", False) is True and config["enabled"]
             and cache.get("revision") == revision(config)
             and 0 <= now - cache.get("monotonic", -TTL) < TTL)
    rows = []
    for row in cache.get("devices", []) if valid else []:
        expires = {ip: min(expiry, cache["monotonic"] + TTL) for ip in row["addresses"]
                   if now < (expiry := row.get("address_expires", {}).get(ip, cache["monotonic"] + row["ttl"]))
                   <= now + TTL}
        rows.append({"mac": row["mac"], "address_expires": expires})
    atomic(RUN / "evidence.json", {"schema": 1, "binding": binding(config),
           "sampled_monotonic": cache.get("monotonic", now), "source_ready": bool(valid), "devices": rows})


def sync(config, force=False):
    if not config["enabled"]:
        return status(config)
    previous = read(RUN / "attempt.json", {})
    elapsed = time.monotonic() - previous.get("monotonic", -INTERVAL)
    if not force and previous.get("revision") == revision(config) and 0 <= elapsed < INTERVAL:
        publish(config)
        return status(config)
    import http.client
    import ssl

    attempt = {"revision": revision(config), "at": time.time(), "monotonic": time.monotonic(), "reason": None}
    atomic(RUN / "attempt.json", attempt)
    try:
        devices = unique_devices((unifi if config["source"] == "unifi" else local)(config, time.time()))
        if len(devices) > 256:
            raise ValueError("too_many_source_devices")
        atomic(RUN / "cache.json", {**attempt, "devices": devices})
    except ssl.SSLCertVerificationError:
        attempt["reason"] = "controller_certificate_untrusted"
    except (socket.timeout, TimeoutError):
        attempt["reason"] = "controller_timeout"
    except ValueError as error:
        attempt["reason"] = str(error) if re.fullmatch(r"[a-z_]+", str(error)) else "controller_response_invalid"
    except (OSError, http.client.HTTPException, subprocess.SubprocessError):
        attempt["reason"] = "source_unavailable"
    atomic(RUN / "attempt.json", attempt)
    publish(config)
    return status(config)


def dispatch(action, params):
    config = read(BASE / "config.json", DEFAULT)
    if action in ("get", "resolve"):
        return status(config)
    RUN.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (RUN / "lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if action == "sync":
                return status(config)
            raise ValueError("identity_mutation_busy")
        config = read(BASE / "config.json", DEFAULT)
        if action in ("load", "unload"):
            (RUN / "evidence.json").unlink(missing_ok=True)
            if action == "load" and not (BASE / "revision-key.json").exists():
                atomic(BASE / "revision-key.json", os.urandom(32).hex())
            atomic(BASE / "loaded.json", action == "load")
            if action == "unload":
                for name in ("cache.json", "session.json"):
                    (RUN / name).unlink(missing_ok=True)
            return status(config)
        if read(BASE / "loaded.json", False) is not True:
            raise ValueError("identity_plugin_not_loaded")
        if action == "sync":
            return sync(config)
        if action == "configure":
            if params.get("config_revision") != revision(config):
                raise ValueError("identity_revision_conflict")
            config = validate(params.get("config"), config)
        else:
            raise ValueError("unknown_identity_action")
        (RUN / "evidence.json").unlink(missing_ok=True)
        atomic(BASE / "config.json", config)
        return status(config)


def main():
    os.umask(0o077)
    try:
        action, path = sys.argv[1:]
        envelope = read(Path(path), {}).get("request", {})
        if envelope.get("id") != "device-identity" or envelope.get("api_version") != 1 or envelope.get("action") != action:
            raise ValueError("invalid_identity_request")
        def timeout(signum, frame):
            raise TimeoutError()
        signal.signal(signal.SIGALRM, timeout)
        signal.alarm(5)
        result = dispatch(action, envelope.get("params", {}))
        response = {"ok": True, "result": result}
    except Exception as error:
        code = str(error) if isinstance(error, ValueError) and re.fullmatch(r"[a-z_]+", str(error)) else "identity_operation_failed"
        response = {"ok": False, "error": code}
    raw = json.dumps(response)
    if len(raw.encode()) > 64000:
        response = {"ok": False, "error": "identity_response_too_large"}
    print(json.dumps(response))
    sys.exit(0 if response["ok"] else 1)
