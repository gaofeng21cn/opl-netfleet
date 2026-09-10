import fs from 'node:fs/promises';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { atomicJSON, readJSON, assert, object, run, delay, inside, processIdentity } from './io.mjs';

// Platform projection owns listeners and paths; imported policy still owns its rules.
export function projectProfile(profile, state, runtimeDir, networkMode = state.network.mode) {
  assert(object(profile), 'profile_object_required');
  const config = structuredClone(profile);
  for (const key of ['external-controller-unix', 'external-controller-pipe', 'external-controller-tls', 'external-ui',
    'external-ui-url', 'external-ui-name', 'external-controller-cors', 'tun', 'tproxy-port', 'redir-port',
    'port', 'socks-port', 'listeners', 'routing-mark', 'interface-name', 'authentication']) delete config[key];
  config['mixed-port'] = state.ports.mixed;
  config['bind-address'] = '127.0.0.1'; config['allow-lan'] = false;
  config['external-controller'] = `127.0.0.1:${state.ports.controller}`; config.secret = state.controllerSecret;
  config['log-level'] = 'warning'; config['find-process-mode'] = 'off';
  config.tun = { enable: networkMode === 'tun', stack: 'mixed', 'auto-route': true,
    'auto-detect-interface': true, 'dns-hijack': ['any:53'] };
  config.dns = { ...(object(config.dns) ? config.dns : {}), enable: true, listen: `127.0.0.1:${state.ports.dns}` };
  if (!config.dns.nameserver?.length) config.dns.nameserver = ['system'];
  if (!config.dns['enhanced-mode']) config.dns['enhanced-mode'] = 'redir-host';
  for (const field of ['proxy-providers', 'rule-providers']) {
    assert(config[field] === undefined || object(config[field]), 'invalid_providers');
    for (const [name, provider] of Object.entries(config[field] ?? {})) {
      assert(object(provider), 'invalid_provider');
      if (provider.type === 'file') {
        assert(typeof provider.path === 'string' && inside(path.dirname(runtimeDir), path.resolve(runtimeDir, provider.path)), 'provider_path_outside_private_backend');
        provider.path = path.resolve(runtimeDir, provider.path);
      } else {
        provider.path = path.join(runtimeDir, field, Buffer.from(name).toString('hex').slice(0, 160) + '.yaml');
      }
    }
  }
  return config;
}

