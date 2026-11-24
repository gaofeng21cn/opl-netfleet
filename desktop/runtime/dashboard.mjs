import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { assert, run } from './io.mjs';

// The panel ships as a release ZIP and stays inside the application's own trust
// boundary: every entry is a plain `dist/` path, links and encrypted rows are
// rejected, and the extracted payload is bounded so a hostile asset cannot fill
// the disk. Archive inspection and extraction delegate to system `unzip` /
// `/usr/bin/ditto -xk` rather than hand-parsing raw ZIP binary structures.
const MAX_ENTRIES = 2048;
const MAX_ENTRY_BYTES = 16 * 1024 * 1024;
const MAX_TOTAL_BYTES = 128 * 1024 * 1024;
const MAX_NAME = 240;
const ALLOWED_METHODS = new Set(['stor', 'defN', 'defX', 'defF', 'defS']);
const ZIPINFO_ROW = /^([\-?dlcbps])([rwxstST-]{9})\s+\S+\s+\S+\s+(\d+)\s+([a-zA-Z][a-zA-Z0-9\-])\s+(\d+)\s+(\S+)\s+\d{8}\.\d{6}\s+(.+)$/;

function payloadName(name) {
  assert(typeof name === 'string' && name.length > 0 && name.length <= MAX_NAME && name.startsWith('dist/') && !name.includes('\\') && !name.includes('\0'),
    'dashboard_archive_invalid');
  const parts = name.split('/');
  assert(!parts.some(part => part === '..' || part === '.' || part === ''), 'dashboard_archive_invalid');
  return name.slice('dist/'.length);
}

async function inspectArchiveFile(archivePath) {
  const listing = await run('/usr/bin/unzip', ['-Z', '-T', '-l', archivePath], { timeout: 30000 });
  assert(listing.code === 0, 'dashboard_archive_invalid');
  const lines = listing.stdout.split(/\r?\n/).filter(line => line.length > 0);
  // Skip zipinfo header ("Archive: ...", "Zip file size: ...") and summary footer ("N files, ...").
  assert(lines.length >= 4 && lines[0].startsWith('Archive:') && lines[1].startsWith('Zip file size:'), 'dashboard_archive_invalid');
  const bodyLines = lines.slice(2, -1);
  assert(bodyLines.length > 0 && bodyLines.length <= MAX_ENTRIES, 'dashboard_archive_invalid');
  const entries = [];
  let total = 0;
  for (const line of bodyLines) {
    const match = ZIPINFO_ROW.exec(line);
    assert(match, 'dashboard_archive_invalid');
    const [, kind, , rawSize, flags, , method, name] = match;
    // Uppercase first flag character ("T" or "B") marks an encrypted entry.
    assert(flags[0] === flags[0].toLowerCase(), 'dashboard_archive_invalid');
    if (kind === 'd' || name.endsWith('/')) {
      assert(kind === 'd' || kind === '?' || kind === '-', 'dashboard_archive_invalid');
      const trimmed = name.replace(/\/+$/, '');
      assert(trimmed === 'dist' || trimmed.startsWith('dist/'), 'dashboard_archive_invalid');
      assert(!trimmed.split('/').some(part => part === '..' || part === '.' || part === ''), 'dashboard_archive_invalid');
      continue;
    }
    // Only regular files (or DOS entries without Unix type bits) are permitted; reject symlinks and special nodes.
    assert(kind === '-' || kind === '?', 'dashboard_archive_invalid');
    assert(ALLOWED_METHODS.has(method), 'dashboard_archive_invalid');
    const size = Number(rawSize);
    assert(Number.isSafeInteger(size) && size >= 0 && size <= MAX_ENTRY_BYTES, 'dashboard_archive_invalid');
    total += size;
    assert(total <= MAX_TOTAL_BYTES, 'dashboard_archive_invalid');
    const relative = payloadName(name);
    entries.push({ relative, size });
  }
  assert(entries.length > 0 && entries.length <= MAX_ENTRIES, 'dashboard_archive_invalid');
  assert(entries.some(entry => entry.relative === 'index.html'), 'dashboard_archive_invalid');
  return entries;
}

async function withArchiveTemp(buffer, action) {
  assert(Buffer.isBuffer(buffer) && buffer.length > 0 && buffer.length <= MAX_TOTAL_BYTES, 'dashboard_archive_invalid');
  const work = await fs.mkdtemp(path.join(os.tmpdir(), 'netfleet-panel-zip-'));
  try {
    await fs.chmod(work, 0o700);
    const archivePath = path.join(work, 'panel.zip');
    await fs.writeFile(archivePath, buffer, { mode: 0o600 });
    return await action(work, archivePath);
  } finally {
    await fs.rm(work, { recursive: true, force: true });
  }
}

/** Read a verified manifest of `dist/` files from a panel archive. */
export async function readPanelArchive(buffer) {
  return withArchiveTemp(buffer, (_work, archivePath) => inspectArchiveFile(archivePath));
}

