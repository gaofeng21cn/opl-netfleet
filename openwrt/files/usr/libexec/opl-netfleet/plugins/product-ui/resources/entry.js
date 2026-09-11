/* SPDX-License-Identifier: Apache-2.0 */

const reads = new Set(['status', 'events', 'connections', 'pluginsList', 'pluginRead', 'configGet', 'configValidate', 'networkGet', 'networkValidate', 'maintenanceGet', 'profileGet', 'backupExport', 'diagnosticsGet', 'dashboardGet', 'componentsGet', 'operationGet', 'nativeSetupGet', 'subscriptionsGet', 'migrationGet', 'onboardingGet']);
const names = ['api', 'product', 'advanced', 'managed', 'management', 'config', 'product-views', 'product-pages'];
let factories;

function loadFactories() {
  if (!factories) {
    const parameters = ['baseclass', 'ui', 'poll', 'rpc', 'fs', 'request', 'resourceUrl', 'netfleet', 'api', 'product', 'managed', 'management', 'netfleetConfig', 'advanced', 'productViews'];
    factories = Promise.all(names.map(async name => {
      const response = await fetch(new URL(name + '.js', import.meta.url));
      if (!response.ok) throw new Error('product_ui_resource_unavailable:' + name);
      return new Function(...parameters, await response.text());
    })).then(values => ({ parameters, values })).catch(error => { factories = null; throw error; });
  }
  return factories;
}

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
  const loaded = await loadFactories();
  if (context.signal.aborted) return;
  const bindings = { baseclass, ui, poll, rpc, fs, request, resourceUrl };
  // These installed LuCI modules share one revision and one page scope.
  for (let index = 0; index < names.length; index++) {
    const exported = loaded.values[index](...loaded.parameters.map(name => bindings[name]));
    let value = typeof exported === 'function' ? new exported() : exported;
    if (names[index] === 'api') { value = guard(value); bindings.netfleet = value; }
    bindings[names[index] === 'config' ? 'netfleetConfig' : names[index] === 'product-views' ? 'productViews' : names[index]] = value;
  }
  return bindings['product-pages'].mount(context, pageId);
}
