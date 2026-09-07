import { useState } from 'react';
import { ArrowLeft, Download, ExternalLink, RefreshCw } from 'lucide-react';
import type { ExtensionComponent } from '../types';

export function CompatibilityView({ extension, onBack }: { extension?: ExtensionComponent; onBack(): void }) {
  const [tab, setTab] = useState('rules');
  const previewReason = '请在设备 LuCI 中操作';
  return <section className="nf-compatibility">
    <div className="nf-section-heading"><div><h2>HTTPS 兼容</h2><small>{extension?.installed_version || '未安装'}</small></div>
      <div className="nf-components-actions"><button type="button" onClick={onBack}><ArrowLeft aria-hidden="true" />返回组件列表</button>
        <button type="button" disabled title={previewReason}><ExternalLink aria-hidden="true" />软件包管理</button></div>
    </div>
    <div className="nf-form-row">
      <label><input type="checkbox" disabled title={previewReason} />启用 HTTPS 兼容</label>
      <div role="status"><strong>运行状态未读取</strong></div>
      <button type="button" disabled title={previewReason} aria-label="刷新兼容状态"><RefreshCw aria-hidden="true" /></button>
    </div>
    <div className="nf-compat-tabs" role="tablist" aria-label="HTTPS 兼容管理">
      {[['rules', '规则'], ['devices', '设备与信任'], ['diagnostics', '诊断']].map(([id, label]) =>
        <button type="button" role="tab" key={id} aria-selected={tab === id} aria-controls="nf-compat-panel" className={tab === id ? 'is-active' : ''} onClick={() => setTab(id)}>{label}</button>)}
    </div>
    <div role="tabpanel" id="nf-compat-panel">
      {tab === 'rules' && <>
        <div className="nf-section-heading"><h3>目标规则</h3><button type="button" disabled title={previewReason}>新增规则</button></div>
        <div className="nf-table-wrap"><table><thead><tr>{['启用', '目标', '设备', '策略', '状态', '操作'].map(label => <th key={label}>{label}</th>)}</tr></thead><tbody><tr><td colSpan={6}>尚未读取目标规则</td></tr></tbody></table></div>
      </>}
      {tab === 'devices' && <>
        <div className="nf-section-heading"><h3>设备与信任</h3><button type="button" disabled title={previewReason}>新增设备</button></div>
        <div className="nf-table-wrap"><table><thead><tr>{['设备', '系统信任', '应用', '操作'].map(label => <th key={label}>{label}</th>)}</tr></thead><tbody><tr><td colSpan={4}>尚未读取接入设备</td></tr></tbody></table></div>
        <div className="nf-components-actions"><button type="button" disabled title={previewReason}><Download aria-hidden="true" />下载公开 CA</button><button type="button" disabled title={previewReason}><Download aria-hidden="true" />macOS 接入工具</button></div>
      </>}
      {tab === 'diagnostics' && <>
        <div className="nf-section-heading"><h3>诊断</h3><div className="nf-components-actions"><button type="button" disabled title={previewReason}>连接验证</button><button type="button" disabled title={previewReason}><Download aria-hidden="true" />导出诊断</button></div></div>
        <div className="nf-table-wrap"><table><thead><tr>{['目标', '最近故障', '恢复探测', '操作'].map(label => <th key={label}>{label}</th>)}</tr></thead><tbody><tr><td colSpan={4}>尚未读取诊断记录</td></tr></tbody></table></div>
        <h3>兼容事件</h3><p>尚未读取兼容事件</p>
      </>}
    </div>
  </section>;
}
