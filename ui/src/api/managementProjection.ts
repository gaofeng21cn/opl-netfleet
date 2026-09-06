import type { DiagnosticsSnapshot, MaintenanceSnapshot, NetworkSnapshot } from '../types';

// The local bridge is unauthenticated. Only these management fields may leave SSH.
export function projectNetwork(snapshot: NetworkSnapshot): NetworkSnapshot {
  let redacted = false;
  const resolver = (value: string) => {
    if (!value.includes('://')) return value;
    redacted = true;
    try {
      const url = new URL(value);
      return `${url.protocol}//${url.host}/[已隐藏]`;
    } catch { return '[私有解析地址已隐藏]'; }
  };
  const settings = snapshot.settings;
  const projected = settings ? {
    dns: {
      nameservers: settings.dns.nameservers.map(resolver),
      default_nameservers: settings.dns.default_nameservers.map(resolver),
      proxy_nameservers: settings.dns.proxy_nameservers.map(resolver),
      direct_nameservers: settings.dns.direct_nameservers.map(resolver),
      policies: settings.dns.policies.map(item => ({ domain: item.domain, nameservers: item.nameservers.map(resolver) })),
      proxy_policies: settings.dns.proxy_policies.map(item => ({ domain: item.domain, nameservers: item.nameservers.map(resolver) })),
    },
    lan: {
      enabled: settings.lan.enabled,
      interfaces: settings.lan.interfaces,
      rules: settings.lan.rules.map(item => ({ id: item.id, enabled: item.enabled, ipv4: item.ipv4, ipv6: item.ipv6, mac: item.mac, proxy: item.proxy, dns: item.dns })),
    },
    router: { enabled: settings.router.enabled },
    listeners: {
      mixed_port: settings.listeners.mixed_port,
      http_port: settings.listeners.http_port,
      socks_port: settings.listeners.socks_port,
      authentication_enabled: settings.listeners.authentication_enabled,
      credentials: settings.listeners.credentials.map(item => ({ id: item.id, username: item.username, password_configured: item.password_configured })),
    },
  } : null;
  return {
    available: snapshot.available, reason: snapshot.reason, backend: snapshot.backend,
    revision: snapshot.revision, running: snapshot.running, settings: projected, preview_redacted: redacted,
    resources: snapshot.resources ? {
      interfaces: snapshot.resources.interfaces.map(item => ({ name: item.name, up: item.up, device: item.device })),
      preserved_dns_policy_count: snapshot.resources.preserved_dns_policy_count,
      preserved_proxy_policy_count: snapshot.resources.preserved_proxy_policy_count,
    } : undefined,
  };
}

export function projectMaintenance(snapshot: MaintenanceSnapshot): MaintenanceSnapshot {
  return {
    supported: snapshot.supported, reason: snapshot.reason, revision: snapshot.revision,
    profiles: snapshot.profiles.map(item => ({ id: item.id, ref: item.ref, format: item.format, size_bytes: item.size_bytes, modified_at: item.modified_at, referenced: item.referenced, editable: item.editable })),
    core: { running: snapshot.core.running, controller_available: snapshot.core.controller_available, running_version: snapshot.core.running_version, actions: snapshot.core.actions },
    backup: snapshot.backup ? { format: snapshot.backup.format, contains_credentials: snapshot.backup.contains_credentials } : undefined,
  };
}

export function projectDiagnostics(snapshot: DiagnosticsSnapshot): DiagnosticsSnapshot {
  return { supported: snapshot.supported, core_running: snapshot.core_running, controller_available: snapshot.controller_available, captured_at: snapshot.captured_at, lines: snapshot.lines, truncated: snapshot.truncated };
}
