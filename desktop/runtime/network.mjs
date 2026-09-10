import { access, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const exec = promisify(execFile);
const HELPER = '/Library/PrivilegedHelperTools/org.opl.netfleet.network';
const SOCKET = '/var/run/opl-netfleet-network/control.sock';
const JOURNAL = '/var/run/opl-netfleet-network/recovery-required';
const quote = value => `'${String(value).replaceAll("'", "'\\''")}'`;
const appleQuote = value => JSON.stringify(value);

async function exists(file) { try { await access(file, constants.F_OK); return true; } catch { return false; } }
async function command(message, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(SOCKET);
    let output = '';
    const timeout = setTimeout(() => socket.destroy(new Error('Network helper response timed out')), timeoutMs);
    socket.on('connect', () => socket.write(`${JSON.stringify(message)}\n`));
    socket.on('data', chunk => { output += chunk; if (output.includes('\n')) socket.end(); });
    socket.on('error', reject);
    socket.on('close', () => {
      clearTimeout(timeout);
      try { resolve(JSON.parse(output)); } catch { reject(new Error('Network helper is unavailable')); }
    });
  });
}

/** The server owns explicit cores; the privileged helper owns network mutations and TUN cores. */
export class NetworkOwner {
  constructor({ stateDir, corePath, ports, ownerPid = process.pid, helperPath, installScript } = {}) {
    this.stateDir = stateDir;
    this.corePath = corePath;
    this.ports = ports || {};
    this.ownerPid = ownerPid;
    this.helperPath = helperPath || path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../runtime/bin/netfleet-network-helper');
    this.installScript = installScript || path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../helper/install.sh');
  }
  async status() {
    if (process.platform !== 'darwin') return { mode: 'explicit', running: false, helper: 'unsupported-platform' };
    let installed = false;
    try { const info = await stat(HELPER); installed = info.isFile() && info.uid === 0 && !(info.mode & 0o022); } catch {}
    try {
      const result = await command({ action: 'status', ownerPid: this.ownerPid });
      const owned = result.ownerPid === this.ownerPid;
      return { ...result, helper: 'installed', owned, authorized: owned, ready: owned && result.running && result.phase === 'active', clean: !result.running && !result.recoveryRequired };
    } catch {
      return { mode: 'explicit', running: false, helper: installed ? 'installed' : 'needs-install', recoveryRequired: await exists(JOURNAL), ready: false, clean: !(await exists(JOURNAL)), authorized: false };
    }
  }
  async install({ authorize = false } = {}) {
    if (process.platform !== 'darwin') return { ok: false, status: 'unsupported-platform' };
    if (!authorize) return { ok: false, status: 'not-authorized' };
    if (!(await exists(this.helperPath)) || !(await exists(this.corePath))) return { ok: false, status: 'build-required' };
    // Both paths originate from packaged runtime discovery, never a web request.
    const shell = ['/bin/sh', this.installScript, this.helperPath, this.corePath].map(quote).join(' ');
    try { await exec('/usr/bin/osascript', ['-e', `do shell script ${appleQuote(shell)} with administrator privileges`], { timeout: 120000 }); }
    catch (error) { return { ok: false, status: 'not-authorized', error: error.stderr?.trim() || error.message }; }
    const state = await this.status();
    return { ok: state.helper === 'installed', status: state.helper };
  }
  async attach(mode, details = {}) {
    if (!['explicit', 'system', 'tun'].includes(mode)) throw new Error('Unknown network mode');
    const before = await this.status();
    if (mode === 'explicit') {
      if (before.owned || before.running || before.recoveryRequired) return this.detach({ close: true });
      return { ok: true, mode, running: false, ready: true };
    }
    if (before.running) {
      if (before.owned && before.mode === mode) return { ...before, ok: true };
      return { ok: false, status: 'owner-conflict', mode: before.mode };
    }
    if (before.helper !== 'installed') return { ok: false, status: before.helper };
    if (before.owned && before.mode === mode) {
      const result = await command({ action: 'attach', ownerPid: this.ownerPid, corePid: details.corePid, configPath: details.configPath }, 60000);
      return { ...result, ready: result.ok && result.phase === 'active' };
    }
    if (before.owned) return { ok: false, status: 'owner-conflict' };
    if (!details.authorize) return { ok: false, status: 'not-authorized' };
    const mixed = Number(this.ports.mixed ?? this.ports.mixedPort);
    if (!Number.isInteger(mixed) || mixed < 1024 || mixed > 65535) throw new Error('Invalid mixed proxy port');
    const args = [HELPER, 'attach', mode, String(this.ownerPid), String(mixed)];
    if (mode === 'system') {
      if (!Number.isInteger(details.corePid) || details.corePid <= 1) throw new Error('System proxy requires a running owned core');
      args.push(String(details.corePid), this.stateDir);
    } else {
      if (!path.isAbsolute(details.configPath || '')) throw new Error('TUN requires an absolute validated config path');
      args.push(details.configPath, this.stateDir);
    }
    const shell = `${args.map(quote).join(' ')} >/dev/null 2>&1 < /dev/null &`;
    try { await exec('/usr/bin/osascript', ['-e', `do shell script ${appleQuote(shell)} with administrator privileges`], { timeout: 120000 }); }
    catch (error) { return { ok: false, status: 'not-authorized', error: error.stderr?.trim() || error.message }; }
    for (let attempt = 0; attempt < 100; attempt++) {
      const current = await this.status();
      if (current.owned && current.running) return { ...current, ok: true, ready: current.phase === 'active' };
      if (current.owned && current.error) return { ...current, ok: false, status: 'attach-failed' };
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    return { ok: false, status: 'attach-failed', error: 'Privileged helper did not establish a network session' };
  }
  async detach({ close = false } = {}) {
    const current = await this.status();
    if (!current.owned && !current.running) return { ok: !current.recoveryRequired, mode: 'explicit', status: current.recoveryRequired ? 'recovery-required' : 'detached' };
    if (!current.owned) return { ok: false, status: 'owner-conflict' };
    const result = await command({ action: 'detach', ownerPid: this.ownerPid, close });
    return { ...result, mode: result.ok ? 'explicit' : current.mode };
  }
}