export class CoreOwner {
  constructor({ stateDir, corePath, getState, network, env }) {
    Object.assign(this, { stateDir, corePath, getState, network, env }); this.child = null; this.corePid = null; this.tunPid = null;
    this.runtimeDir = path.join(stateDir, 'backend/run'); this.stopping = false; this.lastError = null;
  }
  async controller(endpoint = '/version') {
    const state = this.getState();
    try {
      const response = await fetch(`http://127.0.0.1:${state.ports.controller}${endpoint}`, {
        headers: { Authorization: `Bearer ${state.controllerSecret}` }, signal: AbortSignal.timeout(2000) });
      return response.ok ? await response.json() : null;
    } catch { return null; }
  }
  async reconcileStartup() {
    const recordPath = path.join(this.stateDir, 'core-process.json');
    const record = await readJSON(recordPath);
    if (!record) return;
    assert(record.corePath === this.corePath && record.runtimeDir === this.runtimeDir && record.configPath === path.join(this.runtimeDir, 'config.yaml'), 'core_recovery_identity_mismatch');
    const actual = await processIdentity(record.pid);
    if (actual && actual.start === record.start && actual.uid === record.uid && actual.command === record.command) {
      assert(actual.uid === process.getuid(), 'core_owner_mismatch');
      process.kill(record.pid, 'SIGTERM');
      for (let i = 0; i < 50; i++) { if (!(await processIdentity(record.pid))) break; await delay(100); }
      const after = await processIdentity(record.pid);
      assert(!after || after.start !== record.start, 'orphan_core_cleanup_unconfirmed');
    }
    await fs.unlink(recordPath).catch(error => { if (error.code !== 'ENOENT') throw error; });
  }
  async status() {
    const owned = this.child && this.child.exitCode === null && this.child.signalCode === null;
    const tunnel = this.tunPid !== null && (await this.network.status()).running === true;
    const version = owned || tunnel ? await this.controller() : null;
    return { running: Boolean((owned || tunnel) && version?.version), pid: owned ? this.corePid : this.tunPid,
      controllerReady: Boolean(version?.version), version: version?.version ?? null, clean: !owned && !tunnel,
      lastError: this.lastError };
  }
  resolveProfile(reference) {
    assert(typeof reference === 'string', 'profile_missing');
    const match = /^(file|subscription):([A-Za-z0-9_. -]+)$/.exec(reference);
    assert(match && !match[2].includes('..'), 'invalid_profile_reference');
    return path.join(this.stateDir, 'backend', match[1] === 'file' ? 'profiles' : 'subscriptions', match[2] + (match[1] === 'subscription' ? '.yaml' : ''));
  }
  async parseProfile(value) {
    if (object(value)) return value;
    assert(typeof value === 'string' && value.length <= 8 * 1024 * 1024, 'invalid_profile');
    try { const parsed = JSON.parse(value); assert(object(parsed), 'profile_object_required'); return parsed; } catch {}
    const parsed = await run('yq', ['-M', '-p', 'yaml', '-o', 'json'], { input: value, env: this.env });
    assert(parsed.code === 0, 'profile_yaml_invalid');
    const profile = JSON.parse(parsed.stdout); assert(object(profile), 'profile_object_required'); return profile;
  }
  async validate(profile, mode = 'explicit') {
    const projected = projectProfile(profile, this.getState(), this.runtimeDir, mode);
    const candidate = path.join(this.runtimeDir, `candidate-${process.pid}.json`);
    await atomicJSON(candidate, projected);
    try { const checked = await run(this.corePath, ['-d', this.runtimeDir, '-f', candidate, '-t'], { env: this.env, timeout: 45000 });
      assert(checked.code === 0, 'mihomo_configuration_rejected'); return projected;
    } finally { await fs.unlink(candidate).catch(() => {}); }
  }
  async start({ authorize = false } = {}) {
    const state = this.getState();
    const profile = await this.parseProfile(await fs.readFile(this.resolveProfile(state.profile), 'utf8'));
    const config = await this.validate(profile, state.network.mode);
    await this.stop();
    await atomicJSON(path.join(this.runtimeDir, 'config.yaml'), config);
    this.lastError = null;
    try {
      if (state.network.mode === 'tun') {
        const result = await this.network.attach('tun', { configPath: path.join(this.runtimeDir, 'config.yaml'), runtimeDir: this.runtimeDir, authorize });
        assert(result?.ok !== false, result?.status ?? result?.error ?? 'tun_start_failed'); this.tunPid = result.corePid;
      } else {
        const log = await fs.open(path.join(this.stateDir, 'core.log'), 'a', 0o600);
        this.child = spawn(process.execPath, [fileURLToPath(new URL('./core-worker.mjs', import.meta.url)), this.corePath, this.runtimeDir, path.join(this.runtimeDir, 'config.yaml')],
          { env: this.env, stdio: ['pipe', 'pipe', log.fd, log.fd] });
        await log.close();
        const own = this.child;
        own.on('error', () => { this.lastError = 'core_spawn_failed'; });
        own.on('exit', () => {
          if (this.child === own && !this.stopping) {
            this.lastError = 'core_exited';
            this.network.detach().then(() => this.reconcileStartup()).catch(() => { this.lastError = 'network_cleanup_failed'; });
          }
        });
        this.corePid = await new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('core_worker_timeout')), 5000);
          own.once('exit', () => { clearTimeout(timer); reject(new Error('core_worker_exited')); });
          own.stdout.once('data', data => { clearTimeout(timer); try { const value = JSON.parse(data); assert(Number.isInteger(value.pid), 'core_pid_invalid'); resolve(value.pid); } catch (error) { reject(error); } });
        });
      }
      let ready = false;
      for (let i = 0; i < 40; i++) {
        if (this.child && (this.child.exitCode !== null || this.child.signalCode !== null)) break;
        if ((await this.controller())?.version) { ready = true; break; } await delay(150);
      }
      assert(ready, 'core_not_ready');
      if (state.network.mode === 'system') {
        const result = await this.network.attach('system', { corePid: this.corePid, authorize });
        assert(result?.ok !== false, result?.status ?? result?.error ?? 'system_proxy_attach_failed');
      }
      return { ok: true, ...(await this.status()) };
    } catch (error) { this.lastError = error.message; await this.stop(); throw error; }
  }
  async stop() {
    this.stopping = true;
    try {
      const cleanup = await this.network.detach();
      assert(cleanup?.ok !== false, cleanup?.error ?? 'network_cleanup_failed');
      this.tunPid = null;
      const child = this.child;
      if (child && child.exitCode === null && child.signalCode === null) {
        child.kill('SIGTERM');
        for (let i = 0; i < 30 && child.exitCode === null && child.signalCode === null; i++) await delay(100);
        if (child.exitCode === null && child.signalCode === null) {
          child.kill('SIGKILL');
          for (let i = 0; i < 20 && child.exitCode === null && child.signalCode === null; i++) await delay(50);
        }
        assert(child.exitCode !== null || child.signalCode !== null, 'core_stop_unconfirmed');
      }
      this.child = null; this.corePid = null; return { ok: true, running: false, clean: true };
    } finally { this.stopping = false; }
  }
}
