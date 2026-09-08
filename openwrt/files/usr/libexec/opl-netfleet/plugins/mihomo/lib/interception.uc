import * as fs from 'fs';

return function(context) {
	const gateway = context.use('mihomo.gateway');
	const files = context.use('platform.files');
	const quote = context.use('platform.process').shell_quote;
	function request(owner, input) {
		if (type(owner) != 'object' || !match(owner.service ?? '', /^[a-z][a-z0-9-]{0,47}$/) ||
			!match(owner.instance ?? '', /^[a-z][a-z0-9-]{0,47}$/)) return { ok: false, error: 'lease_owner_invalid' };
		const directory = fs.mkdtemp('/tmp/netfleet-interception.XXXXXX');
		if (directory == null) return { ok: false, error: 'lease_request_unavailable' };
		const path = `${directory}/request.json`;
		let result;
		try {
			const network = index(['snapshot', 'prepare', 'renew'], input?.action) >= 0 ? gateway.interception_snapshot(owner).result : {};
			if (!fs.chmod(directory, 0700) || !files.atomic_json(path, { owner, request: input, network }))
				result = { ok: false, error: 'lease_request_unavailable' };
			else {
				const script = `${context.root}/plugins/${context.id}/resources/interception.py`;
				const pipe = fs.popen(`timeout -k 1 2 /usr/bin/python3 ${quote(script)} ${quote(path)} 2>/dev/null`);
				if (pipe == null) result = { ok: false, error: 'lease_owner_unavailable' };
				else {
					const raw = pipe.read('all'), status = pipe.close();
					result = status == 124 || status == 137 ? { ok: false, error: 'lease_owner_timeout' } : json(raw);
				}
			}
		} catch (error) { result = { ok: false, error: 'lease_owner_unavailable' }; }
		fs.unlink(path); fs.rmdir(directory);
		return result;
	};
	return { request };
};
