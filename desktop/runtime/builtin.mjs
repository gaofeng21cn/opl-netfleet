import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { assert, privateDir } from './io.mjs';

// Resources are shipped offline. Only the platform owner projects them to its
// private backend; subscription data never supplies or replaces these files.
export async function installBuiltin(root, stateDir) {
  const lockBytes = await fs.readFile(path.join(root, 'rulesets.lock.json'));
  const lock = JSON.parse(lockBytes);
  assert(lock.schema === 'opl-netfleet-ruleset-lock.v1', 'invalid_ruleset_lock');
  const files = [['policy-sources/base-v1.json', await fs.readFile(path.join(root, 'policy-sources/base-v1.json'))]];
  for (const rule of lock.rulesets) {
    assert(/^[a-z0-9-]+$/.test(rule.id), 'invalid_ruleset_id');
    const bytes = await fs.readFile(path.join(root, 'rulesets', `${rule.id}.mrs`));
    assert(bytes.length === rule.size_bytes && crypto.createHash('sha256').update(bytes).digest('hex') === rule.sha256, 'builtin_ruleset_mismatch');
    files.push([`backend/run/rulesets/${rule.id}.mrs`, bytes]);
  }
  // Read and verify the complete set before changing any installed resource.
  for (const [relative, bytes] of files) {
    const target = path.join(stateDir, relative);
    await privateDir(path.dirname(target));
    const existing = await fs.readFile(target).catch(error => { if (error.code !== 'ENOENT') throw error; return null; });
    if (existing?.equals(bytes)) continue;
    const temporary = `${target}.install`;
    await fs.writeFile(temporary, bytes, { mode: 0o600 });
    await fs.rename(temporary, target);
  }
}

export async function verifyInstalledBuiltin(root, stateDir) {
  const lock = JSON.parse(await fs.readFile(path.join(root, 'rulesets.lock.json')));
  for (const rule of lock.rulesets) {
    const bytes = await fs.readFile(path.join(stateDir, 'backend/run/rulesets', `${rule.id}.mrs`))
      .catch(() => { throw new Error('builtin_ruleset_missing'); });
    assert(bytes.length === rule.size_bytes && crypto.createHash('sha256').update(bytes).digest('hex') === rule.sha256, 'builtin_ruleset_mismatch');
  }
}
