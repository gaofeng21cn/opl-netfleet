"""HAProxy configuration and bounded, private control; no business payload handling."""
import csv
import hashlib
import http.client
import io
import json
import ipaddress
import os
from pathlib import Path
import re
import secrets
import socket
import ssl
import struct
import subprocess
import tempfile
import time

from policy import validate

BINARY = '/usr/libexec/opl-netfleet-compat/haproxy'


def openssl(*arguments):
    return subprocess.run(['openssl', *map(str, arguments)], check=True,
                          capture_output=True, timeout=15).stdout


def write_private(path, data):
    temporary = path.with_suffix('.new')
    with temporary.open('wb') as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def prepare_ca(directory, system_ca=Path('/etc/ssl/certs/ca-certificates.crt')):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Keep the existing private authority and enrollment fingerprint across engine replacement.
    private, public = directory / 'mitmproxy-ca.pem', directory / 'mitmproxy-ca-cert.pem'
    if private.exists() != public.exists():
        raise ValueError('ca_private_key_missing')
    if not private.exists():
        with tempfile.TemporaryDirectory(dir=directory) as temporary:
            root = Path(temporary)
            openssl('req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-sha256', '-days', '3650',
                    '-subj', '/CN=NetFleet Compatibility CA', '-addext', 'basicConstraints=critical,CA:TRUE',
                    '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
                    '-keyout', root / 'key', '-out', root / 'cert')
            write_private(private, (root / 'cert').read_bytes() + (root / 'key').read_bytes())
            write_private(public, (root / 'cert').read_bytes())
    if openssl('x509', '-in', private, '-outform', 'DER') != openssl('x509', '-in', public, '-outform', 'DER'):
        raise ValueError('ca_certificate_mismatch')
    cert = openssl('x509', '-in', public, '-pubkey', '-noout')
    if cert != openssl('pkey', '-in', private, '-pubout'):
        raise ValueError('ca_key_mismatch')
    openssl('x509', '-in', public, '-checkend', '86400', '-noout')
    leaf = directory / 'probe-cert.pem'
    if not leaf.exists() or subprocess.run(['openssl', 'x509', '-in', str(leaf), '-checkend', '604800', '-noout'],
                                         capture_output=True, timeout=2).returncode:
        with tempfile.TemporaryDirectory(dir=directory) as temporary:
            root = Path(temporary)
            (root / 'extensions').write_text('subjectAltName=DNS:localhost\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n')
            openssl('req', '-new', '-newkey', 'rsa:2048', '-noenc', '-subj', '/CN=localhost',
                    '-keyout', root / 'key', '-out', root / 'csr')
            openssl('x509', '-req', '-in', root / 'csr', '-CA', public, '-CAkey', private,
                    '-set_serial', '0x' + secrets.token_hex(16), '-days', '90', '-sha256',
                    '-extfile', root / 'extensions', '-out', root / 'cert')
            write_private(leaf, (root / 'cert').read_bytes())
            write_private(directory / 'probe-key.pem', (root / 'key').read_bytes())
    write_private(directory / 'server.pem', leaf.read_bytes() + (directory / 'probe-key.pem').read_bytes())
    # The generated root is used only for the loopback health origin, never for public upstreams.
    write_private(directory / 'upstream-trust.pem', system_ca.read_bytes())


