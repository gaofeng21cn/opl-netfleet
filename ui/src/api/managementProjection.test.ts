import { describe, expect, it } from 'vitest';
import type { MaintenanceSnapshot, NetworkSnapshot } from '../types';
import { projectMaintenance, projectNetwork } from './managementProjection';

describe('unauthenticated management preview projection', () => {
  it('keeps real network fields but never returns passwords or DNS URL credentials and paths', () => {
    const snapshot = {
      available: true, backend: 'native-mihomo', revision: 'real-revision', running: true,
      secret: 'controller-secret',
      settings: {
        dns: { nameservers: ['1.1.1.1', 'https://user:password@resolver.example:8443/private-token?key=abc#secret'], default_nameservers: ['9.9.9.9'], proxy_nameservers: [], direct_nameservers: [], policies: [{ domain: 'example.com', nameservers: ['tls://dns.example/token'] }], proxy_policies: [] },
        lan: { enabled: true, interfaces: ['br-lan'], rules: [] }, router: { enabled: true },
        listeners: { mixed_port: 7890, http_port: 0, socks_port: 0, authentication_enabled: true, credentials: [{ id: 'one', username: 'local-user', password_configured: true, password: 'actual-password' }] },
      },
      resources: { interfaces: [{ name: 'br-lan', up: true, device: 'br-lan' }], preserved_dns_policy_count: 2, preserved_proxy_policy_count: 1 },
    };
    const projected = projectNetwork(snapshot as NetworkSnapshot);
    expect(projected.revision).toBe('real-revision');
    expect(projected.settings?.dns.nameservers).toEqual(['1.1.1.1', 'https://resolver.example:8443/[已隐藏]']);
    expect(projected.settings?.dns.policies[0].nameservers).toEqual(['tls://dns.example/[已隐藏]']);
    expect(projected.preview_redacted).toBe(true);
    expect(projected.settings?.listeners.credentials).toEqual([{ id: 'one', username: 'local-user', password_configured: true }]);
    const serialized = JSON.stringify(projected);
    for (const secret of ['controller-secret', 'actual-password', 'private-token', 'user:password', 'key=abc']) expect(serialized).not.toContain(secret);
    expect(snapshot.settings.dns.nameservers[1]).toContain('private-token');
  });

  it('does not synthesize network settings when the active backend cannot manage them', () => {
    expect(projectNetwork({ available: false, reason: 'native_backend_required', revision: null, settings: null })).toMatchObject({ available: false, settings: null, revision: null });
  });

  it('preserves an unsupported maintenance result without expecting backup metadata', () => {
    expect(projectMaintenance({ supported: false, reason: 'native_management_unavailable', revision: null, profiles: [], core: { running: false, actions: [] } })).toMatchObject({ supported: false, reason: 'native_management_unavailable', profiles: [] });
  });

  it('returns only profile metadata, not backup or profile contents', () => {
    const snapshot = {
      supported: true, revision: 'revision',
      profiles: [{ id: 'custom.json', ref: 'file:custom.json', format: 'json', size_bytes: 10, modified_at: 100, referenced: true, editable: false, content: 'secret-profile' }],
      core: { running: true, controller_available: true, running_version: '1.19.30', actions: ['restart', 'reload'] },
      backup: { format: 'netfleet-backup-v1', contains_credentials: true, content: 'secret-backup' },
    };
    const projected = projectMaintenance(snapshot as MaintenanceSnapshot);
    expect(projected.profiles[0]).toMatchObject({ id: 'custom.json', referenced: true });
    expect(JSON.stringify(projected)).not.toContain('secret-profile');
    expect(JSON.stringify(projected)).not.toContain('secret-backup');
  });
});
