import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { codeDigest, run } from '../runtime/io.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const runtime = process.env.NETFLEET_RUNTIME_ROOT;
assert.ok(runtime, 'NETFLEET_RUNTIME_ROOT is required; bridge qualification cannot be skipped');

async function bridge(t, response, token = 'test-token') {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'nf-bridge-'));
  const socketPath = path.join(directory, 'rpc.sock');
  const server = net.createServer(socket => {
    let input = '';
    socket.on('error', () => {});
    socket.on('data', chunk => {
      input += chunk.toString();
      const start = input.indexOf('\r\n\r\n');
      if (start < 0) return;
      const size = Number(/Content-Length: (\d+)/.exec(input)[1]);
      if (Buffer.byteLength(input.slice(start + 4)) !== size) return;
      assert.ok(input.includes(`Authorization: Bearer ${token}\r\n`));
      assert.deepEqual(JSON.parse(input.slice(start + 4)), { method: 'state.get', params: { name: '机场' } });
      socket.end(response);
    });
  });
  t.after(async () => { await new Promise(resolve => server.close(resolve)); await fs.rm(directory, { recursive: true, force: true }); });
  await new Promise(resolve => server.listen(socketPath, resolve));
  return run(path.join(runtime, 'bin/ucode'), ['-L', `${runtime}/lib/ucode/*.so`, '-e',
    `import { rpc } from '${repo}/desktop/ucode/bridge.uc'; printf('%J', rpc('state.get', { name: '机场' }));`],
    { env: { ...process.env, NETFLEET_SOCKET: socketPath, NETFLEET_RPC_TOKEN: token }, timeout: 10000 });
}
function response(body, status = 200, length = Buffer.byteLength(body)) {
  return `HTTP/1.1 ${status} Result\r\nContent-Length: ${length}\r\nConnection: close\r\n\r\n${body}`;
}

test('native socket preserves authenticated UTF-8 JSON', async t => {
  const body = JSON.stringify({ profile: '机场', enabled: false });
  const result = await bridge(t, response(body));
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), JSON.parse(body));
});
test('owner rejection stays a failure', async t => {
  const result = await bridge(t, response('{"ok":false,"error":"unauthorized"}', 403));
  assert.notEqual(result.code, 0); assert.match(result.stderr, /unauthorized/);
});
test('truncated and malformed owner payloads are rejected', async t => {
  for (const payload of [response('{}', 200, 3), response('not-json')]) {
    const result = await bridge(t, payload);
    assert.notEqual(result.code, 0); assert.match(result.stderr, /desktop_owner_response_invalid/);
  }
});
test('oversized owner payload is rejected', async t => {
  const result = await bridge(t, response('x'.repeat(8 * 1024 * 1024 + 8193)));
  assert.notEqual(result.code, 0); assert.match(result.stderr, /desktop_owner_response_too_large/);
});
test('code digest preserves the canonical ordered double hash and bounds paths', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'nf-digest-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  await fs.writeFile(path.join(directory, 'a.txt'), 'alpha\n');
  await fs.writeFile(path.join(directory, 'b.txt'), 'beta\n');
  const identities = await run(path.join(runtime, 'bin/sha256sum'), ['b.txt', 'a.txt'], { cwd: directory });
  assert.equal(identities.code, 0);
  const expected = crypto.createHash('sha256').update(identities.stdout).digest('hex');
  assert.equal(await codeDigest(directory, directory, ['b.txt', 'a.txt'].map(name => path.join(directory, name))), expected);
  await assert.rejects(codeDigest(directory, os.tmpdir(), [path.join(directory, 'a.txt')]), /outside_root/);
  await fs.symlink(path.join(directory, 'a.txt'), path.join(directory, 'link'));
  await assert.rejects(codeDigest(directory, directory, [path.join(directory, 'link')]), /outside_root/);
});
