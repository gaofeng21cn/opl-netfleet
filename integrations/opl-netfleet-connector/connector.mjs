import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';

const execute = promisify(execFile);
export const BUNDLE_ID = 'com.onepersonlab.netfleet';
const OPEN_ACTION = 'opl.netfleet.connector.v1#open';
const MAX_STATUS_AGE_MS = 15000;
const MAX_CLOCK_SKEW_MS = 5000;

export function ownerSocketPath(stateDirectory = process.env.NETFLEET_STATE_DIR
  || path.join(os.homedir(), 'Library/Application Support/OPL NetFleet')) {
  const digest = crypto.createHash('sha256').update(path.resolve(stateDirectory)).digest('hex').slice(0, 12);
  return path.join(os.tmpdir(), `opl-netfleet-${process.getuid()}-${digest}`, 'owner.sock');
}

export async function appInstalled({ platform = process.platform, run = execute } = {}) {
  if (platform !== 'darwin') return false;
  try {
    const result = await run('/usr/bin/osascript', ['-e', `POSIX path of (path to application id "${BUNDLE_ID}")`],
      { timeout: 3000, maxBuffer: 4096 });
    return result.stdout.trim().endsWith('.app/');
  } catch { return false; }
}

export async function readOwner(socketPath, { now = () => Date.now() } = {}) {
  const [directory, socket] = await Promise.all([fs.lstat(path.dirname(socketPath)), fs.lstat(socketPath)]);
  if (!directory.isDirectory() || !socket.isSocket()
    || [directory, socket].some(info => info.uid !== process.getuid() || (info.mode & 0o077)))
    throw new Error('owner_unavailable');
  return new Promise((resolve, reject) => {
    const request = http.request({ socketPath, path: '/miniapp/status', method: 'GET', timeout: 2000 }, response => {
      let text = '';
      response.setEncoding('utf8');
      response.on('error', reject);
      response.on('data', chunk => {
        text += chunk;
        if (text.length > 16384) request.destroy(new Error('owner_unavailable'));
      });
      response.on('end', () => {
        try {
          const value = JSON.parse(text);
          if (response.statusCode !== 200 || value.schema !== 'opl-netfleet-miniapp-status.v1'
            || value.platform !== 'macos'
            || !['direct', 'mihomo', 'netfleet', 'unconfirmed'].includes(value.mode)
            || !['explicit', 'system', 'tun', 'unknown'].includes(value.network_mode)
            || typeof value.running !== 'boolean' || typeof value.configured !== 'boolean'
            || typeof value.recovery_required !== 'boolean' || !Number.isFinite(Date.parse(value.read_at)))
            throw new Error('owner_unavailable');
          const checkedAt = now(), age = checkedAt - Date.parse(value.read_at);
          if (age > MAX_STATUS_AGE_MS || age < -MAX_CLOCK_SKEW_MS) {
            const error = new Error(age < 0 ? 'owner_clock_invalid' : 'owner_snapshot_stale');
            error.observedAt = value.read_at;
            reject(error);
            return;
          }
          resolve({ mode: value.mode, network_mode: value.network_mode, running: value.running,
            configured: value.configured, recovery_required: value.recovery_required, read_at: value.read_at });
        } catch { reject(new Error('owner_unavailable')); }
      });
    });
    request.on('timeout', () => request.destroy(new Error('owner_unavailable')));
    request.on('error', reject);
    request.end();
  });
}

export async function contribute(operation, input = {}, options = {}) {
  if (!input || typeof input !== 'object' || Array.isArray(input) || Object.keys(input).length)
    return { state: 'unavailable', reason: 'empty_input_required' };
  if (!['status', 'open'].includes(operation)) return { state: 'unavailable', reason: 'unknown_operation' };
  if ((options.platform || process.platform) !== 'darwin') return { state: 'unavailable', reason: 'macos_required' };
  const installed = await appInstalled(options);
  if (operation === 'open') {
    if (!installed) return { state: 'unavailable', reason: 'app_not_installed' };
    try {
      await (options.run || execute)('/usr/bin/open', ['-b', BUNDLE_ID], { timeout: 5000, maxBuffer: 4096 });
      return { state: 'ready', result: { status: 'accepted', bundle_id: BUNDLE_ID } };
    } catch { return { state: 'unavailable', reason: 'open_failed' }; }
  }
  let ownerError;
  const status = await readOwner(options.socketPath || ownerSocketPath(), options).catch(error => {
    ownerError = error;
    return null;
  });
  const stale = ownerError?.message === 'owner_snapshot_stale';
  const reason = stale || ownerError?.message === 'owner_clock_invalid' ? ownerError.message : 'owner_unavailable';
  const freshness = { state: status ? 'fresh' : stale ? 'stale' : 'unavailable',
    observed_at: status?.read_at || ownerError?.observedAt || null,
    checked_at: new Date((options.now || Date.now)()).toISOString(), max_age_seconds: MAX_STATUS_AGE_MS / 1000,
    ...(status ? {} : { reason }) };
  const item = { id: 'local-netfleet', title: 'OPL NetFleet',
    status: status ? status.mode : reason,
    summary: status ? `运行模式：${status.mode} · 网络接入：${status.network_mode} · 读取：${status.read_at}`
      : stale ? `本机观测已过期（${freshness.observed_at}），请刷新或打开 NetFleet 查看。`
      : installed ? '本机状态暂不可读，可打开 NetFleet 查看。' : '未找到本机 NetFleet App。',
    installed, owner_available: Boolean(status), freshness, ...status,
    actions: installed ? [{ action_ref: OPEN_ACTION, input: {} }] : [],
  };
  return { state: 'ready', data: { items: [item] } };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    let input = '';
    for await (const chunk of process.stdin) { input += chunk; if (input.length > 8192) throw new Error('invalid_input'); }
    console.log(JSON.stringify(await contribute(process.argv[2], input.trim() ? JSON.parse(input) : {})));
  } catch { console.log(JSON.stringify({ state: 'unavailable', reason: 'invalid_input' })); }
}
