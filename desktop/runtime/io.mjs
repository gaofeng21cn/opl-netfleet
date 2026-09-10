import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

export const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
export function assert(condition, message) { if (!condition) throw new Error(message); }
export async function privateDir(directory) {
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const info = await fs.lstat(directory);
  assert(info.isDirectory() && !info.isSymbolicLink() && info.uid === process.getuid(), 'unsafe_state_directory');
  await fs.chmod(directory, 0o700);
}
export async function readJSON(file, fallback = null) {
  try { return JSON.parse(await fs.readFile(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
}
export async function atomicJSON(file, value) {
  const temporary = `${file}.${crypto.randomBytes(8).toString('hex')}.tmp`;
  const handle = await fs.open(temporary, 'wx', 0o600);
  try {
    await handle.writeFile(JSON.stringify(value, null, 2)); await handle.sync(); await handle.close();
    await fs.rename(temporary, file);
  } catch (error) { await handle.close().catch(() => {}); await fs.unlink(temporary).catch(() => {}); throw error; }
}
export function run(file, args = [], { input, env = process.env, timeout = 30000, maxBytes = 8 * 1024 * 1024, cwd } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(file, args, { env, cwd, stdio: ['pipe', 'pipe', 'pipe'] });
    const stdout = [], stderr = []; let bytes = 0, failed;
    const timer = setTimeout(() => { failed = new Error('command_timeout'); child.kill('SIGKILL'); }, timeout);
    const collect = kind => data => {
      bytes += data.length;
      if (bytes > maxBytes) { failed = new Error('command_output_limit'); child.kill('SIGKILL'); return; }
      if (kind === 'out') stdout.push(data); else stderr.push(data);
    };
    child.stdout.on('data', collect('out')); child.stderr.on('data', collect('err'));
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('close', code => { clearTimeout(timer); failed ? reject(failed) : resolve({ code, stdout: Buffer.concat(stdout).toString('utf8'), stderr: Buffer.concat(stderr).toString('utf8') }); });
    child.stdin.on('error', () => {}); child.stdin.end(input);
  });
}
export async function requestBody(request, limit = 8 * 1024 * 1024) {
  const chunks = []; let size = 0;
  for await (const chunk of request) { size += chunk.length; assert(size <= limit, 'request_too_large'); chunks.push(chunk); }
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
}
export function inside(root, target) {
  const relative = path.relative(root, target); return relative !== '' && !relative.startsWith('..') && !path.isAbsolute(relative);
}
export const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
export async function processIdentity(pid) {
  if (!Number.isInteger(pid) || pid <= 1) return null;
  const result = await run('/bin/ps', ['-p', String(pid), '-o', 'uid=', '-o', 'lstart=', '-o', 'command='], { timeout: 3000 });
  const match = /^\s*(\d+)\s+(\w+\s+\w+\s+\d+\s+[\d:]+\s+\d+)\s+(.+)$/.exec(result.stdout.trim());
  return result.code === 0 && match ? { pid, uid: Number(match[1]), start: match[2].replace(/\s+/g, ' '), command: match[3] } : null;
}