/** Expand a verified archive into `{ relative, bytes }` rows via ditto/unzip. */
export async function expandPanelArchive(buffer) {
  return withArchiveTemp(buffer, async (work, archivePath) => {
    const manifest = await inspectArchiveFile(archivePath);
    const integrity = await run('/usr/bin/unzip', ['-tqq', archivePath], { timeout: 60000 });
    assert(integrity.code === 0, 'dashboard_archive_invalid');
    const expected = new Map(manifest.map(entry => [entry.relative, entry.size]));
    const extracted = path.join(work, 'extracted');
    await fs.mkdir(extracted, { mode: 0o700 });
    const extractResult = process.platform === 'darwin'
      ? await run('/usr/bin/ditto', ['-x', '-k', archivePath, extracted], { timeout: 60000 })
      : await run('/usr/bin/unzip', ['-qq', '-n', archivePath, '-d', extracted], { timeout: 60000 });
    assert(extractResult.code === 0, 'dashboard_archive_invalid');

    const distRoot = path.join(extracted, 'dist');
    const distInfo = await fs.lstat(distRoot).catch(() => null);
    assert(distInfo && distInfo.isDirectory() && !distInfo.isSymbolicLink(), 'dashboard_archive_invalid');
    const realDist = await fs.realpath(distRoot);

    const rows = [];
    let total = 0;
    async function walk(directory) {
      const entries = await fs.readdir(directory, { withFileTypes: true });
      for (const entry of entries) {
        const origin = path.join(directory, entry.name);
        const info = await fs.lstat(origin);
        assert(!info.isSymbolicLink(), 'dashboard_archive_invalid');
        const resolved = await fs.realpath(origin);
        assert(resolved === realDist || resolved.startsWith(`${realDist}${path.sep}`), 'dashboard_archive_invalid');
        if (info.isDirectory()) {
          await walk(origin);
          continue;
        }
        assert(info.isFile(), 'dashboard_archive_invalid');
        const relative = path.relative(distRoot, origin).split(path.sep).join('/');
        assert(expected.has(relative), 'dashboard_archive_invalid');
        const bytes = await fs.readFile(origin);
        assert(bytes.length === expected.get(relative) && bytes.length <= MAX_ENTRY_BYTES, 'dashboard_archive_invalid');
        total += bytes.length;
        assert(rows.length < MAX_ENTRIES && total <= MAX_TOTAL_BYTES, 'dashboard_archive_invalid');
        rows.push({ relative, bytes });
      }
    }
    await walk(distRoot);
    assert(rows.length === expected.size && rows.some(row => row.relative === 'index.html'), 'dashboard_archive_invalid');
    return rows;
  });
}

const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

/**
 * Replace a panel directory with `rows` without ever serving a missing path:
 * every file is written next to its target and renamed into place, then files
 * the new manifest no longer contains are removed. The manifest is written last
 * so an interrupted install is reconciled on the next attempt.
 */
export async function installPanel(rows, destination) {
  assert(rows.length > 0 && rows.length <= MAX_ENTRIES, 'dashboard_archive_invalid');
  await fs.mkdir(destination, { recursive: true, mode: 0o700 });
  const manifestPath = path.join(destination, '.panel.json');
  const previous = await fs.readFile(manifestPath, 'utf8').then(JSON.parse, () => null);
  const files = {};
  let total = 0;
  for (const row of rows) {
    const relative = row.relative;
    assert(typeof relative === 'string' && relative.length > 0 && !relative.includes('\\'), 'dashboard_archive_invalid');
    const parts = relative.split('/');
    assert(!parts.some(part => part === '..' || part === '.' || part === ''), 'dashboard_archive_invalid');
    total += row.bytes.length;
    assert(row.bytes.length <= MAX_ENTRY_BYTES && total <= MAX_TOTAL_BYTES, 'dashboard_archive_invalid');
    const target = path.join(destination, relative);
    assert(path.relative(destination, target).startsWith('..') === false, 'dashboard_archive_invalid');
    await fs.mkdir(path.dirname(target), { recursive: true, mode: 0o700 });
    const temporary = `${target}.incoming-${process.pid}`;
    await fs.writeFile(temporary, row.bytes, { mode: 0o600 });
    await fs.rename(temporary, target);
    files[relative] = digest(row.bytes);
  }
  for (const relative of Object.keys(previous?.files ?? {})) {
    if (files[relative]) continue;
    const target = path.join(destination, relative);
    assert(path.relative(destination, target).startsWith('..') === false, 'dashboard_archive_invalid');
    await fs.rm(target, { force: true });
  }
  await fs.writeFile(manifestPath, JSON.stringify({ schema: 'opl-netfleet-macos-panel.v1', files }, null, 2), { mode: 0o600 });
  return { files: Object.keys(files).length, bytes: total };
}

/** Read a panel directory's manifest so the runtime can report its identity. */
export async function readPanelManifest(destination) {
  return fs.readFile(path.join(destination, '.panel.json'), 'utf8').then(JSON.parse, () => null);
}

/** Copy a prepared panel into the directory the running core serves. */
export async function materializePanel(source, destination) {
  const rows = [];
  let total = 0;
  async function walk(directory) {
    const entries = await fs.readdir(directory, { withFileTypes: true });
    for (const entry of entries) {
      const origin = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) throw new Error('panel_resources_invalid');
      if (entry.isDirectory()) { await walk(origin); continue; }
      if (!entry.isFile() || entry.name.startsWith('.panel.json')) continue;
      const info = await fs.lstat(origin);
      total += info.size;
      assert(rows.length < MAX_ENTRIES && total <= MAX_TOTAL_BYTES, 'panel_resources_invalid');
      rows.push({ relative: path.relative(source, origin).split(path.sep).join('/'), bytes: await fs.readFile(origin) });
    }
  }
  await walk(source);
  assert(rows.some(row => row.relative === 'index.html'), 'panel_resources_invalid');
  await installPanel(rows, destination);
  return destination;
}
