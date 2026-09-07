import { useState } from 'react';
import { ExternalLink, Pencil, Plus, RefreshCw, Trash2, X } from 'lucide-react';
import type { StatusSnapshot } from '../types';
import { quotaResetLabel } from '../lib/format';

interface PreviewSource { id: string; name: string; nodeCount: number; pending: boolean; url?: string; user_agent?: string; info_url?: string; quota_reset_day?: number | null }

export function SubscriptionsPreview({ status, onResetDayChange }: { status: StatusSnapshot; onResetDayChange?: (id: string, day: number | null) => void }) {
  const [open, setOpen] = useState(false);
  const [draftSources, setDraftSources] = useState<PreviewSource[] | null>(null);
  const sources = draftSources ?? (status.subscriptions || []).map((source) => ({ id: source.section, name: source.display_name || source.section, nodeCount: source.node_count || 0, pending: Boolean(source.pending_update), quota_reset_day: source.quota?.reset_day }));
  const setSources = (change: (items: PreviewSource[]) => PreviewSource[]) => setDraftSources(change(sources));
  const [editing, setEditing] = useState<PreviewSource | null>(null);
  const [adding, setAdding] = useState(false);
  if (status.runtime.backend?.id !== 'native-mihomo') return <a className="nf-inline-link" href="/cgi-bin/luci/admin/services/nikki/profile" target="_blank" rel="noreferrer"><ExternalLink aria-hidden="true" />管理订阅</a>;
  return <>
    <button type="button" onClick={() => setOpen(true)}>管理订阅</button>
    {open && <div className="nf-managed-backdrop"><section className="nf-managed-dialog" role="dialog" aria-modal="true" aria-label="管理订阅">
      <header><h2>{adding ? '新增订阅' : editing ? '编辑订阅' : '管理订阅'}</h2><button title="关闭" type="button" onClick={() => { setOpen(false); setAdding(false); setEditing(null); }}><X aria-hidden="true" /></button></header>
      <p role="status">地址与 User-Agent 修改后待更新订阅生效；名称与重置日保存即生效。</p>
      {adding || editing ? <form onSubmit={(event) => {
        event.preventDefault();
        const values = new FormData(event.currentTarget);
        const fields = { url: String(values.get('url') || '').trim() || editing?.url, user_agent: String(values.get('user_agent') || 'clash.meta').trim(), info_url: String(values.get('info_url') || '').trim() };
        const pending = !editing || editing.pending || fields.url !== editing.url || fields.user_agent !== (editing.user_agent || 'clash.meta') || fields.info_url !== (editing.info_url || '');
        const resetDay = String(values.get('quota_reset_day') || '');
        const source = { id: editing?.id || String(values.get('id')), name: String(values.get('name')), nodeCount: editing?.nodeCount || 0, pending, ...fields, quota_reset_day: resetDay ? Number(resetDay) : null };
        setSources((items) => editing ? items.map((item) => item.id === editing.id ? source : item) : [...items, source]);
        onResetDayChange?.(source.id, source.quota_reset_day);
        event.currentTarget.reset(); setAdding(false); setEditing(null);
      }}>
        <div className="nf-form-rows">
          <label className="nf-form-row">订阅标识<input name="id" required pattern="[A-Za-z0-9_]+" defaultValue={editing?.id} disabled={Boolean(editing)} /></label>
          <label className="nf-form-row">名称<input name="name" required defaultValue={editing?.name} /></label>
          <label className="nf-form-row">订阅地址<input name="url" type="url" autoComplete="off" defaultValue={editing?.url} required={!editing} placeholder={editing && !editing.url ? '本机未读取私有地址' : ''} /></label>
          <label className="nf-form-row">User-Agent<input name="user_agent" list="netfleet-user-agents" defaultValue={editing?.user_agent || 'clash.meta'} /><datalist id="netfleet-user-agents"><option value="clash" /><option value="clash.meta" /><option value="mihomo" /></datalist></label>
          <label className="nf-form-row">用量查询地址（可选）<input name="info_url" type="url" autoComplete="off" defaultValue={editing?.info_url} /></label>
          <label className="nf-form-row">每月流量重置日<select name="quota_reset_day" defaultValue={editing?.quota_reset_day ?? ''}><option value="">未设置</option>{Array.from({ length: 31 }, (_, index) => <option key={index + 1} value={index + 1}>每月 {index + 1} 日</option>)}</select></label>
        </div>
        <footer><button type="button" onClick={() => { setAdding(false); setEditing(null); }}>返回</button><button type="submit">保存本地预览</button></footer>
      </form> : <>
        <table><thead><tr><th>名称</th><th>节点</th><th>流量重置日</th><th>状态</th><th>操作</th></tr></thead><tbody>{sources.map((source) => <tr key={source.id}><td>{source.name}</td><td>{source.nodeCount}</td><td title="手动设置，仅供套餐参考；实际结算以机场为准">{quotaResetLabel(source.quota_reset_day) || '未设置'}</td><td>{source.pending ? '已保存，待更新订阅' : '已隐藏地址'}</td><td><button type="button" title="编辑" onClick={() => setEditing(source)}><Pencil aria-hidden="true" /></button><button type="button" title="更新" onClick={() => { if (window.confirm(`确认预览更新“${source.name}”？不会下载或写入设备。`)) setSources((items) => items.map((item) => item.id === source.id ? { ...item, pending: false } : item)); }}><RefreshCw aria-hidden="true" /></button><button type="button" title="删除" onClick={() => { if (window.confirm(`确认删除“${source.name}”？`)) setSources((items) => items.filter((item) => item.id !== source.id)); }}><Trash2 aria-hidden="true" /></button></td></tr>)}</tbody></table>
        <footer><button type="button" onClick={() => setAdding(true)}><Plus aria-hidden="true" />新增订阅</button></footer>
      </>}
    </section></div>}
  </>;
}
