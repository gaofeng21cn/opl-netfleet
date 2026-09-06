#!/usr/bin/python3
import fcntl
import asyncio
import hashlib
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tarfile
import time

sys.path.insert(0, "/usr/lib/opl-netfleet-compat/vendor")

import gateway
from policy import validate
from recovery import advance
from routing import admission


BASE = Path("/etc/opl-netfleet/compatibility")
RUN = Path("/var/run/opl-netfleet-compat")
CONFIG = BASE / "config.json"
STATE = RUN / "state.json"
EFFECTIVE = RUN / "effective.json"
TRUST = BASE / "trust.json"
CA = BASE / "ca"
SERVICE = "/etc/init.d/opl-netfleet-compat"
OWNER = "/usr/libexec/opl-netfleet/application/native_gateway.uc"
DEFAULT = {"schema": 1, "enabled": False, "devices": [], "rules": []}


def read(path, fallback=None):
    try:
        return json.loads(path.read_bytes())
    except FileNotFoundError:
        return fallback


def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    data = json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    temporary = path.with_suffix(".new")
    with temporary.open("wb") as stream:
        os.chmod(temporary, 0o600)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def revision():
    return hashlib.sha256(CONFIG.read_bytes() + b"\0" + (TRUST.read_bytes() if TRUST.exists() else b"")).hexdigest() if CONFIG.exists() else None


def ca_fingerprint():
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes
    path = CA / "mitmproxy-ca-cert.pem"
    return x509.load_pem_x509_certificate(path.read_bytes()).fingerprint(hashes.SHA256()).hex() if path.exists() else None


