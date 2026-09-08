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
	return { command };
};
