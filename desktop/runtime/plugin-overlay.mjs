import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { readJSON, object, run } from './io.mjs';

export const OVERLAY_SCHEMA = 'opl-netfleet-plugin-overlay.v1';
const SERVICE_PLUGIN_SCHEMA = 'opl-netfleet-service-plugin.v1';
const SIGNATURE_FILENAME = 'overlay-signature.json';
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const PLUGIN_ID_RE = /^[a-z0-9][a-z0-9-]*$/;
const SEMVER_RE = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const SHA256_RE = /^[a-f0-9]{64}$/;

class OverlayRejectError extends Error {
  constructor(reason) {
    super(reason);
    this.reason = reason;
  }
}

function parseSemver(version) {
  if (typeof version !== 'string') return null;
  const match = SEMVER_RE.exec(version);
  return match ? [Number(match[1]), Number(match[2]), Number(match[3])] : null;
}

function compareSemver(left, right) {
  const a = parseSemver(left);
  const b = parseSemver(right);
  if (!a || !b) return null;
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) return a[i] > b[i] ? 1 : -1;
  }
  return 0;
}

function normalizeRelativePath(rel) {
  if (typeof rel !== 'string' || rel.length === 0) return null;
  if (rel.startsWith('/') || rel.includes('\\') || /[\x00-\x1f\x7f]/.test(rel)) return null;
  const segments = rel.split('/');
  if (segments.some(seg => seg === '' || seg === '.' || seg === '..')) return null;
  if (rel === SIGNATURE_FILENAME) return null;
  return rel;
}

function parsePublicKey(publicKeyBase64) {
  if (typeof publicKeyBase64 !== 'string') return null;
  const trimmed = publicKeyBase64.trim();
  if (!trimmed) return null;
  let raw;
  try {
    raw = Buffer.from(trimmed, 'base64');
  } catch {
    return null;
  }
  if (raw.length !== 32 || raw.toString('base64') !== trimmed) return null;
  try {
    return crypto.createPublicKey({
      key: Buffer.concat([ED25519_SPKI_PREFIX, raw]),
      format: 'der',
      type: 'spki',
    });
  } catch {
    return null;
  }
}

export async function readPublicKeyFromPlist(plistPath) {
  if (typeof plistPath !== 'string' || !plistPath) return null;
  try {
    await fs.access(plistPath);
  } catch {
    return null;
  }
  try {
    const res = await run('/usr/bin/plutil', ['-extract', 'SUPublicEDKey', 'raw', '-o', '-', plistPath], { timeout: 3000 });
    const value = res.code === 0 ? res.stdout.trim() : '';
    return value || null;
  } catch {
    return null;
  }
}

export function canonicalOverlayPayload(envelope) {
  return JSON.stringify({
    schema: envelope.schema,
    id: envelope.id,
    version: envelope.version,
    files: envelope.files.map(item => ({ path: item.path, sha256: item.sha256 })),
  });
}

export function verifyOverlaySignature(envelope, publicKeyBase64) {
  const key = parsePublicKey(publicKeyBase64);
  if (!key || !object(envelope) || typeof envelope.signature !== 'string') return false;
  const trimmedSig = envelope.signature.trim();
  let sigBytes;
  try {
    sigBytes = Buffer.from(trimmedSig, 'base64');
  } catch {
    return false;
  }
  if (sigBytes.length !== 64 || sigBytes.toString('base64') !== trimmedSig) return false;
  const payload = Buffer.from(canonicalOverlayPayload(envelope), 'utf8');
  try {
    return crypto.verify(null, payload, key, sigBytes);
  } catch {
    return false;
  }
}

