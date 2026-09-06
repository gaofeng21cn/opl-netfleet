import { useEffect, useState } from 'react';
import { Check, Plus, RefreshCw, RotateCcw, Save, Trash2 } from 'lucide-react';
import type { DnsPolicy, NetFleetClient, NetworkSettings } from '../types';
import { useManagementRead } from './useManagementRead';

function TextList({ label, values, onChange, placeholder }: { label: string; values: string[]; onChange(values: string[]): void; placeholder?: string }) {
  const [text, setText] = useState(values.join('\n'));
  useEffect(() => setText(values.join('\n')), [values]);
  return <textarea aria-label={label} rows={Math.max(2, Math.min(5, values.length + 1))} value={text} placeholder={placeholder}
    onChange={event => setText(event.target.value)} onBlur={() => onChange(text.split('\n').map(value => value.trim()).filter(Boolean))} />;
}

function Toggle({ label, checked, onChange }: { label: string; checked: boolean; onChange(checked: boolean): void }) {
  return <label className="nf-switch"><input type="checkbox" aria-label={label} checked={checked} onChange={event => onChange(event.target.checked)} /><span aria-hidden="true" /><b>{checked ? '已开启' : '已关闭'}</b></label>;
}

function PolicyList({ title, policies, preserved, onChange }: { title: string; policies: DnsPolicy[]; preserved: number; onChange(policies: DnsPolicy[]): void }) {
  return <section className="nf-management-subsection">
    <div className="nf-section-heading"><h3>{title}</h3><button type="button" onClick={() => onChange([...policies, { domain: '', nameservers: [] }])}><Plus aria-hidden="true" />添加域名</button></div>
    <div className="nf-table-wrap nf-management-table"><table><thead><tr><th>精确域名</th><th>解析地址</th><th>操作</th></tr></thead><tbody>
      {policies.map((policy, index) => <tr key={index}>
        <td><input aria-label={`${title} 域名 ${index + 1}`} value={policy.domain} placeholder="example.com" onChange={event => onChange(policies.map((item, at) => at === index ? { ...item, domain: event.target.value } : item))} /></td>
        <td><TextList label={`${policy.domain || title} 解析地址`} values={policy.nameservers} onChange={nameservers => onChange(policies.map((item, at) => at === index ? { ...item, nameservers } : item))} /></td>
        <td><button className="nf-icon-button" type="button" title="移除解析规则" aria-label={`移除 ${policy.domain || '空白'} 解析规则`} onClick={() => onChange(policies.filter((_, at) => at !== index))}><Trash2 aria-hidden="true" /></button></td>
      </tr>)}
      {!policies.length && <tr><td colSpan={3}>未配置精确域名规则</td></tr>}
    </tbody></table></div>
    {preserved > 0 && <p className="nf-management-note">另有 {preserved} 条高级匹配规则，由当前配置保留。</p>}
  </section>;
}