def prepare_ca():
    from mitmproxy.certs import CertStore
    from cryptography import x509
    from cryptography.hazmat.primitives import serialization
    CA.mkdir(parents=True, exist_ok=True, mode=0o700)
    # A partial or damaged existing authority must not silently replace a trusted root.
    if (CA / "mitmproxy-ca-cert.pem").exists() and not (CA / "mitmproxy-ca.pem").exists():
        raise ValueError("ca_private_key_missing")
    store = CertStore.from_store(CA, "mitmproxy", 2048)
    entry = store.get_cert("localhost", [x509.DNSName("localhost")])
    (CA / "probe-cert.pem").write_bytes(entry.cert.to_pem())
    (CA / "probe-key.pem").write_bytes(entry.privatekey.private_bytes(serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    bundle = Path("/etc/ssl/certs/ca-certificates.crt").read_bytes()
    (CA / "upstream-trust.pem").write_bytes(bundle + (CA / "mitmproxy-ca-cert.pem").read_bytes())
    for path in CA.iterdir():
        if path.is_file():
            os.chmod(path, 0o600)


def engine_health(probe=False):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(1.8 if probe else 0.4)
            connection.connect(str(RUN / "engine.sock"))
            connection.sendall(b"probe\n" if probe else b"status\n")
            with connection.makefile("rb") as stream:
                value = json.loads(stream.readline(65536))
                if value.get("service") == "netfleet-https-compat":
                    return value
    except (OSError, ValueError):
        pass
    connections = None
    try:
        result = subprocess.run(["ubus", "call", "service", "list", '{"name":"opl-netfleet-compat"}'],
                                capture_output=True, text=True, timeout=0.4)
        if result.returncode == 0:
            instances = json.loads(result.stdout).get("opl-netfleet-compat", {}).get("instances", {})
            if not any(instance.get("running") for instance in instances.values()):
                connections = 0
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return {"ready": False, "active_requests": None, "active_connections": connections, "rules": {}}


def snapshot():
    result = subprocess.run(["ucode", OWNER, "compatibility-snapshot"], capture_output=True, text=True, timeout=1)
    if result.returncode:
        raise ValueError("native_gateway_unavailable")
    return json.loads(result.stdout)["result"]


def verified_trust(config, trust, fingerprint):
    return {device["id"]: trust[device["id"]] for device in config["devices"]
            if fingerprint and trust.get(device["id"], {}).get("ca_sha256") == fingerprint
            and trust[device["id"]].get("addresses") == device["addresses"]
            and trust[device["id"]].get("verified") is True}


def effective(config, trust, fingerprint):
    devices = verified_trust(config, trust, fingerprint)
    return {**config, "rules": [{**rule, "devices": [device for device in rule["devices"] if device in devices]}
                                 for rule in config["rules"] if any(device in devices for device in rule["devices"])]}


async def probe_rules(rules):
    context = ssl.create_default_context()
    context.set_alpn_protocols(["h2"])
    async def check(rule):
        writer = None
        try:
            async with asyncio.timeout(0.7):
                _, writer = await asyncio.open_connection(rule.get("address", rule["domain"]), rule["port"], ssl=context, server_hostname=rule["domain"])
                return rule["id"], writer.get_extra_info("ssl_object").selected_alpn_protocol() == "h2"
        except (OSError, asyncio.TimeoutError):
            return rule["id"], False
        finally:
            if writer:
                writer.close()
    return dict(await asyncio.gather(*(check(rule) for rule in rules)))


def status():
    config = validate(read(CONFIG, DEFAULT))
    state = read(STATE, {})
    health = engine_health()
    kernel = gateway.status()
    fingerprint = ca_fingerprint()
    reason = state.get("reason", "disabled" if not config["enabled"] else "not_ready")
    if not kernel["intercepting"] and state.get("intercepting"):
        reason = "lease_expired"
    if not config["enabled"]:
        reason = "draining" if health.get("active_connections") else "disabled"
    return {"installed": True, "revision": revision(), "config": config, "requested": config["enabled"],
            **kernel, "reason": reason, "active_connections": health.get("active_connections"),
            "device_connections": {device["id"]: sum(health.get("clients_by_address", {}).get(address, 0) for address in device["addresses"])
                                   if health.get("active_connections") is not None else None for device in config["devices"]},
            "active_requests": health.get("active_requests"), "rules": health.get("rules", {}),
            "recovery": state.get("recovery", {}), "ca_sha256": fingerprint,
            "rule_recovery": state.get("rule_recovery", {}),
            "trust": verified_trust(config, read(TRUST, {}), fingerprint), "events": state.get("events", [])[-100:]}


def save_state(state, previous):
    events = previous.get("events", [])
    if (state.get("reason"), state.get("intercepting")) != (previous.get("reason"), previous.get("intercepting")):
        events = [*events, {"at": int(time.time()), "reason": state.get("reason"), "intercepting": state.get("intercepting", False)}][-100:]
    for identity, current in state.get("rule_recovery", {}).items():
        old = previous.get("rule_recovery", {}).get(identity, {})
        if (current.get("reason"), current.get("intercepting")) != (old.get("reason"), old.get("intercepting")):
            events = [*events, {"at": int(time.time()), "rule": identity, "reason": current.get("reason"), "intercepting": current.get("intercepting", False)}][-100:]
    atomic(STATE, {**state, "events": events, "last_tick": time.monotonic()})


def tick():
    config = validate(read(CONFIG, DEFAULT))
    previous = read(STATE, {})
    now = time.monotonic()
    if now - previous.get("last_tick", now) > 10:
        previous["recovery"] = advance(previous.get("recovery"), requested=config["enabled"],
                                        healthy=False, reason="management_lease_expired", now=now)
    if not config["enabled"]:
        gateway.bypass()
        health = engine_health()
        if health.get("active_connections") == 0:
            # The owner has already bypassed and drained while holding the mutation lock.
            subprocess.run(["ubus", "call", "service", "delete", '{"name":"opl-netfleet-compat"}'],
                           capture_output=True, timeout=2)
        save_state({**previous, "intercepting": False, "reason": "disabled"}, previous)
        return
    if previous.get("maintenance"):
        gateway.bypass()
        save_state({**previous, "intercepting": False, "reason": "maintenance"}, previous)
        return
    try:
        network = snapshot()
        profile = read(Path("/etc/opl-netfleet/native/run/config.yaml"), {})
        reason = admission(profile, network)
    except (OSError, ValueError, subprocess.SubprocessError):
        network, reason = {}, "native_gateway_unavailable"
    health = engine_health(probe=True)
    expected = hashlib.sha256(EFFECTIVE.read_bytes()).hexdigest() if EFFECTIVE.exists() else None
    healthy = not reason and health.get("ready") and health.get("processing_chain") is True and health.get("revision") == expected
    if not reason:
        reason = ("engine_unavailable" if not health.get("ready") else
                  "processing_chain_failed" if health.get("processing_chain") is not True else
                  "engine_config_pending" if health.get("revision") != expected else None)
    recovery = advance(previous.get("recovery"), requested=True, healthy=bool(healthy), reason=reason, now=now)
    last_pid = previous.get("engine_pid")
    if health.get("pid") and last_pid and health["pid"] != last_pid:
        if previous.get("recovery", {}).get("healthy") is True:
            recovery["faults"] = [stamp for stamp in recovery.get("faults", []) if now - 600 <= stamp <= now] + [now]
        recovery["latched"] = recovery.get("latched", False) or len(recovery["faults"]) >= 3
        recovery["intercepting"] = False
        recovery["healthy_since"] = now if healthy else None
        recovery["reason"] = "manual_recovery_required" if recovery["latched"] else "engine_restarted"
    state = {**previous, "recovery": recovery, "reason": recovery["reason"], "intercepting": False}
    state["engine_pid"] = health.get("pid", last_pid)
    if not recovery["intercepting"]:
        gateway.bypass()
        if not health.get("ready") or health.get("processing_chain") is not True:
            since = previous.get("unhealthy_since", now)
            state["unhealthy_since"] = since
            if now - since >= 10 and not recovery["latched"]:
                # Failed start attempts count even when no ready engine was ever observed.
                recovery["faults"] = [stamp for stamp in recovery.get("faults", []) if now - 600 <= stamp <= now] + [now]
                recovery["latched"] = len(recovery["faults"]) >= 3
                if recovery["latched"]:
                    state["reason"] = recovery["reason"] = "manual_recovery_required"
                state["unhealthy_since"] = now
                save_state(state, previous)
                subprocess.run(["ubus", "call", "service", "signal", json.dumps({"name": "opl-netfleet-compat", "instance": "engine", "signal": 9})],
                               capture_output=True, timeout=1)
                subprocess.run([SERVICE, "start"], capture_output=True, timeout=2)
        else:
            state.pop("unhealthy_since", None)
        save_state(state, previous)
        return
    active = effective(config, read(TRUST, {}), ca_fingerprint())
    rule_states = dict(previous.get("rule_recovery", {}))
    observed = {**previous.get("observed", {}), **health.get("observed", {})}
    state["observed"] = observed
    pending = [{**rule, **observed.get(rule["id"], {})} for rule in active["rules"] if rule["enabled"] and rule["strategy"] == "h2"
               and (rule["match"] == "exact" or rule["id"] in observed)
               and rule_states.get(rule["id"], {}).get("intercepting") is not True
               and now - rule_states.get(rule["id"], {}).get("last_probe", -100) >= 10]
    probes = asyncio.run(probe_rules(pending)) if pending else {}
    for rule in active["rules"]:
        if not rule["enabled"] or rule["strategy"] != "h2":
            continue
        old = rule_states.get(rule["id"], {})
        errors = [event for event in health.get("failure_events", []) if event["rule"] == rule["id"]
                  and event["id"] > old.get("last_error", 0)]
        new_error = bool(errors)
        probe_ok = probes.get(rule["id"], old.get("probe_ok", rule["match"] == "suffix"))
        current = advance(old, requested=True, healthy=probe_ok and not new_error, reason="upstream_protocol_failed", now=now)
        current.update({"probe_ok": probe_ok, "last_probe": now if rule["id"] in probes else old.get("last_probe", -100),
                        "last_error": max(event["id"] for event in errors) if new_error else old.get("last_error", 0)})
        if new_error:
            current["faults"] = [stamp for stamp in old.get("faults", []) if now - 600 <= stamp <= now] + [event["at"] for event in errors if now - 600 <= event["at"] <= now]
            current["latched"] = old.get("latched", False) or len(current["faults"]) >= 3
            if current["latched"]:
                current["reason"] = "manual_recovery_required"
            current["probe_ok"] = False
            current["last_probe"] = -100
        rule_states[rule["id"]] = current
        if not current["intercepting"]:
            rule["strategy"] = "bypass"
    state["rule_recovery"] = rule_states
    if read(EFFECTIVE) != active:
        gateway.bypass()
        atomic(EFFECTIVE, active)
        state["reason"] = "rules_recovering"
        save_state(state, previous)
        return
    pairs = {(device, rule["port"]) for rule in active["rules"] if rule["enabled"] and rule["strategy"] == "h2" for device in rule["devices"]}
    candidates = []
    for device in active["devices"]:
        for identity, port in pairs:
            if identity != device["id"]:
                continue
            for address in device["addresses"]:
                family = 6 if ":" in address else 4
                if network.get(f"ipv{family}_proxy"):
                    candidates.append((address, "::/0" if family == 6 else "0.0.0.0/0", port))
    if candidates:
        gateway.prepare(network["interfaces"], network.get("dscp_bypass", []))
        gateway.renew(candidates)
    else:
        gateway.bypass()
        state["reason"] = "no_verified_targets"
    state["intercepting"] = bool(candidates)
    save_state(state, previous)


def apply(action, request):
    if request.get("revision") != revision():
        raise ValueError("compatibility_revision_conflict")
    config = validate(read(CONFIG, DEFAULT))
    original_enabled = config["enabled"]
    if action == "apply":
        config = validate(request.get("config"))
    elif action in ("enable", "disable"):
        config["enabled"] = action == "enable"
    gateway.bypass()
    if config["enabled"] or config["devices"]:
        prepare_ca()
    atomic(CONFIG, config)
    atomic(EFFECTIVE, effective(config, read(TRUST, {}), ca_fingerprint()))
    previous = read(STATE, {})
    kept = previous if original_enabled and config["enabled"] and action == "apply" else {}
    save_state({**kept, "intercepting": False, "reason": "recovering" if config["enabled"] else "disabled"}, previous)
    if config["enabled"]:
        subprocess.run([SERVICE, "enable"], check=True, capture_output=True, timeout=2)
        subprocess.run([SERVICE, "start"], check=True, capture_output=True, timeout=3)
    tick()
    return status()


def trust_action(request):
    if request.get("revision") != revision():
        raise ValueError("compatibility_revision_conflict")
    config = validate(read(CONFIG, DEFAULT))
    device = next((item for item in config["devices"] if item["id"] == request.get("device")), None)
    if device is None:
        raise ValueError("unknown_device")
    trust = read(TRUST, {})
    gateway.bypass()
    if request["operation"] == "trust_revoke":
        trust.pop(device["id"], None)
    else:
        report = request.get("report", {})
        if report.get("ca_sha256") != ca_fingerprint() or report.get("system") is not True:
            raise ValueError("device_trust_not_verified")
        # Only the authenticated enrollment tool records verification; UI has no ready toggle.
        trust[device["id"]] = {"verified": True, "ca_sha256": ca_fingerprint(), "addresses": device["addresses"],
                                "verified_at": int(time.time()), "runtimes": {"system": True,
                                **{name: report.get(name) if type(report.get(name)) is bool else None
                                   for name in ("codex_app", "codex_cli", "images")}}}
    atomic(TRUST, trust)
    atomic(EFFECTIVE, effective(config, trust, ca_fingerprint()))
    tick()
    return status()


def drain(timeout=30):
    gateway.bypass()
    deadline = time.monotonic() + timeout
    while True:
        health = engine_health()
        if health.get("active_connections") == 0 or not health.get("ready"):
            return {"drained": True}
        if time.monotonic() >= deadline:
            raise ValueError("healthy_connections_still_draining")
        time.sleep(0.2)


def main():
    os.umask(0o077)
    action = sys.argv[1]
    if action == "run":
        os.execv("/usr/libexec/opl-netfleet-compat/mitmdump", ["mitmdump", "--mode", "transparent@18443",
            "--mode", "regular@127.0.0.1:18444", "-s", "/usr/libexec/opl-netfleet-compat/addon.py",
            "--set", f"confdir={CA}", "--set", "upstream_cert=false", "--set", "connection_strategy=lazy",
            "--set", "netfleet_preserve_source_port=true", "--set", "netfleet_local_probe=true",
            "--set", f"ssl_verify_upstream_trusted_ca={CA / 'upstream-trust.pem'}",
            "--set", f"netfleet_config={EFFECTIVE}", "--set", "flow_detail=0", "--set", "termlog_verbosity=error"])
    if action == "get":
        return status()
    if action == "ca":
        return {"pem": (CA / "mitmproxy-ca-cert.pem").read_text(), "sha256": ca_fingerprint()}
    with Path("/var/lock/opl-netfleet-deploy.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("mutation_busy")
        RUN.mkdir(parents=True, exist_ok=True, mode=0o700)
        if action == "tick":
            tick()
            return {"reconciled": True}
        if action == "prepare":
            prepare_ca()
            atomic(EFFECTIVE, effective(validate(read(CONFIG, DEFAULT)), read(TRUST, {}), ca_fingerprint()))
            return {"prepared": True}
        if action == "private-backup":
            destination = Path(sys.argv[2])
            if not destination.is_absolute() or destination.parent.stat().st_mode & 0o077:
                raise ValueError("private_backup_directory_required")
            if not (CA / "mitmproxy-ca.pem").is_file():
                raise ValueError("ca_not_prepared")
            with destination.open("xb") as output:
                os.chmod(destination, 0o600)
                with tarfile.open(fileobj=output, mode="w:gz") as archive:
                    for path in (CONFIG, TRUST, CA):
                        if path.exists():
                            archive.add(path, arcname=str(path.relative_to(BASE)))
                output.flush()
                os.fsync(output.fileno())
            return {"private_backup_created": True, "ca_sha256": ca_fingerprint()}
        if action == "bypass":
            gateway.bypass()
            return {"intercepting": False}
        if action in ("drain", "remove"):
            previous = read(STATE, {})
            save_state({**previous, "maintenance": True, "intercepting": False, "reason": "maintenance"}, previous)
            result = drain()
            if action == "remove":
                gateway.remove()
            return result
        request = read(Path(sys.argv[2]), {}).get("request", {})
        if action in ("apply", "enable", "disable"):
            return apply(action, request)
        if action == "probe":
            if request.get("revision") != revision():
                raise ValueError("compatibility_revision_conflict")
            if request.get("operation") in ("trust_record", "trust_revoke"):
                return trust_action(request)
            if request.get("operation") == "recover":
                state = read(STATE, {})
                if request.get("rule"):
                    identity = request["rule"]
                    old = state.setdefault("rule_recovery", {}).get(identity, {})
                    last_error = max([old.get("last_error", 0), *[event["id"] for event in engine_health().get("failure_events", []) if event["rule"] == identity]])
                    state["rule_recovery"][identity] = {"last_error": last_error}
                else:
                    state.pop("recovery", None)
                    state.pop("unhealthy_since", None)
                    state.pop("maintenance", None)
                atomic(STATE, state)
                tick()
            return {"processing_chain": engine_health(probe=True).get("processing_chain") is True, **status()}
        raise ValueError("unknown_compatibility_action")


if __name__ == "__main__":
    try:
        print(json.dumps({"ok": True, "result": main()}))
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as error:
        code = str(error) if isinstance(error, ValueError) and str(error).replace("_", "").isalnum() else "compatibility_operation_failed"
        print(json.dumps({"ok": False, "error": code}))
        sys.exit(1)
