/* SPDX-License-Identifier: Apache-2.0 */

const reads = new Set(['status', 'events', 'connections', 'pluginsList', 'pluginRead', 'configGet', 'configValidate', 'networkGet', 'networkValidate', 'maintenanceGet', 'profileGet', 'backupExport', 'diagnosticsGet', 'dashboardGet', 'componentsGet', 'operationGet', 'nativeSetupGet', 'subscriptionsGet', 'migrationGet', 'onboardingGet', 'compatibilityGet', 'compatibilityCa']);

export async function mountPage(context, pageId) {
  const resourceUrl = name => new URL(name, import.meta.url).href;
  const [baseclass, ui, poll, rpc, fs, request] = await Promise.all(['baseclass', 'ui', 'poll', 'rpc', 'fs', 'request'].map(name => L.require(name)));
  if (context.signal.aborted) return;
  const guard = transport => new Proxy(transport, { get(target, name) {
    if (typeof target[name] !== 'function') return target[name];
    return function(...params) {
      if (context.signal.aborted) return Promise.reject(new Error('plugin_scope_disposed'));
      if (context.readOnly && !reads.has(name)) return Promise.reject(new Error('plugin_read_only'));
      return target[name](...params);
    };
  } });
  const names = ['api', 'product', 'managed', 'compatibility', 'management', 'config', 'product-pages'];
  const sources = await Promise.all(names.map(async name => {
    const response = await fetch(resourceUrl(name + '.js'), { signal: context.signal, cache: 'no-store' });
    if (!response.ok) throw new Error('product_ui_resource_unavailable:' + name);
    return response.text();
  }));
  if (context.signal.aborted) return;
  const bindings = { baseclass, ui, poll, rpc, fs, request, resourceUrl };
  // These installed LuCI modules share one revision and one page scope.
  for (let index = 0; index < names.length; index++) {
    const exported = new Function(...Object.keys(bindings), sources[index])(...Object.values(bindings));
    let value = typeof exported === 'function' ? new exported() : exported;
    if (names[index] === 'api') { value = guard(value); bindings.netfleet = value; }
    bindings[names[index] === 'config' ? 'netfleetConfig' : names[index]] = value;
  }
  return bindings['product-pages'].mount(context, pageId);
}
