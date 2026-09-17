import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { assert, run } from './io.mjs';

// 应用自更新沿用成熟更新器的形状：单独签名的清单 + 有界下载 + 校验后替换 + 重启。
// 这里只做可机械证明的判断；网络读取、暂存编排和退出交接由宿主运行时负责。
export const UPDATE_SCHEMA = 'opl-netfleet-macos-update.v1';
export const UPDATE_KEY_SCHEMA = 'opl-netfleet-macos-update-key.v1';

export function parseVersion(value) {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(String(value ?? '').replace(/^v/, ''));
  return match ? match.slice(1).map(Number) : null;
}

export function newerVersion(candidate, installed) {
  const left = parseVersion(candidate), right = parseVersion(installed);
  if (!left) return false;
  if (!right) return true;
  for (let index = 0; index < 3; index++) if (left[index] !== right[index]) return left[index] > right[index];
  return false;
}

/** 清单必须由内置公钥签名的原始字节验证；签名覆盖清单文件本身。 */
export function verifyManifest(payload, signature, publicKey) {
  assert(Buffer.isBuffer(payload) && Buffer.isBuffer(signature), 'update_manifest_invalid');
  // 公钥不可解析或不是 Ed25519 都属于"来源不可信"，与签名不匹配同等拒绝。
  let key;
  try { key = publicKey instanceof crypto.KeyObject ? publicKey : crypto.createPublicKey(publicKey); }
  catch { throw new Error('update_key_invalid'); }
  assert(key.asymmetricKeyType === 'ed25519', 'update_key_invalid');
  assert(crypto.verify(null, payload, key, signature), 'update_signature_invalid');
  let manifest;
  try { manifest = JSON.parse(payload.toString('utf8')); } catch { throw new Error('update_manifest_invalid'); }
  assert(manifest && typeof manifest === 'object', 'update_manifest_invalid');
  assert(manifest.schema === UPDATE_SCHEMA, 'update_manifest_invalid');
  const version = parseVersion(manifest.version);
  assert(version && typeof manifest.tag === 'string' && manifest.tag === `macos-v${manifest.version}`, 'update_manifest_invalid');
  assert(typeof manifest.release === 'string' && manifest.release.length > 0, 'update_manifest_invalid');
  assert(typeof manifest.asset === 'string' && /^[A-Za-z0-9._-]+$/.test(manifest.asset), 'update_manifest_invalid');
  assert(typeof manifest.url === 'string' && manifest.url.startsWith('https://'), 'update_manifest_invalid');
  assert(Number.isInteger(manifest.size_bytes) && manifest.size_bytes > 0, 'update_manifest_invalid');
  assert(/^[a-f0-9]{64}$/.test(String(manifest.sha256 ?? '')), 'update_manifest_invalid');
  assert(/^[a-f0-9]{40}$/.test(String(manifest.source_commit ?? '')), 'update_manifest_invalid');
  assert(/^[A-Z0-9]{10}$/.test(String(manifest.team_id ?? '')), 'update_manifest_invalid');
  return manifest;
}

export const sha256 = value => crypto.createHash('sha256').update(value).digest('hex');

export async function fileDigest(file) {
  try { return sha256(await fs.readFile(file)); } catch { return null; }
}

/** 单个运行组件的同步状态：只有逐字节一致才算已同步。 */
export async function componentState(bundled, installed) {
  const expected = await fileDigest(bundled);
  if (!expected) return { state: 'unbundled' };
  const actual = await fileDigest(installed);
  if (!actual) return { state: 'missing', expected };
  return { state: actual === expected ? 'match' : 'outdated', expected, installed: actual };
}

/** 挂载只读 DMG 并回读其中的应用，随后总是卸载。 */
export async function withMountedApp(image, work, action) {
  const mount = path.join(work, 'mounted');
  await fs.rm(mount, { recursive: true, force: true });
  await fs.mkdir(mount, { recursive: true, mode: 0o700 });
  const attached = await run('/usr/bin/hdiutil', ['attach', '-nobrowse', '-readonly', '-mountpoint', mount, image], { timeout: 120000 });
  assert(attached.code === 0, 'update_image_unreadable');
  try {
    const entries = await fs.readdir(mount);
    const apps = entries.filter(name => name.endsWith('.app'));
    assert(apps.length === 1, 'update_image_invalid');
    return await action(path.join(mount, apps[0]));
  } finally {
    await run('/usr/bin/hdiutil', ['detach', mount, '-force'], { timeout: 60000 }).catch(() => {});
  }
}

/** 新包必须是同一 Team ID 的 Developer ID 签名、已公证且身份与清单一致。 */
export async function verifyBundle(app, manifest, teamId) {
  assert(teamId && teamId !== 'not set', 'update_team_identity_missing');
  const strict = await run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], { timeout: 120000 });
  assert(strict.code === 0, 'update_signature_invalid');
  const details = await run('/usr/bin/codesign', ['-dv', '--verbose=4', app], { timeout: 60000 });
  const described = `${details.stdout}\n${details.stderr}`;
  assert(described.includes('Authority=Developer ID Application:'), 'update_signature_untrusted');
  assert(described.includes(`TeamIdentifier=${teamId}`), 'update_team_identity_mismatch');
  const gatekeeper = await run('/usr/bin/spctl', ['--assess', '--type', 'execute', '--verbose=2', app], { timeout: 180000 });
  assert(gatekeeper.code === 0, 'update_notarization_unverified');
  const stapled = await run('/usr/bin/stapler', ['validate', app], { timeout: 120000 });
  assert(stapled.code === 0, 'update_notarization_unverified');
  const identity = JSON.parse(await fs.readFile(path.join(app, 'Contents/Resources/build.json'), 'utf8'));
  assert(identity.channel === 'distribution' && identity.working_tree_dirty === false, 'update_not_a_distribution_build');
  assert(identity.package_version === manifest.version && identity.package_release === manifest.release, 'update_version_mismatch');
  assert(identity.source_commit === manifest.source_commit, 'update_source_mismatch');
  return identity;
}
