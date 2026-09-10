import { useEffect, useRef, useState } from 'react';
import { ConfirmDialog } from '../components/ConfirmDialog';
import type { ConnectionsSnapshot } from '../types';
import type { DesktopSnapshot } from './types';
import type { DesktopNetFleetClient } from './client';

export type RunAction = (label: string, work: () => Promise<unknown>) => Promise<boolean>;
const failure = (error: unknown) => error instanceof Error ? error.message : String(error);
export const modeNames = { direct: '原生直连', mihomo: 'Mihomo 原生代理', netfleet: 'NetFleet 增强代理' };
export const networkNames = { explicit: '显式代理', system: '系统代理', tun: 'TUN 接管' };
const parseObject = (text: string) => { const value: unknown = JSON.parse(text); if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('请提供 JSON 对象。'); return value as Record<string, unknown>; };

function DesktopFilePicker({ label, accept, disabled, onFile }: { label: string; accept: string; disabled?: boolean; onFile(file: File): void }) {
  const input = useRef<HTMLInputElement>(null);
  const [name, setName] = useState('未选择文件');
  return <div className="nf-desktop-file-picker"><input ref={input} type="file" hidden accept={accept} disabled={disabled} onChange={event => { const file = event.target.files?.[0]; event.target.value = ''; if (file) { setName(file.name); onFile(file); } }} /><button type="button" className="nf-button-secondary" disabled={disabled} onClick={() => input.current?.click()}>{label}</button><span title={name}>{name}</span></div>;
}

export function RuntimeControls({ snapshot, disabled, client, run }: { snapshot: DesktopSnapshot; disabled: boolean; client: DesktopNetFleetClient; run: RunAction }) {
  const [network, setNetwork] = useState(snapshot.runtime.networkMode);
  const [confirmNetwork, setConfirmNetwork] = useState(false);
  const [showNative, setShowNative] = useState(false);
  useEffect(() => setNetwork(snapshot.runtime.networkMode), [snapshot.runtime.networkMode]);
  const runtime = snapshot.runtime;
  const connected = runtime.running && runtime.mode === 'netfleet';
  const descriptions = { explicit: '仅供明确指定代理的应用使用，不修改系统网络。', system: '让浏览器等遵循 macOS 系统代理的应用使用 NetFleet。', tun: '通过虚拟网卡接入流量，适合不遵循系统代理的应用。' };
  const applyNetwork = () => run('应用网络接入', () => client.action('network', { mode: network, authorize: true }));
  const networkState = runtime.networkMode === 'explicit' ? '未接管系统流量' : snapshot.network.ready ? `${networkNames[runtime.networkMode]}已生效` : `${networkNames[runtime.networkMode]}尚未生效`;
  return <>
    <section className="nf-desktop-connection" aria-label="连接控制">
      <div className="nf-desktop-connection-main"><div><span className="nf-desktop-eyebrow">代理连接</span><h2>{runtime.mode === 'unconfirmed' ? '状态待确认' : runtime.running ? connected ? 'NetFleet 已连接' : '原生代理运行中' : '代理已停止'}</h2><p>{runtime.running ? `127.0.0.1:${runtime.ports.mixed} · HTTP / SOCKS5` : runtime.configured ? '配置已就绪，可启动代理。' : '添加机场订阅后可启动。'}</p></div><div className="nf-desktop-connection-actions">{runtime.running ? <><button className="nf-button-secondary" disabled={disabled} onClick={() => void run('停止代理', () => client.action('mode', { mode: 'direct' }))}>停止代理</button>{!connected && <button className="nf-button-primary" disabled={disabled} onClick={() => void run('启动 NetFleet', () => client.enable())}>启用 NetFleet</button>}</> : <button className="nf-button-primary" disabled={disabled || runtime.clean && !runtime.configured} onClick={() => void run(runtime.clean ? '启动 NetFleet' : '恢复直连', () => runtime.clean ? client.enable() : client.action('mode', { mode: 'direct' }))}>{runtime.clean ? '启动 NetFleet' : '恢复直连'}</button>}</div></div>
      <fieldset className="nf-desktop-access" disabled={disabled}><legend className="nf-visually-hidden">本机流量接入</legend><div className="nf-desktop-access-row"><label htmlFor="desktop-network-mode">流量接入</label><select id="desktop-network-mode" value={network} onChange={event => setNetwork(event.target.value as typeof network)}>{(Object.keys(networkNames) as Array<keyof typeof networkNames>).map(value => <option value={value} key={value}>{value === 'explicit' ? '仅显式代理' : networkNames[value]}</option>)}</select><span className="nf-desktop-access-state">{network !== runtime.networkMode ? '尚未应用' : networkState}</span><button className="nf-button-secondary" disabled={network === runtime.networkMode} onClick={() => { if (network === 'explicit') void applyNetwork(); else setConfirmNetwork(true); }}>应用</button></div><p className="nf-desktop-access-help">{descriptions[network]}{network !== 'explicit' && snapshot.network.helper === 'needs-install' ? ' 首次使用需管理员授权。' : ''}</p></fieldset>
      <div className="nf-desktop-connection-foot"><span>{runtime.networkMode === 'explicit' ? '系统代理与 TUN 均未开启' : networkState}</span><button type="button" onClick={() => setShowNative(true)} disabled={disabled || !runtime.configured || runtime.mode === 'mihomo'}>原生配置模式…</button></div>
    </section>
    {showNative && <ConfirmDialog title="使用原生配置" description="使用恢复配置自身的代理规则，暂停 NetFleet 自动选优。流量接入方式保持当前设置。" confirmLabel="使用原生配置" busy={disabled} onCancel={() => setShowNative(false)} onConfirm={() => { setShowNative(false); void run('使用原生配置', () => client.action('mode', { mode: 'mihomo', authorize: true })); }} />}
    {confirmNetwork && <ConfirmDialog title={`应用${networkNames[network]}`} description={`${descriptions[network]}${runtime.running ? '将重启当前代理以切换接入方式。' : '当前核心未运行，只保存接入选择，启动核心后才会接管流量。'}首次使用可能出现 macOS 管理员授权。`} confirmLabel="继续应用" busy={disabled} onCancel={() => setConfirmNetwork(false)} onConfirm={() => { setConfirmNetwork(false); void applyNetwork(); }} />}
  </>;
}

