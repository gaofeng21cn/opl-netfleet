import { useState } from 'react';
import { RefreshCw, ShieldCheck } from 'lucide-react';

export function CompatibilityPreview() {
  const [requested, setRequested] = useState(false);
  return <section>
    <div className="nf-config-section-heading"><h2>HTTPS 兼容</h2></div>
    <div className="nf-form-row">
      <label><input type="checkbox" checked={requested} onChange={event => setRequested(event.target.checked)} />开启</label>
      <div role="status"><strong>{requested ? '已开启，当前旁路' : '已关闭'}</strong><p>没有已验证的接入目标</p></div>
    </div>
    <div className="nf-config-actions"><button type="button" disabled><RefreshCw aria-hidden="true" />连接验证</button><button type="button" disabled><ShieldCheck aria-hidden="true" />人工恢复</button></div>
    <h3>目标规则</h3>
    <div className="nf-table-wrap"><table><thead><tr><th>启用</th><th>域名</th><th>设备</th><th>策略</th><th>实际协议</th><th>最近结果</th></tr></thead><tbody><tr><td colSpan={6}>暂无规则</td></tr></tbody></table></div>
    <h3>设备与信任</h3>
    <div className="nf-table-wrap"><table><thead><tr><th>设备</th><th>系统信任</th><th>Codex App</th><th>CLI</th><th>图片</th></tr></thead><tbody><tr><td colSpan={5}>暂无接入设备</td></tr></tbody></table></div>
    <h3>兼容事件</h3><p>暂无事件</p>
  </section>;
}
