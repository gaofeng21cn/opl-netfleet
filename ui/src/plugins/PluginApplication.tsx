import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AlertCircle, LockKeyhole, Network, Puzzle, RefreshCw } from 'lucide-react';
import { createPageHost, pageHash, pageFromHash, pluginPages, pluginNavigation, pluginHostStyles, resourceUrl, type PluginApi, type PluginPage, type PluginsSnapshot } from '../../../openwrt/luci-app-netfleet/htdocs/luci-static/resources/netfleet/plugin-host.js';

export interface PluginClient extends PluginApi { pluginsList(): Promise<PluginsSnapshot> }

function PluginPageView({ page, client, readOnly, onNavigate, state }: { page: PluginPage; client: PluginClient; readOnly: boolean; onNavigate(id: string, state?: Record<string, unknown>): void; state?: Record<string, unknown> }) {
  const container = useRef<HTMLDivElement>(null);
  const [error, setError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  const host = useMemo(() => createPageHost({ api: client, readOnly, navigate: onNavigate, onError: reason => setError(reason instanceof Error ? reason.message : String(reason)) }), [client, onNavigate, readOnly]);
  const key = resourceUrl(page);
  useEffect(() => {
    setError(null);
    if (container.current) void host.show(page, container.current, state);
    return () => { void host.dispose(); };
  }, [host, key, attempt, page.plugin.instance, state]);
  return <>
    {error && <div className="nf-alert" role="alert"><AlertCircle aria-hidden="true" /><span>{error}</span><button type="button" onClick={() => setAttempt(value => value + 1)}>重试</button></div>}
    <div ref={container} className="nf-plugin-page" aria-label={page.title} />
  </>;
}

export function PluginApplication({ client, readOnly = false, initialPlugins }: { client: PluginClient; readOnly?: boolean; initialPlugins?: PluginsSnapshot }) {
  const [snapshot, setSnapshot] = useState<PluginsSnapshot>(initialPlugins || { plugins: [] });
  const [selection, setSelection] = useState<{ id: string; state?: Record<string, unknown> } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(!initialPlugins);
  const reading = useRef(false);
  const pages = useMemo(() => pluginPages(snapshot), [snapshot]);
  const model = useMemo(() => pluginNavigation(pages), [pages]);
  const current = selection?.id === 'plugins' || pages.some(page => page.id === selection?.id) ? selection!.id : model.defaultId;
  const selected = pages.find(page => page.id === current);
  const group = model.groups.find(value => value.pages.some(page => page.id === current));
  const navigate = useCallback((id: string, state?: Record<string, unknown>) => {
    const target = id === 'plugins' ? model.directoryId : id;
    setSelection({ id: target, state });
    if (typeof window !== 'undefined' && window.location.hash !== pageHash(target)) window.location.hash = pageHash(target);
  }, [model.directoryId]);
  useEffect(() => {
    const follow = () => setSelection(previous => {
      const id = pageFromHash(window.location.hash, pages);
      return previous?.id === id ? previous : { id };
    });
    follow(); window.addEventListener('hashchange', follow);
    return () => window.removeEventListener('hashchange', follow);
  }, [pages]);
  const refresh = useCallback(async () => {
    if (reading.current) return;
    reading.current = true;
    setLoading(true);
    try {
      const next = await client.pluginsList();
      setSnapshot(previous => JSON.stringify(previous) === JSON.stringify(next) ? previous : next);
      setError(null);
    } catch (reason) { setError(reason instanceof Error ? reason.message : '插件清单读取失败'); }
    finally { reading.current = false; setLoading(false); }
  }, [client]);
  useEffect(() => {
    void refresh();
    const timer = setInterval(() => void refresh(), 5000);
    return () => clearInterval(timer);
  }, [refresh]);
  const navigation = <>{model.primary.map(page => <button className={selected?.id === page.id || group && page.id === model.directoryId ? 'is-active' : ''} type="button" key={page.id} onClick={() => navigate(page.id)}><Puzzle aria-hidden="true" /><span>{page.title}</span></button>)}{model.directoryId === 'plugins' && <button type="button" className={!selected || group ? 'is-active' : ''} onClick={() => navigate('plugins')}><Puzzle aria-hidden="true" /><span>插件</span></button>}</>;
  return <div className="nf-app"><style>{pluginHostStyles}</style>
    <aside className="nf-sidebar"><div className="nf-brand"><Network aria-hidden="true" /><span><strong>OPL</strong> NetFleet</span></div><nav className="nf-nav" aria-label="NetFleet 导航">{navigation}</nav></aside>
    <div className="nf-stage"><header className="nf-toolbar"><span /><div className="nf-toolbar-actions">{readOnly && <span className="nf-readonly-badge"><LockKeyhole aria-hidden="true" />只读</span>}<button type="button" title="刷新插件" disabled={loading} onClick={() => void refresh()}><RefreshCw aria-hidden="true" className={loading ? 'is-spinning' : ''} /><span>刷新</span></button></div></header>
      <main className="nf-main"><div className="nf-page-heading"><h1>{selected?.title || '插件'}</h1></div>
        {error && <div className="nf-alert" role="alert"><AlertCircle aria-hidden="true" /><span>{error}</span></div>}
        {group && <nav className="netfleet-plugin-subnav" aria-label="插件页面"><button type="button" onClick={() => navigate(model.directoryId)}>{model.directoryId === 'plugins' ? '← 插件' : '← 插件与更新'}</button>{group.pages.map(page => <button type="button" key={page.id} aria-current={page.id === current ? 'page' : undefined} onClick={() => navigate(page.id)}>{page.title}</button>)}</nav>}
        {selected ? <PluginPageView key={selected.id} page={selected} client={client} readOnly={readOnly || !!error} onNavigate={navigate} state={selection?.id === selected.id ? selection.state : undefined} /> : <div className="nf-plugin-directory"><p>选择插件打开配置页面。</p>{model.groups.map(group => <section key={group.id}><h2>{group.title}{group.instance && group.instance !== 'default' ? ` · ${group.instance}` : ''}</h2>{group.pages.map(page => <button type="button" key={page.id} onClick={() => navigate(page.id)}>{page.title}</button>)}</section>)}{!model.groups.length && <p role="status">{loading ? '正在读取插件…' : '暂无已启用的插件配置页'}</p>}</div>}
      </main>
    </div>
    <nav className="nf-mobile-nav nf-plugin-mobile-nav" aria-label="NetFleet 移动导航">{navigation}</nav>
  </div>;
}