export function SubscriptionManager({ snapshot, disabled, client, run }: { snapshot: DesktopSnapshot; disabled: boolean; client: DesktopNetFleetClient; run: RunAction }) {
  const [editing, setEditing] = useState<string | null>(null);
  const [name, setName] = useState('');
  const [url, setUrl] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [remove, setRemove] = useState<string | null>(null);
  const subscriptions = snapshot.subscriptions;
  const locked = disabled || snapshot.runtime.running;
  const policyProviders = snapshot.policy?.providers as Record<string, { enabled?: boolean }> | undefined;
  const reset = () => { setEditing(null); setName(''); setUrl(''); setError(null); };
  return <section className="nf-config-section" aria-label="管理订阅">
    <div className="nf-section-heading"><div><h2>机场订阅</h2><p>订阅提供节点，NetFleet 内置策略负责分流。添加后自动下载、识别地区并编译。</p></div><button className="nf-button-secondary" disabled={disabled || !Object.values(subscriptions).some(item => item.hasUrl && item.enabled)} onClick={() => void run('更新订阅', () => client.refresh())}>更新订阅</button></div>
    {error && <p className="nf-inline-warning" role="alert">{error}</p>}
    {snapshot.runtime.running && <div className="nf-desktop-inline-note"><span>日常更新可直接执行。增删或修改来源前需停止代理，已有配置会保留。</span><button className="nf-button-secondary" disabled={disabled} onClick={() => void run('停止代理以编辑来源', () => client.action('mode', { mode: 'direct' }))}>停止并编辑</button></div>}
    <div className="nf-table-wrap"><table><thead><tr><th>订阅来源</th><th>准备状态</th><th>操作</th></tr></thead><tbody>{Object.entries(subscriptions).map(([key, item]) => <tr key={key}><td>{item.name || key}<small>{item.imported && !item.hasUrl ? '本地导入 · 不会自动下载' : item.nodeCount != null ? `${item.nodeCount} 条节点记录` : '尚未下载'}{item.updatedAt && ` · ${new Date(item.updatedAt).toLocaleString('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })} 更新`}</small></td><td>{item.enabled === false ? '已停用' : policyProviders?.[key] ? '已纳入业务配置' : '待准备'}<small>{item.hasUrl ? '地址已隐藏，仅保存在本机' : '仅保存在本机'}</small></td><td><div className="nf-desktop-inline">{item.hasUrl && <button className="nf-button-secondary" disabled={locked} onClick={() => { setEditing(key); setName(item.name); setUrl(''); setError(null); }}>{policyProviders?.[key] ? '编辑' : '继续准备'}</button>}<button className="nf-button-secondary" disabled={locked} onClick={() => void run('更新订阅状态', () => client.action('subscriptions-set', { subscriptions: { ...subscriptions, [key]: { ...item, enabled: item.enabled === false } } }))}>{item.enabled === false ? '启用' : '停用'}</button><button className="nf-button-secondary" disabled={locked} onClick={() => setRemove(key)}>移除</button></div></td></tr>)}{Object.keys(subscriptions).length === 0 && <tr><td colSpan={3}>尚无机场订阅。粘贴 Clash / Mihomo 订阅地址即可开始。</td></tr>}</tbody></table></div>
    <fieldset className="nf-desktop-fieldset" disabled={locked}><form className="nf-form-rows" onSubmit={event => {
      event.preventDefault(); setError(null);
      if (url.trim()) { try { const parsed = new URL(url.trim()); if (!['http:', 'https:'].includes(parsed.protocol) || parsed.username || parsed.password) throw new Error('请使用有效的 HTTP / HTTPS 订阅地址。'); } catch { setError('请使用有效的 HTTP / HTTPS 订阅地址。'); return; } }
      else if (!editing) { setError('请填写机场订阅地址。'); return; }
      const displayName = name.trim() || (url.trim() ? new URL(url.trim()).hostname : subscriptions[editing!]?.name);
      void run(editing ? '更新并准备订阅' : '添加并准备订阅', () => client.action('subscription-prepare', { ...(editing ? { id: editing } : {}), subscription: { name: displayName, ...(url.trim() ? { url: url.trim() } : {}) } })).then(ok => { if (ok) reset(); });
    }}><div className="nf-form-row"><label htmlFor="desktop-subscription-url">{editing ? '新的订阅地址' : '订阅地址'}<p>{editing ? '留空保留原地址，并重新下载准备。' : '支持完整 Clash / Mihomo 配置和节点列表。'}</p></label><input id="desktop-subscription-url" value={url} onChange={event => setUrl(event.target.value)} type="password" autoComplete="new-password" placeholder={editing ? '留空保留原地址' : 'https://…'} required={!editing} /></div><div className="nf-form-row"><label htmlFor="desktop-subscription-name">显示名称<p>选填，默认使用订阅域名。</p></label><input id="desktop-subscription-name" value={name} onChange={event => setName(event.target.value)} placeholder="例如：我的机场" /></div><div className="nf-desktop-actions"><button className="nf-button-primary" type="submit">{editing ? '保存并重新准备' : '添加并准备'}</button>{editing && <button className="nf-button-secondary" type="button" onClick={reset}>取消编辑</button>}<span className="nf-management-note">不会自动启动代理或开启系统接管。</span></div></form></fieldset>
    {remove && <ConfirmDialog title="移除订阅" description={`将移除“${subscriptions[remove]?.name}”及其地区资源。至少需要保留一个启用的机场。`} confirmLabel="移除订阅" busy={locked} onCancel={() => setRemove(null)} onConfirm={() => { const next = { ...subscriptions }; delete next[remove]; void run('移除订阅', () => client.action('subscriptions-set', { subscriptions: next })).then(ok => { if (ok) { setRemove(null); if (editing === remove) reset(); } }); }} />}
  </section>;
}

