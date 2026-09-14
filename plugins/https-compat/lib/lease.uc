import * as fs from 'fs';

return function(context) {
	const gateway = context.use('mihomo.interception');
	const files = context.use('platform.files');
	const owner = { owner: context.id, service: 'opl-netfleet-compat', instance: 'engine', user: 'netfleet-compat' };
	function command(argv) {
		if (length(argv) != 2 || !files.private_file(argv[1]) || fs.lstat(argv[1]).size > 262144)
			return { ok: false, error: 'lease_private_request_required' };
		try { return gateway.request(owner, json(fs.readfile(argv[1]))); }
		catch (error) { return { ok: false, error: 'lease_request_invalid' }; }
	};
	function watch() {
		fs.stdout.write('{"ready":true}\n');
		fs.stdout.flush();
		for (let line = fs.stdin.read('line'); line != null; line = fs.stdin.read('line')) {
			if (length(line) > 262144) return { ok: false, error: 'lease_request_invalid' };
			let response;
			try { response = gateway.request(owner, json(line)); }
			catch (error) { response = { ok: false, error: 'lease_request_invalid' }; }
			if (!fs.stdout.write(sprintf('%J\n', response)) || !fs.stdout.flush()) break;
		}
		return { ok: true, result: { stopped: true } };
	};
	return { command, watch };
};
