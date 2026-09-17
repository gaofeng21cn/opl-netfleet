import zlib from 'node:zlib';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { assert } from './io.mjs';

// The panel ships as a release ZIP and stays inside the application's own trust
// boundary: every entry is a plain `dist/` path, links and encrypted rows are
// rejected, and the extracted payload is bounded so a hostile asset cannot fill
// the disk. Nothing here trusts the archive's own directory metadata.
const MAX_ENTRIES = 2048;
const MAX_ENTRY_BYTES = 16 * 1024 * 1024;
const MAX_TOTAL_BYTES = 128 * 1024 * 1024;
const MAX_NAME = 240;
const EOCD = 0x06054b50, CENTRAL = 0x02014b50, LOCAL = 0x04034b50;

function endOfCentralDirectory(buffer) {
  const from = Math.max(0, buffer.length - 65557);
  for (let at = buffer.length - 22; at >= from; at--) if (buffer.readUInt32LE(at) === EOCD) return at;
  throw new Error('dashboard_archive_invalid');
}

function payloadName(entry) {
  const name = entry.name;
  assert(name.length > 0 && name.length <= MAX_NAME && name.startsWith('dist/') && !name.includes('\\'),
    'dashboard_archive_invalid');
  const parts = name.split('/');
  assert(!parts.some(part => part === '..' || part === '.' || part === ''), 'dashboard_archive_invalid');
  return name.slice('dist/'.length);
}

/** Read a verified manifest of `dist/` files from a panel archive. */
export function readPanelArchive(buffer) {
  const eocd = endOfCentralDirectory(buffer);
  const count = buffer.readUInt16LE(eocd + 10);
  const size = buffer.readUInt32LE(eocd + 12);
  let offset = buffer.readUInt32LE(eocd + 16);
  assert(count > 0 && count <= MAX_ENTRIES && offset + size <= buffer.length, 'dashboard_archive_invalid');
  const entries = [];
  let total = 0;
  for (let index = 0; index < count; index++) {
    assert(offset + 46 <= buffer.length && buffer.readUInt32LE(offset) === CENTRAL, 'dashboard_archive_invalid');
    const flags = buffer.readUInt16LE(offset + 8);
    const method = buffer.readUInt16LE(offset + 10);
    const compressed = buffer.readUInt32LE(offset + 20);
    const uncompressed = buffer.readUInt32LE(offset + 24);
    const nameLength = buffer.readUInt16LE(offset + 28);
    const extraLength = buffer.readUInt16LE(offset + 30);
    const commentLength = buffer.readUInt16LE(offset + 32);
    const mode = buffer.readUInt32LE(offset + 38) >>> 16;
    const header = buffer.readUInt32LE(offset + 42);
    const name = buffer.subarray(offset + 46, offset + 46 + nameLength).toString('utf8');
    offset += 46 + nameLength + extraLength + commentLength;
    assert((flags & 0x1) === 0, 'dashboard_archive_invalid');
    const kind = mode & 0o170000;
    if (kind === 0o040000 || name.endsWith('/')) continue;
    assert(kind === 0 || kind === 0o100000, 'dashboard_archive_invalid');
    assert([0, 8].includes(method), 'dashboard_archive_invalid');
    const relative = payloadName({ name });
    total += uncompressed;
    assert(uncompressed <= MAX_ENTRY_BYTES && total <= MAX_TOTAL_BYTES, 'dashboard_archive_invalid');
    assert(header + 30 <= buffer.length && buffer.readUInt32LE(header) === LOCAL, 'dashboard_archive_invalid');
    const localName = buffer.readUInt16LE(header + 26);
    const localExtra = buffer.readUInt16LE(header + 28);
    const start = header + 30 + localName + localExtra;
    assert(start + compressed <= buffer.length, 'dashboard_archive_invalid');
    entries.push({ relative, method, compressed: buffer.subarray(start, start + compressed), size: uncompressed });
  }
  assert(entries.some(entry => entry.relative === 'index.html'), 'dashboard_archive_invalid');
  return entries;
}

/** Expand a verified archive into `{ relative, bytes }` rows. */
export function expandPanelArchive(buffer) {
  return readPanelArchive(buffer).map(entry => {
    const bytes = entry.method === 0 ? entry.compressed : zlib.inflateRawSync(entry.compressed, { maxOutputLength: entry.size });
    assert(bytes.length === entry.size, 'dashboard_archive_invalid');
    return { relative: entry.relative, bytes };
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