export function Configuration({ snapshot, disabled, client, run, section, onDirtyChange }: { snapshot: DesktopSnapshot; disabled: boolean; client: DesktopNetFleetClient; run: RunAction; section: 'profile' | 'advanced'; onDirtyChange?(dirty: boolean): void }) {
  const [profile, setProfile] = useState('');
  const [confirmBuiltin, setConfirmBuiltin] = useState(false);
  const builtin = (snapshot.policy?.policy_source as { kind?: string; ref?: string } | undefined)?.ref === 'bundle:base-v1';
  const [policy, setPolicy] = useState('');
  const [dirty, setDirty] = useState(false);
  useEffect(() => { onDirtyChange?.(dirty); }, [dirty, onDirtyChange]);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => { if (!dirty) setPolicy(snapshot.policy ? JSON.stringify(snapshot.policy, null, 2) : ''); }, [snapshot.policy, dirty]);
  const readProfile = async (file?: File) => { if (!file) return; try { if (file.size > 8 * 1024 * 1024) throw new Error('配置文件不能超过 8 MB。'); setProfile(await file.text()); setError(null); } catch (reason) { setError(failure(reason)); } };
  return <div className="nf-view-stack">
    {error && <p className="nf-inline-warning" role="alert">{error}</p>}
    <fieldset className="nf-desktop-fieldset" disabled={disabled}>
      {section === 'profile' && <section className="nf-config-section"><div className="nf-config-section-heading"><h2>策略与节点</h2><p>策略决定流量如何分配，机场订阅提供可用节点。</p></div><div className="nf-desktop-policy-card"><div className="nf-section-heading"><h2>{builtin ? 'NetFleet 内置策略' : snapshot.policy ? '自定义 Profile 策略' : 'NetFleet 内置策略 · 待准备'}</h2><span className="nf-desktop-state">{builtin ? '当前使用' : '默认推荐'}</span></div><p>海外加速承接常规海外流量，AI 出口独立选优；国内与私网流量直连。</p><div className="nf-desktop-policy-exits"><div><strong>海外加速</strong><small>按机场和地区自动选优</small></div><div><strong>AI 出口</strong><small>默认避开香港，优先沿用可用地区</small></div></div>{!builtin && snapshot.policy && <div className="nf-desktop-actions"><button className="nf-button-primary" disabled={snapshot.runtime.running} onClick={() => setConfirmBuiltin(true)}>使用内置策略</button><span className="nf-management-note">保留订阅、地区资源与恢复配置。</span></div>}{!snapshot.policy && <p className="nf-management-note">到“机场”添加订阅后自动准备，无需另行导入配置。</p>}{snapshot.runtime.running && !builtin && <p className="nf-management-note">停止代理后可切换策略。</p>}</div><details className="nf-desktop-import"><summary>导入自定义 Profile</summary><p className="nf-management-note">适合明确需要沿用现有规则的高级配置。导入会替换恢复配置并重新生成业务策略，需先停止代理。</p><div className="nf-desktop-editor"><DesktopFilePicker label="选择配置文件…" accept=".json,.yaml,.yml,text/plain,application/json" disabled={disabled} onFile={file => { void readProfile(file); }} /><label htmlFor="desktop-profile">Mihomo 配置</label><textarea id="desktop-profile" value={profile} onChange={event => setProfile(event.target.value)} spellCheck={false} placeholder="粘贴 Mihomo JSON / YAML 配置" /><div className="nf-desktop-actions"><button className="nf-button-primary" disabled={!profile.trim() || snapshot.runtime.running} onClick={() => { let value: unknown = profile; try { value = JSON.parse(profile); } catch { /* YAML is parsed by the runtime. */ } void run('导入基础配置', () => client.action('configure', { profile: value })).then(ok => { if (ok) { setProfile(''); setDirty(false); } }); }}>导入配置</button>{snapshot.runtime.running && <span className="nf-management-note">停止代理后可导入。</span>}</div></div></details></section>}
      {section === 'advanced' && <section className="nf-config-section"><div className="nf-config-section-heading"><h2>高级策略 JSON</h2><p>添加订阅默认使用内置策略；显式导入 Profile 时沿用其规则。常规修改使用配置表单；JSON 供完整策略检查和高级调整。</p></div><div className="nf-desktop-editor"><label htmlFor="desktop-policy">策略 JSON{dirty ? ' · 有未保存修改' : ''}</label><textarea id="desktop-policy" value={policy} onChange={event => { setPolicy(event.target.value); setDirty(true); }} spellCheck={false} placeholder="导入基础配置并编译后生成初始策略" /><div className="nf-desktop-actions"><button className="nf-button-secondary" onClick={() => { try { setPolicy(JSON.stringify(parseObject(policy), null, 2)); setError(null); } catch (reason) { setError(failure(reason)); } }}>格式化</button><button className="nf-button-primary" disabled={!dirty} onClick={() => { try { const value = parseObject(policy); setError(null); void run('保存业务策略', () => client.action('save-policy', { policy: value })).then(ok => { if (ok) setDirty(false); }); } catch (reason) { setError(failure(reason)); } }}>保存策略</button><button className="nf-button-secondary" disabled={!snapshot.runtime.configured || dirty} onClick={() => void run('校验并编译', () => client.action('compile'))}>校验并编译</button></div>{dirty && <p className="nf-management-note">先保存策略再编译；切换页面会保留未保存修改。</p>}</div></section>}
    </fieldset>
    {confirmBuiltin && <ConfirmDialog title="使用 NetFleet 内置策略" description="将替换当前策略来源、业务组绑定和出口定义，建立海外加速与 AI 双出口。订阅、地区资源、自动化设置、恢复配置及其他字段会保留；验证失败会保留原策略。" confirmLabel="切换并编译" busy={disabled} onCancel={() => setConfirmBuiltin(false)} onConfirm={() => { void run('使用内置策略', () => client.action('use-builtin-policy')).then(ok => { if (ok) setConfirmBuiltin(false); }); }} />}
  </div>;
}

