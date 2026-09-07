import { Activity, Cable, Network, RefreshCw, ShieldCheck, SlidersHorizontal } from 'lucide-react';
import type { StatusSnapshot } from '../types';

export function StatusStrip({ snapshot }: { snapshot: StatusSnapshot }) {
  const supervisor = snapshot.runtime.supervisor;
  const lanRuntime = snapshot.runtime.lan_runtime;
  const items = [
    { label: 'NetFleet', value: snapshot.recovery ? '降级恢复中' : snapshot.active ? '已启用' : snapshot.runtime.netfleet_present ? '待清理' : '已关闭', ok: snapshot.active && !snapshot.recovery, icon: Network },
    { label: 'Mihomo', value: snapshot.runtime.mihomo_running ? '运行中' : '未运行', ok: snapshot.runtime.mihomo_running, icon: Activity },
    { label: 'LAN 透明代理', value: lanRuntime?.transparent_proxy_ready ? '可用' : snapshot.active ? '不可用' : '未接管', ok: Boolean(lanRuntime?.transparent_proxy_ready), icon: Cable },
    { label: 'DNS 接管', value: lanRuntime?.dns_ready ? '可用' : snapshot.active ? '不可用' : '未接管', ok: Boolean(lanRuntime?.dns_ready), icon: ShieldCheck },
    { label: '控制接口', value: snapshot.runtime.controller_available ? '可读取' : '不可用', ok: snapshot.runtime.controller_available, icon: Cable },
    { label: '周期选优', value: supervisor?.running ? (snapshot.selection?.automation_paused ? '手动暂停' : '运行中') : '未运行', ok: supervisor?.running && !snapshot.selection?.automation_paused, icon: RefreshCw },
    { label: '当前配置', value: snapshot.active ? 'NetFleet 运行配置' : snapshot.recovery_profile_display_name || '当前原生配置', ok: true, icon: SlidersHorizontal },
  ];
  return (
    <div className="nf-status-strip">
      {items.map(({ label, value, ok, icon: Icon }) => (
        <div className="nf-status-item" key={label}>
          <Icon aria-hidden="true" />
          <div><span>{label}</span><strong className={ok ? 'is-ok' : ''}>{value}</strong></div>
        </div>
      ))}
    </div>
  );
}
