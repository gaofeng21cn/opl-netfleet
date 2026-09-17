#!/usr/bin/env node
// 更新签名工具：ED25519 密钥生成与发布清单签名。macOS 自带的 LibreSSL 不支持
// Ed25519，因此与运行时一致使用 Node 的 crypto，而不是外部 openssl。
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const SCHEMA = 'opl-netfleet-macos-update.v1';
const REPO = 'gaofeng21cn/opl-netfleet';
const DEFAULT_KEY = path.join(os.homedir(), '.config/opl-netfleet/update-signing-key.pem');

const fail = message => { console.error(message); process.exit(1); };
const option = (args, name, fallback = null) => {
  const at = args.indexOf(name);
  return at < 0 ? fallback : args[at + 1];
};

async function keygen(args) {
  const privateKey = path.resolve(option(args, '--private', DEFAULT_KEY));
  const publicKey = path.resolve(option(args, '--public', path.resolve('scripts/macos/update-key.pub')));
  if (await fs.access(privateKey).then(() => true, () => false) && !args.includes('--force')) {
    fail(`Refusing to overwrite the existing private key: ${privateKey}`);
  }
  await fs.mkdir(path.dirname(privateKey), { recursive: true, mode: 0o700 });
  const { publicKey: pub, privateKey: priv } = crypto.generateKeyPairSync('ed25519');
  await fs.writeFile(privateKey, priv.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
  await fs.chmod(privateKey, 0o600);
  await fs.writeFile(publicKey, pub.export({ type: 'spki', format: 'pem' }));
  console.log(`private key: ${privateKey} (0600, back this up)`);
  console.log(`public key:  ${publicKey}`);
}

async function manifest(args) {
  const dmg = path.resolve(option(args, '--dmg') ?? fail('--dmg is required'));
  const app = path.resolve(option(args, '--app') ?? fail('--app is required'));
  const tag = option(args, '--tag') ?? fail('--tag is required');
  const key = path.resolve(option(args, '--key', DEFAULT_KEY));
  const output = path.resolve(option(args, '--output') ?? fail('--output is required'));
  if (!/^macos-v\d+\.\d+\.\d+$/.test(tag)) fail('Tag must use the macos-vX.Y.Z form');
  const version = tag.replace(/^macos-v/, '');
  const privateKey = await fs.readFile(key, 'utf8').catch(() => fail(`Signing key is missing: ${key}`));
  if (((await fs.stat(key)).mode & 0o077) !== 0) fail('Signing key must not be readable by other users (chmod 600)');
  const identity = JSON.parse(await fs.readFile(path.join(app, 'Contents/Resources/build.json'), 'utf8'));
  if (identity.channel !== 'distribution' || identity.working_tree_dirty !== false) fail('A clean distribution build is required');
  if (identity.package_version !== version) fail(`Bundle version ${identity.package_version} does not match ${tag}`);
  const described = await new Promise((resolve, reject) => {
    const child = spawn('/usr/bin/codesign', ['-dv', '--verbose=4', app]);
    let text = ''; child.stderr.on('data', data => { text += data; }); child.stdout.on('data', data => { text += data; });
    child.on('close', code => code === 0 ? resolve(text) : reject(new Error('codesign -dv failed')));
    child.on('error', reject);
  }).catch(error => fail(String(error.message)));
  const team = /TeamIdentifier=(\S+)/.exec(described)?.[1];
  if (!team || team === 'not set') fail('The application must be Developer ID signed');
  const bytes = await fs.readFile(dmg);
  const payload = Buffer.from(JSON.stringify({
    schema: SCHEMA, version, release: identity.package_release, tag,
    source_commit: identity.source_commit, source_tree: identity.source_tree,
    asset: path.basename(dmg), url: `https://github.com/${REPO}/releases/download/${tag}/${path.basename(dmg)}`,
    size_bytes: bytes.length, sha256: crypto.createHash('sha256').update(bytes).digest('hex'), team_id: team,
  }, null, 2) + '\n');
  const signature = crypto.sign(null, payload, crypto.createPrivateKey(privateKey));
  await fs.writeFile(output, payload);
  await fs.writeFile(`${output}.sig`, `${signature.toString('hex')}\n`);
  console.log(payload.toString('utf8'));
  console.log(`wrote ${output} and ${path.basename(output)}.sig`);
}

const [command, ...args] = process.argv.slice(2);
if (command === 'keygen') await keygen(args);
else if (command === 'manifest') await manifest(args);
else fail('usage: update-sign.mjs keygen|manifest [options]');
