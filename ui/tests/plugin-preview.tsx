import { createRoot } from 'react-dom/client';
import { PluginApplication, type PluginClient } from '../src/plugins/PluginApplication';
import type { PluginsSnapshot } from '../../openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet/plugin-host.js';
import '../src/styles.css';

let catalog: PluginsSnapshot = { plugins: [
  { id: 'workspace-note', revision: 'revision-1', enabled: true, configuration: { read: 'configuration_get', write: 'configuration_set' }, ui: [{ id: 'note', title: 'Workspace note', module: 'resources/page.js' }] },
  { id: 'module-probe', revision: 'revision-1', enabled: true, ui: [{ id: 'graph', title: 'Module graph', module: 'resources/page.js' }] },
] };
let note = { title: 'Workspace note', text: 'Shared plugin configuration', generation: 1 };
const requests: unknown[] = [];
const client: PluginClient = {
  async pluginsList() { return structuredClone(catalog); },
  async pluginRead(request) { requests.push(request); return structuredClone(note); },
  async pluginCall(request) {
    requests.push(request);
    if (request.confirm !== true || request.revision !== catalog.plugins.find(plugin => plugin.id === request.id)?.revision) throw new Error('revision_conflict');
    if (request.params.generation !== note.generation) throw new Error('configuration_conflict');
    note = { title: String(request.params.title), text: String(request.params.text), generation: note.generation + 1 };
    return structuredClone(note);
  },
};
const root = createRoot(document.getElementById('root')!);
const render = (readOnly = false) => root.render(<PluginApplication client={client} readOnly={readOnly} />);
Object.assign(window, { __netfleetPluginFixture: {
  requests,
  catalog: () => structuredClone(catalog),
  externalChange(text: string) { note = { ...note, text, generation: note.generation + 1 }; },
  revision(id: string, revision: string) { catalog = { plugins: catalog.plugins.map(plugin => plugin.id === id ? { ...plugin, revision } : plugin) }; },
  remove(id: string) { catalog = { plugins: catalog.plugins.filter(plugin => plugin.id !== id) }; },
  readOnly(value: boolean) { render(value); },
} });
render(new URLSearchParams(location.search).has('readonly'));
