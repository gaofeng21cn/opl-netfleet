/* SPDX-License-Identifier: MIT */

'use strict';
'require baseclass';
'require rpc';

function declare(options) {
	// LuCI's batch queue waits for requestAnimationFrame, which pauses in background tabs.
	return rpc.declare(Object.assign({ nobatch: true }, options));
}

const calls = {
	compatibilityGet: declare({ object: 'opl-netfleet', method: 'compatibility_get' }),
	compatibilityCa: declare({ object: 'opl-netfleet', method: 'compatibility_ca' }),
	compatibilityApply: declare({ object: 'opl-netfleet', method: 'compatibility_apply', params: [ 'request' ] }),
	compatibilityEnable: declare({ object: 'opl-netfleet', method: 'compatibility_enable', params: [ 'request' ] }),
	compatibilityDisable: declare({ object: 'opl-netfleet', method: 'compatibility_disable', params: [ 'request' ] }),
	compatibilityProbe: declare({ object: 'opl-netfleet', method: 'compatibility_probe', params: [ 'request' ] }),
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
	compatibilityGet: function() { return execute('compatibilityGet'); },
	compatibilityCa: function() { return execute('compatibilityCa'); },
	compatibilityApply: function(request) { return executeRequest('compatibilityApply', request); },
	compatibilityEnable: function(request) { return executeRequest('compatibilityEnable', request); },
	compatibilityDisable: function(request) { return executeRequest('compatibilityDisable', request); },
	compatibilityProbe: function(request) { return executeRequest('compatibilityProbe', request); },
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