function validateEnvelope(envelope, pluginId) {
  if (!object(envelope)) throw new OverlayRejectError('invalid_signature_envelope');
  const keys = Object.keys(envelope).sort();
  if (keys.join(',') !== 'files,id,schema,signature,version') {
    throw new OverlayRejectError('invalid_signature_envelope');
  }
  if (envelope.schema !== OVERLAY_SCHEMA || envelope.id !== pluginId || !parseSemver(envelope.version)) {
    throw new OverlayRejectError('invalid_signature_envelope');
  }
  if (typeof envelope.signature !== 'string' || envelope.signature.trim().length === 0) {
    throw new OverlayRejectError('invalid_signature_envelope');
  }
  if (!Array.isArray(envelope.files) || envelope.files.length === 0) {
    throw new OverlayRejectError('invalid_signature_envelope');
  }
  let previousPath = null;
  for (const entry of envelope.files) {
    if (!object(entry)) throw new OverlayRejectError('invalid_signature_envelope');
    const entryKeys = Object.keys(entry).sort();
    if (entryKeys.join(',') !== 'path,sha256') {
      throw new OverlayRejectError('invalid_signature_envelope');
    }
    const cleanPath = normalizeRelativePath(entry.path);
    if (!cleanPath || typeof entry.sha256 !== 'string' || !SHA256_RE.test(entry.sha256)) {
      throw new OverlayRejectError('invalid_signature_envelope');
    }
    if (previousPath !== null && !(cleanPath > previousPath)) {
      throw new OverlayRejectError('invalid_signature_envelope');
    }
    previousPath = cleanPath;
  }
}

async function collectOverlayFiles(rootDir, currentRel = '', collected = new Map()) {
  const dirPath = currentRel ? path.join(rootDir, currentRel) : rootDir;
  const entries = await fs.readdir(dirPath);
  entries.sort();
  for (const name of entries) {
    const rel = currentRel ? `${currentRel}/${name}` : name;
    const abs = path.join(dirPath, name);
    const stat = await fs.lstat(abs);
    if (stat.isSymbolicLink()) throw new OverlayRejectError('symlink_disallowed');
    if (stat.uid !== process.getuid() || (stat.mode & 0o022) !== 0) {
      throw new OverlayRejectError('unsafe_overlay_permissions');
    }
    if (stat.isDirectory()) {
      await collectOverlayFiles(rootDir, rel, collected);
    } else if (stat.isFile()) {
      if (rel === SIGNATURE_FILENAME) {
        collected.set(SIGNATURE_FILENAME, await fs.readFile(abs));
        continue;
      }
      if (!normalizeRelativePath(rel)) {
        throw new OverlayRejectError('invalid_overlay_path');
      }
      collected.set(rel, await fs.readFile(abs));
    } else {
      throw new OverlayRejectError('unsupported_entry_type');
    }
  }
  return collected;
}

async function stageVerifiedPlugin(targetDir, verifiedFiles) {
  const parentDir = path.dirname(targetDir);
  const pluginId = path.basename(targetDir);
  const nonce = crypto.randomBytes(6).toString('hex');
  const stagingDir = path.join(parentDir, `.overlay-${pluginId}-${nonce}`);
  const backupDir = path.join(parentDir, `.prev-${pluginId}-${nonce}`);
  await fs.mkdir(stagingDir, { mode: 0o700 });
  let movedOld = false;
  try {
    for (const [rel, bytes] of verifiedFiles) {
      const dest = path.join(stagingDir, rel);
      await fs.mkdir(path.dirname(dest), { recursive: true, mode: 0o700 });
      await fs.writeFile(dest, bytes, { mode: 0o600 });
    }
    const exists = await fs.lstat(targetDir).then(() => true, error => {
      if (error.code === 'ENOENT') return false;
      throw error;
    });
    if (exists) {
      await fs.rename(targetDir, backupDir);
      movedOld = true;
    }
    await fs.rename(stagingDir, targetDir);
    if (movedOld) await fs.rm(backupDir, { recursive: true, force: true });
  } catch {
    if (movedOld) {
      const restoredNeeded = await fs.lstat(targetDir).then(() => false, () => true);
      if (restoredNeeded) await fs.rename(backupDir, targetDir).catch(() => {});
    }
    await fs.rm(stagingDir, { recursive: true, force: true }).catch(() => {});
    throw new OverlayRejectError('install_failed');
  }
}

