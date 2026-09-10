// The core's immediate parent survives an abrupt desktop-owner exit long enough
// to reap its exact child. The ownership pipe is never inherited by Mihomo.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { atomicJSON, processIdentity } from './io.mjs';
const [corePath, runtimeDir, configPath] = process.argv.slice(2);
const recordPath = path.join(runtimeDir, '../../core-process.json');
const child = spawn(corePath, ['-d', runtimeDir, '-f', configPath], { env: process.env, stdio: ['ignore', 3, 3] });
let ending = false;
function stop() {
  if (ending) return; ending = true;
  if (child.exitCode !== null || child.signalCode !== null) process.exit(0);
  child.kill('SIGTERM');
  setTimeout(() => child.kill('SIGKILL'), 3000).unref();
}
child.on('spawn', async () => {
  try { const identity = await processIdentity(child.pid); if (!identity) throw new Error('identity_missing');
    await atomicJSON(recordPath, { ...identity, corePath, runtimeDir, configPath });
    process.stdout.write(JSON.stringify({ pid: child.pid }) + '\n');
  } catch { stop(); }
});
child.on('error', () => process.exit(1));
child.on('exit', async code => { await fs.unlink(recordPath).catch(() => {}); process.exit(ending ? 0 : (code || 1)); });
process.stdin.resume(); process.stdin.on('end', stop); process.stdin.on('error', stop);
process.on('SIGTERM', stop); process.on('SIGINT', stop);
