// Shared host tests exercise the real OpenWrt digest when present. The pinned
// desktop contract runtime omits this OpenWrt-only module; inject a test-only
// reference implementation there, never a fallback in the shipped adapter.
import * as fs from 'fs';
import { create as openwrt } from '../openwrt/files/usr/libexec/opl-netfleet/adapters/openwrt.uc';
import { shell_quote as q } from '../openwrt/files/usr/libexec/opl-netfleet/kernel/io.uc';

export function create() {
	const adapter = openwrt();
	try { require('digest'); return adapter; } catch (error) {
		if (fs.readfile('/etc/openwrt_release') != null) die('OpenWrt digest dependency missing');
	}
	return { ...adapter, inspect_digest: (directory, files) => {
		if (!length(files)) return null;
		const pipe = fs.popen(`cd ${q(directory)} && sha256sum ${join(' ', map(files, path => q(substr(path, length(directory) + 1))))} 2>/dev/null`);
		if (pipe == null) return null;
		const identities = pipe.read('all'), status = pipe.close();
		if (status != 0 || type(identities) != 'string' || !length(identities)) return null;
		const digest = fs.popen(`printf '%s' ${q(identities)} | sha256sum`);
		if (digest == null) return null;
		const value = substr(trim(digest.read('all') ?? ''), 0, 64);
		return digest.close() == 0 && match(value, /^[a-f0-9]{64}$/) ? value : null;
	} };
};