export async function applySignedPluginOverlays({ overlayRoot, codeRoot, publicKeyBase64 }) {
  let rootStat;
  try {
    rootStat = await fs.lstat(overlayRoot);
  } catch (error) {
    if (error.code === 'ENOENT') return { applied: [], rejected: [] };
    return { applied: [], rejected: [{ id: '*', reason: 'unsafe_overlay_root' }] };
  }
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink() || rootStat.uid !== process.getuid() || (rootStat.mode & 0o022) !== 0) {
    return { applied: [], rejected: [{ id: '*', reason: 'unsafe_overlay_root' }] };
  }

  const parsedKey = parsePublicKey(publicKeyBase64);
  const bundledPluginsDir = path.join(codeRoot, 'plugins');
  const applied = [];
  const rejected = [];

  const entries = (await fs.readdir(overlayRoot, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name));
  for (const entry of entries) {
    const id = entry.name;
    if (id.startsWith('.')) continue;
    try {
      if (!PLUGIN_ID_RE.test(id)) throw new OverlayRejectError('invalid_plugin_id');
      if (id === 'platform-macos') throw new OverlayRejectError('platform_plugin_disallowed');

      const pluginOverlayDir = path.join(overlayRoot, id);
      const dirStat = await fs.lstat(pluginOverlayDir);
      if (!dirStat.isDirectory() || dirStat.isSymbolicLink() || dirStat.uid !== process.getuid() || (dirStat.mode & 0o022) !== 0) {
        throw new OverlayRejectError('unsafe_overlay_directory');
      }

      const targetPluginDir = path.join(bundledPluginsDir, id);
      const bundledManifest = await readJSON(path.join(targetPluginDir, 'manifest.json')).catch(() => null);
      if (!object(bundledManifest) || bundledManifest.schema !== SERVICE_PLUGIN_SCHEMA || bundledManifest.id !== id || !parseSemver(bundledManifest.version)) {
        throw new OverlayRejectError('unknown_plugin_id');
      }

      if (!parsedKey) throw new OverlayRejectError('missing_public_key');

      const fileMap = await collectOverlayFiles(pluginOverlayDir);
      const sigBytes = fileMap.get(SIGNATURE_FILENAME);
      if (!sigBytes) throw new OverlayRejectError('missing_signature');
      let envelope;
      try {
        envelope = JSON.parse(sigBytes.toString('utf8'));
      } catch {
        throw new OverlayRejectError('invalid_signature_envelope');
      }
      validateEnvelope(envelope, id);

      if (!verifyOverlaySignature(envelope, publicKeyBase64)) {
        throw new OverlayRejectError('signature_verification_failed');
      }

      const expectedPaths = new Set(envelope.files.map(item => item.path));
      for (const actualPath of fileMap.keys()) {
        if (actualPath === SIGNATURE_FILENAME) continue;
        if (!expectedPaths.has(actualPath)) throw new OverlayRejectError('unlisted_overlay_file');
      }

      const verifiedFiles = [];
      for (const item of envelope.files) {
        const bytes = fileMap.get(item.path);
        if (!bytes) throw new OverlayRejectError('missing_overlay_file');
        const actualSha = crypto.createHash('sha256').update(bytes).digest('hex');
        if (actualSha !== item.sha256) throw new OverlayRejectError('file_digest_mismatch');
        verifiedFiles.push([item.path, bytes]);
      }

      const manifestEntry = verifiedFiles.find(([rel]) => rel === 'manifest.json');
      if (!manifestEntry) throw new OverlayRejectError('invalid_manifest');
      let overlayManifest;
      try {
        overlayManifest = JSON.parse(manifestEntry[1].toString('utf8'));
      } catch {
        throw new OverlayRejectError('invalid_manifest');
      }
      if (!object(overlayManifest) || overlayManifest.schema !== SERVICE_PLUGIN_SCHEMA || overlayManifest.id !== id || overlayManifest.version !== envelope.version) {
        throw new OverlayRejectError('invalid_manifest');
      }
      const order = compareSemver(overlayManifest.version, bundledManifest.version);
      if (order === null || order <= 0) {
        throw new OverlayRejectError('downgrade_rejected');
      }

      await stageVerifiedPlugin(targetPluginDir, verifiedFiles);
      applied.push({ id, version: overlayManifest.version, bundled_version: bundledManifest.version });
    } catch (error) {
      rejected.push({ id, reason: error instanceof OverlayRejectError ? error.reason : 'overlay_verification_failed' });
    }
  }

  return { applied, rejected };
}