def configuration(effective, run, revision, *, port=18443, probe_port=18445):
    config = validate({**effective, 'rules': [rule for rule in effective['rules'] if rule['devices']]})
    if len(config['rules']) > 256 or len(config['devices']) > 256:
        raise ValueError('engine_configuration_limit')
    if not all(character in '0123456789abcdef' for character in revision) or len(revision) != 64:
        raise ValueError('engine_revision_invalid')
    # These are owner-generated paths, never interpolated user configuration.
    if any(character.isspace() or character in '#\\\"\'' for character in str(run)):
        raise ValueError('engine_directory_invalid')
    ca, sockets = run / 'ca', run / 'engine'
    source = {4: '', 6: ''}
    ports = effective.get('egress', {}).get('port_range') if effective.get('egress') else None
    if ports is not None:
        if not isinstance(ports, list) or len(ports) != 2 or not all(type(x) is int for x in ports) or not 1024 <= ports[0] <= ports[1] <= 65535:
            raise ValueError('egress_port_range_invalid')
        for family, address in ((4, '0.0.0.0'), (6, '::')):
            source[family] = f' source {address}:{ports[0]}-{ports[1]}' if family == 4 else f' source [{address}]:{ports[0]}-{ports[1]}'
    lines = [f'''global
  nbthread 1
  maxconn 96
  description {revision}
  tune.ssl.cachesize 128
  tune.ssl.ssl-ctx-cache-size 128
  tune.ssl.default-dh-param 2048
  stats socket {sockets}/engine.sock mode 600 level admin
defaults
  mode tcp
  timeout connect 10s
  timeout client 300s
  timeout server 300s
  timeout tunnel 1h
  timeout http-request 60s
  timeout http-keep-alive 30s
  retries 0
frontend ingress
  bind 0.0.0.0:{port}
  bind :::{port} v6only
  bind {sockets}/probe.sock accept-proxy mode 600
  tcp-request inspect-delay 2s
  tcp-request content accept if {{ req.ssl_hello_type 1 }}
  use_backend loopback_convert if {{ src 127.0.0.1 ::1 }} {{ dst 127.0.0.1 ::1 }} {{ dst_port {probe_port} }} {{ req.ssl_sni -i localhost }} !{{ req.ssl_alpn -m str h2 }}''']
    rules = sorted((rule for rule in config['rules'] if rule['enabled']),
                   key=lambda rule: (rule['match'] == 'exact', len(rule['domain'])), reverse=True)
    indexed = [(number, rule) for number, rule in enumerate(rules)]
    for number, rule in indexed:
        addresses = [address for device in config['devices'] if device['id'] in rule['devices'] for address in device['addresses']]
        if not addresses:
            continue
        name = f'r{number}'
        lines += [f"  acl {name}_source src {' '.join(addresses)}", f"  acl {name}_domain req.ssl_sni -i {rule['domain']}"]
        if rule['match'] == 'suffix':
            lines += [f"  acl {name}_domain req.ssl_sni -m end -i .{rule['domain']}"]
        condition = f"{name}_source {name}_domain {{ dst_port {rule['port']} }} !{{ req.ssl_alpn -m str h2 }}"
        if config['enabled'] and rule['strategy'] == 'h2':
            lines += [f'  use_backend {name}_convert if {condition} {{ str({name}),map_str_int({run}/rules.map,0) eq 1 }}']
        # A blocked exact rule must still win over a broader suffix rule.
        lines += [f'  use_backend passthrough if {condition}']
    lines += ['  default_backend passthrough', '''backend passthrough
  use-server v4 if { dst -m ip 0.0.0.0/0 }
  use-server v6 if { dst -m ip ::/0 }''',
              f'  server v4 0.0.0.0:0{source[4]}', f'  server v6 [::]:0{source[6]}',
              f'''backend loopback_convert
  server local {sockets}/health.sock send-proxy-v2
frontend health_convert
  mode http
  option http-no-delay
  bind {sockets}/health.sock accept-proxy mode 600 ssl crt {ca}/server.pem alpn http/1.1
  default_backend health_origin
backend health_origin
  mode http
  option abortonclose
  option http-no-delay
  server local 127.0.0.1:{probe_port} ssl alpn h2 proto h2 verify required ca-file {ca}/mitmproxy-ca-cert.pem sni str(localhost)
frontend health_endpoint
  mode http
  bind 127.0.0.1:{probe_port} ssl crt {ca}/server.pem alpn h2
  bind [::1]:{probe_port} v6only ssl crt {ca}/server.pem alpn h2
  http-request return status 200 hdr X-Upstream-Protocol %[ssl_fc_alpn] content-type text/plain lf-string %[path]''']
    for number, rule in indexed:
        if rule['strategy'] != 'h2':
            continue
        name = f'r{number}'
        observation = f'  tcp-request content set-var(proc.{name}_sni) req.ssl_sni,lower\n' if rule['match'] == 'suffix' else ''
        lines += [f'''backend {name}_convert
{observation}  server local {sockets}/{name}.sock send-proxy-v2
frontend {name}_http
  mode http
  option http-no-delay
  bind {sockets}/{name}.sock accept-proxy mode 600 ssl crt {ca}/server.pem ca-sign-file {ca}/mitmproxy-ca.pem generate-certificates alpn http/1.1
  use_backend {name}_websocket if {{ hdr(Upgrade) -i websocket }}
  default_backend {name}_h2''']
        for suffix, protocol in (('h2', 'h2'), ('websocket', 'http/1.1')):
            lines += [f'''backend {name}_{suffix}
  mode http
  option abortonclose
  option http-no-delay
  http-reuse safe
  use-server v4 if {{ dst -m ip 0.0.0.0/0 }}
  use-server v6 if {{ dst -m ip ::/0 }}''']
            for family, address in ((4, '0.0.0.0'), (6, '[::]')):
                lines += [f'  server v{family} {address}:0 ssl alpn {protocol} proto {"h2" if protocol == "h2" else "h1"} verify required ca-file {ca}/upstream-trust.pem sni ssl_fc_sni{source[family]}']
    return '\n'.join(lines) + '\n', {f'r{number}': rule['id'] for number, rule in indexed}


