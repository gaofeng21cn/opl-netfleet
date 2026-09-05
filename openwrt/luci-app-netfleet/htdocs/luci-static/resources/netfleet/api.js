/* SPDX-License-Identifier: MIT */

'use strict';
'require baseclass';
'require rpc';

const calls = {
	nativeSetupGet: rpc.declare({ object: 'opl-netfleet', method: 'native_setup_get' }),
	nativeSetupApply: rpc.declare({ object: 'opl-netfleet', method: 'native_setup_apply', params: [ 'request' ] }),
	dashboardGet: rpc.declare({ object: 'opl-netfleet', method: 'dashboard_get' }),
	subscriptionsGet: rpc.declare({ object: 'opl-netfleet', method: 'subscriptions_get' }),
	subscriptionsSet: rpc.declare({ object: 'opl-netfleet', method: 'subscriptions_set', params: [ 'request' ] }),
	subscriptionsRefresh: rpc.declare({ object: 'opl-netfleet', method: 'subscriptions_refresh', params: [ 'id' ] }),
	migrationGet: rpc.declare({ object: 'opl-netfleet', method: 'migration_get' }),
	migrationApply: rpc.declare({ object: 'opl-netfleet', method: 'migration_apply', params: [ 'request' ] }),
	onboardingGet: rpc.declare({ object: 'opl-netfleet', method: 'onboarding_get' }),
	onboardingApply: rpc.declare({ object: 'opl-netfleet', method: 'onboarding_apply', params: [ 'request' ] }),
	status: rpc.declare({ object: 'opl-netfleet', method: 'status' }),
	events: rpc.declare({ object: 'opl-netfleet', method: 'events' }),
	connections: rpc.declare({ object: 'opl-netfleet', method: 'connections' }),
	configGet: rpc.declare({ object: 'opl-netfleet', method: 'config_get' }),
	configValidate: rpc.declare({ object: 'opl-netfleet', method: 'config_validate', params: [ 'request' ] }),
	configSave: rpc.declare({ object: 'opl-netfleet', method: 'config_save', params: [ 'request' ] }),
	configApply: rpc.declare({ object: 'opl-netfleet', method: 'config_apply', params: [ 'request' ] }),
	enable: rpc.declare({ object: 'opl-netfleet', method: 'enable' }),
	selectAuto: rpc.declare({ object: 'opl-netfleet', method: 'select_auto', params: [ 'capability' ] }),
	refresh: rpc.declare({ object: 'opl-netfleet', method: 'refresh' }),
	disable: rpc.declare({ object: 'opl-netfleet', method: 'disable' })
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

return baseclass.extend({
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
