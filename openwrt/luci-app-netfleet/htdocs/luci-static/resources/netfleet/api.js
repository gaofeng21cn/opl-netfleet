/* SPDX-License-Identifier: MIT */

'use strict';
'require baseclass';
'require rpc';
'require fs';
'require request';

function declare(options) {
	// LuCI's batch queue waits for requestAnimationFrame, which pauses in background tabs.
	return rpc.declare(Object.assign({ nobatch: true }, options));
}

const calls = {
	networkGet: declare({ object: 'opl-netfleet', method: 'network_get' }),
	networkValidate: declare({ object: 'opl-netfleet', method: 'network_validate', params: [ 'request' ] }),
	networkApply: declare({ object: 'opl-netfleet', method: 'network_apply', params: [ 'request' ] }),
	maintenanceGet: declare({ object: 'opl-netfleet', method: 'maintenance_get' }),
	profileGet: declare({ object: 'opl-netfleet', method: 'profile_get', params: [ 'id' ] }),
	profileSave: declare({ object: 'opl-netfleet', method: 'profile_save', params: [ 'request' ] }),
	profileDelete: declare({ object: 'opl-netfleet', method: 'profile_delete', params: [ 'request' ] }),
	backupExport: declare({ object: 'opl-netfleet', method: 'backup_export' }),
	backupRestore: declare({ object: 'opl-netfleet', method: 'backup_restore', params: [ 'request' ] }),
	coreAction: declare({ object: 'opl-netfleet', method: 'core_action', params: [ 'request' ] }),
	diagnosticsGet: declare({ object: 'opl-netfleet', method: 'diagnostics_get' }),
	dashboardCheck: declare({ object: 'opl-netfleet', method: 'dashboard_check' }),
	dashboardUpdate: declare({ object: 'opl-netfleet', method: 'dashboard_update', params: [ 'version' ] }),
	componentsGet: declare({ object: 'opl-netfleet', method: 'components_get' }),
	componentsCheck: declare({ object: 'opl-netfleet', method: 'components_check' }),
	componentsUpdate: declare({ object: 'opl-netfleet', method: 'components_update', params: [ 'component', 'version' ] }),
	operationGet: declare({ object: 'opl-netfleet', method: 'operation_get' }),
	nativeSetupGet: declare({ object: 'opl-netfleet', method: 'native_setup_get' }),
	nativeSetupApply: declare({ object: 'opl-netfleet', method: 'native_setup_apply', params: [ 'request' ] }),
	dashboardGet: declare({ object: 'opl-netfleet', method: 'dashboard_get' }),
	subscriptionsGet: declare({ object: 'opl-netfleet', method: 'subscriptions_get' }),
	subscriptionsSet: declare({ object: 'opl-netfleet', method: 'subscriptions_set', params: [ 'request' ] }),
	subscriptionsRefresh: declare({ object: 'opl-netfleet', method: 'subscriptions_refresh', params: [ 'id' ] }),
	migrationGet: declare({ object: 'opl-netfleet', method: 'migration_get' }),
	migrationApply: declare({ object: 'opl-netfleet', method: 'migration_apply', params: [ 'request' ] }),
	onboardingGet: declare({ object: 'opl-netfleet', method: 'onboarding_get' }),
	onboardingApply: declare({ object: 'opl-netfleet', method: 'onboarding_apply', params: [ 'request' ] }),
	status: declare({ object: 'opl-netfleet', method: 'status' }),
	events: declare({ object: 'opl-netfleet', method: 'events' }),
	connections: declare({ object: 'opl-netfleet', method: 'connections' }),
	configGet: declare({ object: 'opl-netfleet', method: 'config_get' }),
	configValidate: declare({ object: 'opl-netfleet', method: 'config_validate', params: [ 'request' ] }),
	configSave: declare({ object: 'opl-netfleet', method: 'config_save', params: [ 'request' ] }),
	configApply: declare({ object: 'opl-netfleet', method: 'config_apply', params: [ 'request' ] }),
	enable: declare({ object: 'opl-netfleet', method: 'enable' }),
	selectAuto: declare({ object: 'opl-netfleet', method: 'select_auto', params: [ 'capability' ] }),
	refresh: declare({ object: 'opl-netfleet', method: 'refresh' }),
	disable: declare({ object: 'opl-netfleet', method: 'disable' })
};

function execute(method) {
	return calls[method]().then(function(response) {
		if (!response || response.ok !== true)
			throw new Error(response?.error || 'operation_failed');
		return response.result;
	}, function(error) {
		throw annotateRpcError(error);
	});
}

function executeRequest(method, request) {
	return calls[method](request).then(function(response) {
		if (!response || response.ok !== true) {
			const error = new Error(response?.error || 'operation_failed');
			error.detail = response?.detail || response?.result || null;
			if (response?.rollback) error.detail = Object.assign({}, error.detail, { rollback: response.rollback });
			throw error;
		}
		return response.result;
	}, function(error) {
		throw annotateRpcError(error);
	});
}

function annotateRpcError(error) {
	if (error && /XHR request aborted by browser/i.test(String(error.message || error)))
		error.netfleetKind = 'request_aborted';
	return error;
}