export function LogsAndBackup({ snapshot, disabled, client, run }: { snapshot: DesktopSnapshot; disabled: boolean; client: DesktopNetFleetClient; run: RunAction }) {
  const [logs, setLogs] = useState<string | null>(null);
  const [connections, setConnections] = useState<ConnectionsSnapshot | null>(null);
  const [restore, setRestore] = useState<unknown>(null);
  const [error, setError] = useState<string | null>(null);
  const exportBackup = async () => {
    const backup = await client.exportBackup();
    const contents = JSON.stringify(backup, null, 2);
    const native = (window as Window & { webkit?: { messageHandlers?: { saveBackup?: { postMessage(value: { contents: string }): void } } } }).webkit?.messageHandlers?.saveBackup;
    if (native) native.postMessage({ contents });
    else { const url = URL.createObjectURL(new Blob([contents], { type: 'application/json' })); const link = document.createElement('a'); link.href = url; link.download = 'netfleet-backup.json'; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); }
  };
  return <>
    <section className="nf-table-section"><div className="nf-section-heading"><h2>当前连接</h2><button className="nf-button-secondary" disabled={disabled} onClick={() => void run('读取当前连接', async () => { setConnections(await client.connections()); })}>读取连接</button></div>{connections ? <><p className="nf-management-note">{connections.truncated ? '结果已截断，只显示本次返回的连接。' : `本次读取 ${connections.connections.length} 条活动连接。`}</p><div className="nf-table-wrap"><table><thead><tr><th>目标</th><th>网络</th><th>命中规则</th><th>实际链路</th></tr></thead><tbody>{connections.connections.map((item, index) => <tr key={index}><td>{item.destination}{item.destination_port ? `:${item.destination_port}` : ''}</td><td>{item.network || '未提供'}</td><td>{item.rule || '未提供'}</td><td>{item.chains.join(' → ') || '未提供'}</td></tr>)}{connections.connections.length === 0 && <tr><td colSpan={4}>当前没有活动连接。</td></tr>}</tbody></table></div></> : <p className="nf-empty">尚未读取当前连接。</p>}</section>
    <section className="nf-log-section"><div className="nf-section-heading"><h2>Mihomo 日志</h2><button className="nf-button-secondary" disabled={disabled} onClick={() => void run('读取日志', async () => { setLogs((await client.logs()).text); })}>读取日志</button></div><pre>{logs === null ? '尚未读取日志。' : logs || '当前没有日志。'}</pre></section>
    <section className="nf-config-section"><div className="nf-config-section-heading"><h2>配置备份</h2><p>包含私有配置与订阅，请保存到可信位置。恢复前必须停止当前代理。</p></div>{error && <p className="nf-inline-warning" role="alert">{error}</p>}<fieldset disabled={disabled} className="nf-desktop-fieldset"><div className="nf-desktop-actions"><button className="nf-button-secondary" disabled={!snapshot.runtime.configured} onClick={() => void run('导出备份', exportBackup)}>导出备份</button><DesktopFilePicker label="选择备份…" accept=".json,application/json" disabled={disabled || snapshot.runtime.running} onFile={file => { void file.text().then(text => { setRestore(parseObject(text)); setError(null); }).catch(reason => setError(failure(reason))); }} /></div></fieldset></section>
    {restore && <ConfirmDialog title="恢复本机备份" description="将替换当前本机基础配置、业务策略与机场订阅。" confirmLabel="恢复备份" busy={disabled} onCancel={() => setRestore(null)} onConfirm={() => { void run('恢复备份', () => client.action('backup-restore', { backup: restore })).then(() => setRestore(null)); }} />}
  </>;
}