def configuration_revision(effective):
    structural = {key: value for key, value in effective.items() if key != 'blocked_rules'}
    return hashlib.sha256(json.dumps(structural, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def rule_switches(effective, mapping):
    blocked = set(effective.get('blocked_rules', []))
    return {name: '0' if identity in blocked else '1' for name, identity in mapping.items()}


def write_rule_map(run, effective, mapping):
    write_private(run / 'rules.map', ''.join(f'{name} {value}\n' for name, value in rule_switches(effective, mapping).items()).encode())


def prepare(effective_path, run):
    effective = json.loads(effective_path.read_bytes())
    config, rules = configuration(effective, run, configuration_revision(effective))
    write_rule_map(run, effective, rules)
    path = run / 'haproxy.cfg'
    temporary = path.with_suffix('.new')
    write_private(temporary, config.encode())
    subprocess.run([BINARY, '-c', '-f', str(temporary)], check=True, capture_output=True, timeout=5)
    temporary.replace(path)
    write_private(run / 'haproxy-rules.json', json.dumps(rules).encode())
    return path


_synchronized_rules = None


def sync_rule_switches(run, effective, health):
    global _synchronized_rules
    mapping = json.loads((run / 'haproxy-rules.json').read_bytes())
    expected = rule_switches(effective, mapping)
    identity = (str(run), health['pid'], health['revision'], tuple(sorted(expected.items())))
    if identity == _synchronized_rules:
        return
    _synchronized_rules = None
    def read_switches():
        return {parts[1]: parts[2] for line in command(run, f'show map {run}/rules.map').splitlines()
                if len(parts := line.split()) == 3 and parts[0].startswith('0x')}
    current = read_switches()
    if current.keys() != expected.keys():
        raise ValueError('engine_rule_map_mismatch')
    updates = [f'set map {run}/rules.map {name} {value}' for name, value in expected.items() if current[name] != value]
    if updates and command(run, ';'.join(updates)).strip():
        raise ValueError('engine_rule_map_update_failed')
    if read_switches() != expected:
        raise ValueError('engine_rule_map_mismatch')
    _synchronized_rules = identity


def command(run, request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(0.4)
        connection.connect(str(run / 'engine/engine.sock'))
        connection.sendall(request.encode() + b'\n')
        data = bytearray()
        while True:
            part = connection.recv(65536)
            if not part:
                break
            data.extend(part)
            if len(data) > 262144:
                raise ValueError('health_response_invalid')
        return data.decode()


def probe(run, family=None, socket_uid=None):
    """Exercise H1 TLS ingress -> internal TLS frontend -> actual H2 TLS origin."""
    context = ssl.create_default_context(cafile=str(run / 'ca/mitmproxy-ca-cert.pem'))
    context.set_alpn_protocols(['http/1.1'])
    nonce = '/' + secrets.token_hex(16)
    started = time.monotonic()
    if family is None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(1.4)
        sock.connect(str(run / 'engine/probe.sock'))
        sock.sendall(b'PROXY TCP4 127.0.0.1 127.0.0.1 12345 18445\r\n')
    else:
        if socket_uid is not None:
            os.seteuid(socket_uid)
        try:
            # Only the loopback socket's creation identity changes. Restore root before I/O.
            sock = socket.socket(socket.AF_INET if family == 4 else socket.AF_INET6, socket.SOCK_STREAM)
        finally:
            if socket_uid is not None:
                os.seteuid(0)
        sock.settimeout(1.4)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_PRIORITY, 6)
        sock.connect(('127.0.0.1' if family == 4 else '::1', 18445))
    with sock, context.wrap_socket(sock, server_hostname='localhost') as connection:
        if connection.selected_alpn_protocol() != 'http/1.1':
            raise ValueError('probe_downstream_protocol_failed')
        connection.sendall(f'GET {nonce} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'.encode())
        response = http.client.HTTPResponse(connection)
        response.begin()
        if response.status != 200 or response.getheader('X-Upstream-Protocol') != 'h2' or response.read(128) != nonce.encode():
            raise ValueError('probe_conversion_failed')
    return {'ok': True, 'stage': 'http', 'reason': None, 'duration_ms': round((time.monotonic() - started) * 1000, 2), 'timeout_ms': 1400}


def health(run):
    info = dict(line.split(': ', 1) for line in command(run, 'show info').splitlines() if ': ' in line)
    rows = list(csv.DictReader(io.StringIO(command(run, 'show stat').removeprefix('# '))))
    ingress = next(row for row in rows if row['pxname'] == 'ingress' and row['svname'] == 'FRONTEND')
    probes = next(row for row in rows if row['pxname'] == 'loopback_convert' and row['svname'] == 'BACKEND')
    connections = max(0, int(ingress['scur']) - int(probes['scur']))
    mapping = json.loads((run / 'haproxy-rules.json').read_bytes())
    rules, events, observed = {}, [], {}
    if mapping:
        values = command(run, ';'.join(f'get var proc.{name}_sni' for name in mapping))
        for line in values.splitlines():
            match = re.fullmatch(r'proc\.(r[0-9]+)_sni: type=str value=<([a-z0-9.-]{1,253})>', line)
            if match and match[1] in mapping:
                observed[mapping[match[1]]] = {'domain': match[2]}
    for row in rows:
        name = row['pxname'].removesuffix('_h2')
        if row['svname'] != 'BACKEND' or name not in mapping or not row['pxname'].endswith('_h2'):
            continue
        identity = mapping[name]
        rules[identity] = {'requests': int(row.get('req_tot') or 0), 'active_requests': int(row['scur']),
                           'upstream_protocol': 'h2' if sum(int(row.get('hrsp_' + group) or 0) for group in ('2xx', '3xx', '4xx')) > 0 else None}
        errors = int(row.get('econ') or 0) + int(row.get('eresp') or 0)
        if errors:
            events.append({'id': errors, 'rule': identity, 'reason': 'upstream_transport_failed'})
    return {'service': 'netfleet-https-compat', 'ready': True, 'pid': int(info['Pid']),
            'revision': info['description'], 'active_connections': connections,
            'active_requests': sum(rule['active_requests'] for rule in rules.values()),
            'unassigned_connections': connections, 'rules': rules, 'failure_events': events, 'observed': observed,
            'engine': 'haproxy', 'engine_version': info['Version']}


async def probe_upstreams(request):
    import asyncio
    context = ssl.create_default_context()
    context.set_alpn_protocols(['h2'])
    ports = (request.get('egress') or {}).get('port_range')
    async def check(rule):
        writer = None
        sock = None
        started = time.monotonic()
        try:
            async with asyncio.timeout(1.4):
                loop = asyncio.get_running_loop()
                records = await loop.getaddrinfo(rule['domain'], rule['port'], type=socket.SOCK_STREAM)
                if not records:
                    raise OSError('no_address')
                # Try both address families within the same bounded probe. One unavailable
                # AAAA answer must not permanently hide an otherwise reachable target.
                last_error = OSError('no_address')
                for family, kind, protocol, _, address in records[:4]:
                    sock = socket.socket(family, kind, protocol)
                    sock.setblocking(False)
                    if ports:
                        sock.setsockopt(socket.IPPROTO_IP, 51, struct.pack('I', (ports[1] << 16) | ports[0]))
                    try:
                        await asyncio.wait_for(loop.sock_connect(sock, address), timeout=0.4)
                        break
                    except (OSError, asyncio.TimeoutError) as error:
                        last_error = error
                        sock.close()
                        sock = None
                if sock is None:
                    raise last_error
                reader, writer = await asyncio.open_connection(sock=sock, ssl=context, server_hostname=rule['domain'])
                sock = None
                ok = writer.get_extra_info('ssl_object').selected_alpn_protocol() == 'h2'
                return rule['id'], {'ok': ok, 'at': int(time.time()),
                                    'reason': None if ok else 'upstream_h2_not_negotiated', 'duration_ms': round((time.monotonic() - started) * 1000, 2)}
        except (OSError, ValueError, asyncio.TimeoutError) as error:
            reason = ('upstream_certificate_failed' if isinstance(error, ssl.SSLCertVerificationError) else
                      'upstream_tls_failed' if isinstance(error, ssl.SSLError) else
                      'upstream_probe_timeout' if isinstance(error, TimeoutError) else
                      'upstream_dns_failed' if isinstance(error, socket.gaierror) else
                      'upstream_connection_refused' if isinstance(error, ConnectionRefusedError) else
                      'upstream_connect_failed')
            return rule['id'], {'ok': False, 'at': int(time.time()), 'reason': reason, 'duration_ms': round((time.monotonic() - started) * 1000, 2)}
        finally:
            if writer:
                writer.close()
            if sock:
                sock.close()
    return dict(await asyncio.gather(*(check(rule) for rule in request['rules'])))


if __name__ == '__main__':
    import json
    import sys
    import isolation
    if len(sys.argv) not in (3, 4) or sys.argv[1] not in ('probe', 'upstreams'):
        raise SystemExit(2)
    request = json.loads(Path(sys.argv[2]).read_bytes()) if sys.argv[1] == 'upstreams' else None
    # A bounded probe joins the already running engine's resource group before dropping privileges.
    if request is not None:
        (isolation.CGROUP / 'cgroup.procs').write_text(str(os.getpid()))
    uid, gid = isolation.account()
    os.setgroups([])
    os.setgid(gid)
    os.setuid(uid)
    if request is None:
        print(json.dumps(probe(Path(sys.argv[2]), int(sys.argv[3]))))
    else:
        import asyncio
        print(json.dumps(asyncio.run(probe_upstreams(request))))