function withRpcTimeout(seconds, callback) {
	const previous = L.env.rpctimeout;
	L.env.rpctimeout = Math.max(Number(previous) || 20, seconds);
	return Promise.resolve().then(callback).then(function(result) {
		L.env.rpctimeout = previous;
		return result;
	}, function(error) {
		L.env.rpctimeout = previous;
		throw annotateRpcError(error);
	});
}

function transferRead(action, id) {
	return fs.exec_direct('/usr/libexec/opl-netfleet-transfer', id ? [action, id] : [action], 'json').then(function(response) {
		if (!response || response.ok !== true) throw new Error(response?.error || 'transfer_failed');
		return response.result;
	});
}

function transferWrite(method, value) {
	const bytes = new Uint8Array(16);
	window.crypto.getRandomValues(bytes);
	const id = Array.from(bytes).map(function(value) { return value.toString(16).padStart(2, '0'); }).join('');
	const form = new FormData();
	form.append('sessionid', rpc.getSessionID());
	form.append('filename', '/tmp/opl-netfleet-upload.' + id + '.json');
	form.append('filedata', new Blob([JSON.stringify({ request: value })], { type: 'application/json' }), 'request.json');
	return request.post(L.env.cgi_base + '/cgi-upload', form).then(function(response) {
		const result = response.json();
		if (!response.ok || result.error) throw new Error('transfer_upload_failed');
		return executeRequest(method, { upload_id: id });
	});
}

return baseclass.extend({
	networkGet: function() { return execute('networkGet'); },
	networkValidate: function(request) { return withRpcTimeout(60, function() { return executeRequest('networkValidate', request); }); },
	networkApply: function(request) { return withRpcTimeout(300, function() { return executeRequest('networkApply', request); }); },
	maintenanceGet: function() { return execute('maintenanceGet'); },
	profileGet: function(id) { return transferRead('profile-get', id); },
	profileSave: function(request) { return withRpcTimeout(60, function() { return transferWrite('profileSave', request); }); },
	profileDelete: function(request) { return executeRequest('profileDelete', request); },
	backupExport: function() { return transferRead('backup-export'); },
	backupRestore: function(request) { return withRpcTimeout(300, function() { return transferWrite('backupRestore', request); }); },
	coreAction: function(request) { return withRpcTimeout(300, function() { return executeRequest('coreAction', request); }); },
	diagnosticsGet: function() { return execute('diagnosticsGet'); },
	dashboardCheck: function() { return withRpcTimeout(60, function() { return execute('dashboardCheck'); }); },
	dashboardUpdate: function(version) { return withRpcTimeout(180, function() { return executeRequest('dashboardUpdate', version); }); },
	componentsGet: function() { return execute('componentsGet'); },
	componentsCheck: function() { return execute('componentsCheck'); },
	componentsUpdate: function(component, version) {
		return calls.componentsUpdate(component, version).then(function(response) {
			if (!response || response.ok !== true) throw new Error(response?.error || 'operation_failed');
			return response.result;
		});
	},
	operationGet: function() { return execute('operationGet'); },
	nativeSetupGet: function() { return execute('nativeSetupGet'); },
	nativeSetupApply: function(request) {
		return withRpcTimeout(300, function() { return executeRequest('nativeSetupApply', request); });
	},
	dashboardGet: function() { return execute('dashboardGet'); },
	subscriptionsGet: function() { return execute('subscriptionsGet'); },
	subscriptionsSet: function(request) {
		return withRpcTimeout(300, function() { return executeRequest('subscriptionsSet', request); });
	},
	subscriptionsRefresh: function(id) {
		return withRpcTimeout(300, function() { return executeRequest('subscriptionsRefresh', id); });
	},
	migrationGet: function() { return execute('migrationGet'); },
	migrationApply: function(request) {
		return withRpcTimeout(300, function() { return executeRequest('migrationApply', request); });
	},
	onboardingGet: function() { return execute('onboardingGet'); },
	onboardingApply: function(request) {
		return withRpcTimeout(300, function() { return executeRequest('onboardingApply', request); });
	},
	status: function() { return execute('status'); },
	events: function() { return execute('events'); },
	connections: function() { return execute('connections'); },
	configGet: function() { return execute('configGet'); },
	configValidate: function(request) { return executeRequest('configValidate', request); },
	configSave: function(request) {
		return withRpcTimeout(35, function() { return executeRequest('configSave', request); });
	},
	configApply: function(request) {
		return withRpcTimeout(300, function() { return executeRequest('configApply', request); });
	},
	enable: function() {
		return withRpcTimeout(300, function() { return execute('enable'); });
	},
	selectAuto: function(capability) {
		return withRpcTimeout(300, function() { return calls.selectAuto(capability).then(function(response) {
			if (!response || response.ok !== true)
				throw new Error(response?.error || 'operation_failed');
			return response.result;
		}); });
	},
	refresh: function() {
		return withRpcTimeout(300, function() { return execute('refresh'); });
	},
	disable: function() {
		return withRpcTimeout(35, function() { return execute('disable'); });
	}
});
