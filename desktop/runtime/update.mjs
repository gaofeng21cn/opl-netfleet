import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { assert, run } from './io.mjs';

// 应用更新的信任锚是 Apple 代码签名与公证，不是自建密钥：Developer ID 证书
// 已经承担签名职责，再加一层清单密钥只会重复同一个信任问题。GitHub Release
// 提供 DMG 的 sha256 摘要用于完整性校验，来源身份由签名与公证证明。
export const RELEASE_TAG = /^macos-v(\d+\.\d+\.\d+)$/;
export const DMG_ASSET = /^OPL-NetFleet-.*macos-arm64\.dmg$/;
// 公开事实：应用的 Developer ID 团队标识，用于确认候选确实来自本产品。
export const TEAM_ID = 'SVVC4TA784';
// 应用镜像比面板资源大得多（当前 DMG 约 75 MB），下载上限必须按镜像而不是按
// 面板资产来定；超限即拒绝，避免被伪造的清单拖垮磁盘或内存。
export const MAX_APP_IMAGE_BYTES = 268435456;

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

/** 从 Release 列表选出版本最高的正式 macOS Release。 */
export function latestRelease(releases) {
  return (Array.isArray(releases) ? releases : [])
    .filter(item => item?.draft === false && item?.prerelease === false && RELEASE_TAG.test(String(item?.tag_name ?? '')))
    .sort((left, right) => String(right.tag_name).localeCompare(String(left.tag_name), 'en', { numeric: true }))[0] ?? null;
}

/** Release 必须同时给出 DMG 与 GitHub 计算的 sha256 摘要，否则不可安装。 */
export function releaseCandidate(release, { allowLoopbackHttp = false } = {}) {
  if (!release) return null;
  // 草稿与预发布只作为手动下载入口，不能成为安装候选。
  if (release.draft !== false || release.prerelease !== false) return null;
  const version = RELEASE_TAG.exec(String(release.tag_name))?.[1] ?? null;
  const asset = (Array.isArray(release.assets) ? release.assets : [])
    .find(item => DMG_ASSET.test(String(item?.name ?? '')) && /^sha256:[a-f0-9]{64}$/.test(String(item?.digest ?? '')));
  if (!version || !asset) return null;
  const url = String(asset.browser_download_url ?? '');
  // 生产只接受 https；测试夹具经显式开关可指向本机回环地址。
  const loopback = allowLoopbackHttp && /^http:\/\/(127\.0\.0\.1|\[::1\]|localhost):\d+\//.test(url);
  if (!Number.isInteger(asset.size) || asset.size <= 0 || (!/^https:\/\//.test(url) && !loopback)) return null;
  return { version, tag: release.tag_name, url: asset.browser_download_url, name: asset.name,
    size_bytes: asset.size, sha256: asset.digest.slice('sha256:'.length), page: release.html_url ?? null,
    published_at: release.published_at ?? null };
}

export const sha256 = value => crypto.createHash('sha256').update(value).digest('hex');

/**
 * 从应用资源目录回到 `.app` 包本身：资源目录的父级是 `Contents`，再上一层才是包。
 * 源码运行时没有这层结构，返回 null，自更新据此拒绝而不是猜一个目标目录。
 */
export function applicationBundle(appRoot) {
  const contents = path.dirname(appRoot);
  return path.basename(contents) === 'Contents' ? path.dirname(contents) : null;
}

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
    const apps = (await fs.readdir(mount)).filter(name => name.endsWith('.app'));
    assert(apps.length === 1, 'update_image_invalid');
    return await action(path.join(mount, apps[0]));
  } finally {
    await run('/usr/bin/hdiutil', ['detach', mount, '-force'], { timeout: 60000 }).catch(() => {});
  }
}

/**
 * 新包必须来自本产品的 Developer ID 签名、已公证，并且是干净的分发构建且版本
 * 与 Release tag 一致。Apple 的签名与公证是这一层的完整信任来源。
 */
export async function verifyBundle(app, expected, teamId = TEAM_ID) {
  const version = typeof expected === 'string' ? expected : expected?.version;
  assert(parseVersion(version), 'update_version_invalid');
  const strict = await run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], { timeout: 120000 });
  assert(strict.code === 0, 'update_signature_invalid');
  const details = await run('/usr/bin/codesign', ['-dv', '--verbose=4', app], { timeout: 60000 });
  const described = `${details.stdout}\n${details.stderr}`;
  assert(described.includes('Authority=Developer ID Application:'), 'update_signature_untrusted');
  assert(described.includes(`TeamIdentifier=${teamId}`), 'update_team_identity_mismatch');
  // 先核对包内身份：版本与提交不符时给出可诊断的原因，而不是只报公证失败。
  const identity = JSON.parse(await fs.readFile(path.join(app, 'Contents/Resources/build.json'), 'utf8'));
  assert(identity.channel === 'distribution' && identity.working_tree_dirty === false, 'update_not_a_distribution_build');
  assert(identity.package_version === version, 'update_version_mismatch');
  assert(/^[0-9a-f]{40}$/.test(String(identity.source_commit ?? '')) && /^[0-9a-f]{40}$/.test(String(identity.source_tree ?? '')),
    'update_source_missing');
  // 公证是这条链的另一半：spctl 要求 Gatekeeper 能验证票据，stapler 确认票据已装订。
  const gatekeeper = await run('/usr/sbin/spctl', ['--assess', '--type', 'execute', '--verbose=2', app], { timeout: 180000 });
  assert(gatekeeper.code === 0, 'update_notarization_unverified');
  const stapled = await run('/usr/bin/stapler', ['validate', app], { timeout: 120000 });
  assert(stapled.code === 0, 'update_notarization_unverified');
  return identity;
}
