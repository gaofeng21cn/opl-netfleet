// Shared host tests exercise the real OpenWrt digest when present. The pinned
// desktop contract runtime omits this OpenWrt-only module; inject a test-only
// reference implementation there, never a fallback in the shipped adapter.
import * as fs from 'fs';
import { create as openwrt } from '../openwrt/files/usr/libexec/opl-netfleet/adapters/openwrt.uc';
import { shell_quote as q } from '../openwrt/files/usr/libexec/opl-netfleet/kernel/io.uc';

const SHA256_K = [
	0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
	0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
	0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
	0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
	0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
	0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
	0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
	0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
];

function sha256_str(s) {
	const n = length(s), bits = n * 8;
	const rem = (n + 9) % 64;
	const pad = rem == 0 ? 0 : 64 - rem;
	const total = n + 1 + pad + 8;
	const b = [];
	for (let i = 0; i < n; i++) push(b, ord(s, i));
	push(b, 0x80);
	for (let i = 0; i < pad; i++) push(b, 0);
	const hi = int(bits / 4294967296), lo = bits & 0xffffffff;
	push(b, (hi >> 24) & 0xff, (hi >> 16) & 0xff, (hi >> 8) & 0xff, hi & 0xff,
	        (lo >> 24) & 0xff, (lo >> 16) & 0xff, (lo >> 8) & 0xff, lo & 0xff);
	let h0=0x6a09e667,h1=0xbb67ae85,h2=0x3c6ef372,h3=0xa54ff53a,h4=0x510e527f,h5=0x9b05688c,h6=0x1f83d9ab,h7=0x5be0cd19;
	const w = [];
	for (let off = 0; off < total; off += 64) {
		for (let i = 0; i < 16; i++) {
			const j = off + i * 4;
			w[i] = ((b[j] << 24) | (b[j+1] << 16) | (b[j+2] << 8) | b[j+3]) & 0xffffffff;
		}
		for (let i = 16; i < 64; i++) {
			const x = w[i-15], y = w[i-2];
			const s0 = (((x >> 7) | (x << 25)) ^ ((x >> 18) | (x << 14)) ^ (x >> 3)) & 0xffffffff;
			const s1 = (((y >> 17) | (y << 15)) ^ ((y >> 19) | (y << 13)) ^ (y >> 10)) & 0xffffffff;
			w[i] = (w[i-16] + s0 + w[i-7] + s1) & 0xffffffff;
		}
		let a=h0,b0=h1,c=h2,d=h3,e=h4,f=h5,g=h6,h=h7;
		for (let i = 0; i < 64; i++) {
			const S1 = (((e >> 6) | (e << 26)) ^ ((e >> 11) | (e << 21)) ^ ((e >> 25) | (e << 7))) & 0xffffffff;
			const ch = (e & f) ^ ((~e & 0xffffffff) & g);
			const t1 = (h + S1 + ch + SHA256_K[i] + w[i]) & 0xffffffff;
			const S0 = (((a >> 2) | (a << 30)) ^ ((a >> 13) | (a << 19)) ^ ((a >> 22) | (a << 10))) & 0xffffffff;
			const maj = (a & b0) ^ (a & c) ^ (b0 & c);
			const t2 = (S0 + maj) & 0xffffffff;
			h=g; g=f; f=e; e=(d+t1)&0xffffffff; d=c; c=b0; b0=a; a=(t1+t2)&0xffffffff;
		}
		h0=(h0+a)&0xffffffff; h1=(h1+b0)&0xffffffff; h2=(h2+c)&0xffffffff; h3=(h3+d)&0xffffffff;
		h4=(h4+e)&0xffffffff; h5=(h5+f)&0xffffffff; h6=(h6+g)&0xffffffff; h7=(h7+h)&0xffffffff;
	}
	return sprintf("%08x%08x%08x%08x%08x%08x%08x%08x", h0,h1,h2,h3,h4,h5,h6,h7);
};

const shared_root_raw = getenv('NETFLEET_TEST_RUNTIME');
const shared_root = shared_root_raw != null && length(shared_root_raw) > 0
	? (fs.realpath(shared_root_raw) ?? shared_root_raw) : null;
let precomputed = {};
const digests_path = getenv('NETFLEET_TEST_DIGESTS');
if (shared_root != null && digests_path != null && length(digests_path) > 0 && fs.lstat(digests_path)?.type == 'file') {
	try {
		const parsed = json(fs.readfile(digests_path));
		if (type(parsed) == 'object') precomputed = parsed;
	} catch (error) {}
}
const hash_cache = {};

export function create() {
	const adapter = openwrt();
	try { require('digest'); return adapter; } catch (error) {
		if (fs.readfile('/etc/openwrt_release') != null) die('OpenWrt digest dependency missing');
	}
	return { ...adapter, inspect_digest: (directory, files) => {
		if (!length(files)) return null;
		const resolved_prefix = shared_root != null ? `${shared_root}/` : null;
		const digests = [], large_indices = [], large_paths = [], large_contents = [];
		for (let i = 0; i < length(files); i++) {
			const path = files[i];
			const hit = resolved_prefix != null && index(path, resolved_prefix) == 0 ? precomputed[path] : null;
			if (hit != null) {
				push(digests, hit);
				continue;
			}
			const contents = fs.readfile(path);
			if (contents == null) return null;
			const text_key = index(contents, "\0") < 0;
			if (text_key && hash_cache[contents] != null) {
				push(digests, hash_cache[contents]);
			} else if (length(contents) <= 4096) {
				const sum = sha256_str(contents);
				if (text_key) hash_cache[contents] = sum;
				push(digests, sum);
			} else {
				push(large_indices, i);
				push(large_paths, path);
				push(large_contents, text_key ? contents : null);
				push(digests, null);
			}
		}
		if (length(large_paths) > 0) {
			const pipe = fs.popen(`sha256sum ${join(' ', map(large_paths, p => q(p)))} 2>/dev/null`);
			if (pipe == null) return null;
			const output = pipe.read('all'), status = pipe.close();
			if (status != 0 || type(output) != 'string') return null;
			const lines = filter(split(trim(output), '\n'), line => length(line) > 0);
			if (length(lines) != length(large_paths)) return null;
			for (let k = 0; k < length(large_paths); k++) {
				const value = substr(lines[k], 0, 64);
				if (!match(value, /^[a-f0-9]{64}$/)) return null;
				digests[large_indices[k]] = value;
				if (large_contents[k] != null) hash_cache[large_contents[k]] = value;
			}
		}
		let identities = '';
		for (let i = 0; i < length(files); i++)
			identities += `${digests[i]}  ${substr(files[i], length(directory) + 1)}\n`;
		if (hash_cache[identities] != null) return hash_cache[identities];
		const digest = sha256_str(identities);
		if (index(identities, "\0") < 0) hash_cache[identities] = digest;
		return digest;
	} };
};

export function stage_runtime(target) {
	const repo = fs.realpath(replace(sourcepath(), /[^/]+$/, '..'));
	const script = `rm -rf ${q(target)} && mkdir -p ${q(target)}/plugins && cp -R ${q(repo + '/openwrt/files/usr/libexec/opl-netfleet')}/. ${q(target)}/ && for p in ${q(repo + '/plugins')}/*; do [ -f "$p/manifest.json" ] || continue; cp -R "$p" ${q(target)}/plugins/; done && chmod -R u+rwX,go-w ${q(target)}`;
	if (system(script) != 0) die('stage_runtime_failed');
	return target;
};

export function remove_tree(target) {
	if (fs.lstat(target) != null && system(`rm -rf ${q(target)}`) != 0) die('remove_tree_failed');
};
