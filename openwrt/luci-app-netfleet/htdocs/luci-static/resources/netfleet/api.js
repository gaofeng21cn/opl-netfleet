/* SPDX-License-Identifier: Apache-2.0 */
'use strict';
'require baseclass';
'require rpc';

const list = rpc.declare({ object: 'opl-netfleet.plugins', method: 'plugins_list', nobatch: true });
const read = rpc.declare({ object: 'opl-netfleet.plugins', method: 'plugin_read', params: ['request'], nobatch: true });
const call = rpc.declare({ object: 'opl-netfleet.plugins', method: 'plugin_call', params: ['request'], nobatch: true });

function execute(operation, request, timeout) {
  const previous = L.env.rpctimeout;
  L.env.rpctimeout = Math.max(Number(previous) || 20, timeout);
  return Promise.resolve().then(function() { return request === undefined ? operation() : operation(request); }).then(function(response) {
    if (!response || response.ok !== true) {
      const error = new Error(response?.error || 'plugin_operation_failed');
      error.detail = response?.detail || response?.result || null;
      throw error;
    }
    return response.result;
  }).catch(function(error) {
    if (error && /XHR request aborted by browser/i.test(String(error.message || error))) error.netfleetKind = 'request_aborted';
    throw error;
  }).finally(function() { L.env.rpctimeout = previous; });
}

return baseclass.extend({
  pluginsList: function() { return execute(list, undefined, 20); },
  pluginRead: function(request) { return execute(read, request, 70); },
  pluginCall: function(request) { return execute(call, request, 200); }
});
