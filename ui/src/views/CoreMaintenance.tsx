import { RefreshCw, RotateCcw } from 'lucide-react';
import type { NetFleetClient } from '../types';
import { useManagementRead } from '../config/useManagementRead';

export function CoreMaintenance({ client }: { client?: NetFleetClient }) {
  const maintenance = useManagementRead(client, 'maintenance');
  const diagnostics = useManagementRead(client, 'diagnostics');
  const core = maintenance.data?.core;
  const captured = diagnostics.data?.captured_at;
  const loading = maintenance.loading || diagnostics.loading;
  return <section className="nf-management nf-core-maintenance">
    <div className="nf-section-heading"><h2>核心维护</h2><div className="nf-management-buttons">
      <button type="button" disabled={loading || !client} onClick={() => { void maintenance.refresh(); void diagnostics.refresh(); }}><RefreshCw aria-hidden="true" className={loading ? 'is-spinning' : ''} />重新读取</button>
      <button type="button" disabled title="本机预览只读；请在设备 LuCI 中重新加载核心"><RefreshCw aria-hidden="true" />重新加载配置</button>
      <button type="button" disabled title="本机预览只读；请在设备 LuCI 中重启核心"><RotateCcw aria-hidden="true" />重启核心</button>
    </div></div>
    {maintenance.error && <div className="nf-inline-warning">{maintenance.error}</div>}
    {maintenance.data && !maintenance.data.supported && <p className="nf-management-note">当前运行后端尚未提供原生核心维护。</p>}
    <dl className="nf-core-summary"><div><dt>运行状态</dt><dd>{core ? core.running ? '运行中' : '已停止' : loading ? '正在读取' : '未提供'}</dd></div><div><dt>核心版本</dt><dd>{core?.running_version || '未提供'}</dd></div><div><dt>控制接口</dt><dd>{core ? core.controller_available ? '可读取' : '不可用' : '未提供'}</dd></div><div><dt>诊断读取</dt><dd>{captured ? new Date(captured * 1000).toLocaleString() : '未提供'}</dd></div></dl>
    <div className="nf-log-section"><h3>核心启动与运行日志</h3>
      {diagnostics.error && <p className="nf-inline-warning">{diagnostics.error}</p>}
      <pre>{diagnostics.data?.lines.join('\n') || (diagnostics.loading ? '正在读取核心日志…' : '暂无核心日志。')}</pre>
      {diagnostics.data?.truncated && <p className="nf-management-note">只显示最近的日志窗口。</p>}
    </div>
  </section>;
}