export function NetworkSection({ client }: { client?: NetFleetClient }) {
  const { data, loading, error, refresh } = useManagementRead(client, 'network');
  const [draft, setDraft] = useState<NetworkSettings | null>(null);
  const [saved, setSaved] = useState<NetworkSettings | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  useEffect(() => {
    setDraft(data?.settings ? structuredClone(data.settings) : null);
    setSaved(data?.settings ? structuredClone(data.settings) : null);
    setMessage(null);
  }, [data]);
  const dirty = JSON.stringify(draft) !== JSON.stringify(saved);
  const change = (next: NetworkSettings) => { setDraft(next); setMessage(null); };
  const setDns = (update: Partial<NetworkSettings['dns']>) => draft && change({ ...draft, dns: { ...draft.dns, ...update } });

  return <section className="nf-config-section nf-management">
    <div className="nf-config-section-heading nf-section-heading"><div><h2>网络接入</h2><p>透明代理模式：TProxy</p></div><button type="button" disabled={loading || dirty || !client} onClick={() => void refresh()} title={dirty ? '请先应用本地预览或放弃更改' : '重新读取设备网络配置'}><RefreshCw aria-hidden="true" className={loading ? 'is-spinning' : ''} />重新读取</button></div>
    {error && <div className="nf-alert" role="alert">{error}</div>}
    {!data && <p className="nf-management-note">{loading ? '正在读取网络接入配置…' : '当前数据源未提供网络接入配置。'}</p>}
    {data && !data.available && <p className="nf-inline-warning">{data.reason === 'native_backend_required' ? '当前由 Nikki 管理网络接入；迁移到 NetFleet 原生后端后可在这里管理。' : '当前设备不支持网络接入管理。'}</p>}
    {data?.available && draft && <>
      {data.preview_redacted && <p className="nf-management-note">私有解析地址已隐藏路径和凭据；完整地址仅在设备 LuCI 中显示。</p>}
      <section className="nf-management-subsection"><h3>DNS 解析</h3><div className="nf-form-rows">
        {([
          ['nameservers', '默认上游', '未命中特例时使用'],
          ['default_nameservers', '引导解析', '用于解析上游服务的域名'],
          ['proxy_nameservers', '机场节点解析', '为空时沿用默认上游'],
          ['direct_nameservers', '直连解析', '为空时沿用默认上游'],
        ] as const).map(([key, label, hint]) => <div className="nf-form-row" key={key}><div><label>{label}</label><p>{hint}</p></div><TextList label={label} values={draft.dns[key]} onChange={values => setDns({ [key]: values })} /></div>)}
      </div></section>
      <PolicyList title="域名解析特例" policies={draft.dns.policies} preserved={data.resources?.preserved_dns_policy_count || 0} onChange={policies => setDns({ policies })} />
      <PolicyList title="机场域名解析特例" policies={draft.dns.proxy_policies} preserved={data.resources?.preserved_proxy_policy_count || 0} onChange={proxy_policies => setDns({ proxy_policies })} />
      <section className="nf-management-subsection"><h3>代理范围</h3><div className="nf-form-rows">
        <div className="nf-form-row"><div><label>局域网透明代理</label></div><Toggle label="局域网透明代理" checked={draft.lan.enabled} onChange={enabled => change({ ...draft, lan: { ...draft.lan, enabled } })} /></div>
        <div className="nf-form-row"><div><label>路由器本机代理</label></div><Toggle label="路由器本机代理" checked={draft.router.enabled} onChange={enabled => change({ ...draft, router: { enabled } })} /></div>
        <div className="nf-form-row"><div><label>接入接口</label></div><div className="nf-region-checks">{Array.from(new Set([...draft.lan.interfaces, ...(data.resources?.interfaces || []).map(item => item.name)])).map(name => <label key={name}><input type="checkbox" checked={draft.lan.interfaces.includes(name)} onChange={event => change({ ...draft, lan: { ...draft.lan, interfaces: event.target.checked ? [...draft.lan.interfaces, name] : draft.lan.interfaces.filter(item => item !== name) } })} />{name}</label>)}</div></div>
      </div></section>
      <section className="nf-management-subsection"><div className="nf-section-heading"><h3>设备访问规则</h3><button type="button" onClick={() => change({ ...draft, lan: { ...draft.lan, rules: [...draft.lan.rules, { id: `preview-${Date.now()}`, enabled: false, ipv4: [], ipv6: [], mac: [], proxy: true, dns: true }] } })}><Plus aria-hidden="true" />添加设备</button></div>
        <div className="nf-table-wrap nf-management-table"><table><thead><tr><th>启用</th><th>设备地址</th><th>代理</th><th>DNS 接管</th><th>操作</th></tr></thead><tbody>
          {draft.lan.rules.map((rule, index) => {
            const changeRule = (update: Partial<typeof rule>) => change({ ...draft, lan: { ...draft.lan, rules: draft.lan.rules.map((item, at) => at === index ? { ...item, ...update } : item) } });
            return <tr key={rule.id}><td><input type="checkbox" aria-label={`启用设备规则 ${index + 1}`} checked={rule.enabled} onChange={event => changeRule({ enabled: event.target.checked })} /></td><td className="nf-device-addresses">
              <label><span>IPv4</span><TextList label={`设备 ${index + 1} IPv4`} values={rule.ipv4} onChange={ipv4 => changeRule({ ipv4 })} /></label>
              <label><span>IPv6</span><TextList label={`设备 ${index + 1} IPv6`} values={rule.ipv6} onChange={ipv6 => changeRule({ ipv6 })} /></label>
              <label><span>MAC</span><TextList label={`设备 ${index + 1} MAC`} values={rule.mac} onChange={mac => changeRule({ mac })} /></label>
              {!rule.ipv4.length && !rule.ipv6.length && !rule.mac.length && <small>其余设备</small>}
            </td><td><select aria-label={`设备 ${index + 1} 代理`} value={String(rule.proxy)} onChange={event => changeRule({ proxy: event.target.value === 'true' })}><option value="true">代理</option><option value="false">直连</option></select></td><td><input type="checkbox" aria-label={`设备 ${index + 1} DNS 接管`} checked={rule.dns} onChange={event => changeRule({ dns: event.target.checked })} /></td><td><button className="nf-icon-button" type="button" title="移除设备规则" aria-label={`移除设备规则 ${index + 1}`} onClick={() => change({ ...draft, lan: { ...draft.lan, rules: draft.lan.rules.filter((_, at) => at !== index) } })}><Trash2 aria-hidden="true" /></button></td></tr>;
          })}
          {!draft.lan.rules.length && <tr><td colSpan={5}>未设置单独的设备规则，沿用当前局域网接入策略。</td></tr>}
        </tbody></table></div>
      </section>
      <section className="nf-management-subsection"><h3>代理监听与认证</h3><div className="nf-form-rows">
        {([['mixed_port', '混合端口'], ['http_port', 'HTTP 端口'], ['socks_port', 'SOCKS 端口']] as const).map(([key, label]) => <div className="nf-form-row" key={key}><div><label htmlFor={`nf-${key}`}>{label}</label><p>{key === 'mixed_port' ? 'HTTP 与 SOCKS 共用' : '0 表示关闭'}</p></div><input id={`nf-${key}`} type="number" min={key === 'mixed_port' ? 1 : 0} max={65535} value={draft.listeners[key]} onChange={event => change({ ...draft, listeners: { ...draft.listeners, [key]: Number(event.target.value) } })} /></div>)}
        <div className="nf-form-row"><div><label>代理认证</label></div><Toggle label="代理认证" checked={draft.listeners.authentication_enabled} onChange={authentication_enabled => change({ ...draft, listeners: { ...draft.listeners, authentication_enabled } })} /></div>
        <div className="nf-form-row"><div><label>认证账户</label><p>密码仅在已登录的设备页面维护。</p></div><div>{draft.listeners.credentials.length ? draft.listeners.credentials.map(item => <div className="nf-credential-summary" key={item.id}><strong>{item.username}</strong><span>{item.password_configured ? '密码已配置' : '未设置密码'}</span></div>) : <span>未配置账户</span>}</div></div>
      </div></section>
      <div className="nf-management-actions"><span>{dirty ? '有尚未应用的本地草稿' : '本地草稿与读取结果一致'}</span><div><button type="button" disabled={!dirty} onClick={() => { setDraft(saved ? structuredClone(saved) : null); setMessage(null); }}><RotateCcw aria-hidden="true" />放弃更改</button><button type="button" disabled={!dirty} onClick={() => { setSaved(structuredClone(draft)); setMessage('本地网络草稿已应用；设备配置和网络状态没有改变。'); }}><Save aria-hidden="true" />应用本地预览</button></div></div>
      {message && <div className="nf-config-message" role="status"><Check aria-hidden="true" />{message}</div>}
    </>}
  </section>;
}
