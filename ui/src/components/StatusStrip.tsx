import type { StatusSnapshot } from '../types';
import { displayVersion } from '../lib/version';

export function StatusStrip({ snapshot }: { snapshot: StatusSnapshot }) {
  const supervisor = snapshot.runtime.supervisor;
  const lanRuntime = snapshot.runtime.lan_runtime;
  const stopped = snapshot.runtime.backend_enabled === false && snapshot.runtime.mihomo_running === false;
  const health = (value?: boolean) => value === true ? '正常' : value === false ? '异常' : '状态未确认';
  const interception = (enabled?: boolean, ready?: boolean) => stopped || enabled === false ? '未启用' : enabled === true ? `已启用 · ${health(ready)}` : '状态未确认';
  const mode = { openwrt: 'OpenWrt 原生直连', mihomo: 'Mihomo 原生代理', netfleet: 'NetFleet 增强代理' };
  const groups = [
    { title: '运行概况', items: [
      ['NetFleet', displayVersion(snapshot.build?.version)],
      ['运行模式', snapshot.operating_mode ? mode[snapshot.operating_mode] : '状态未确认'],
      ['当前配置', snapshot.active ? 'NetFleet 运行配置' : snapshot.recovery_profile_display_name || '当前原生配置'],
    ] },
    { title: '网络接管', items: [
      ['Mihomo', snapshot.runtime.mihomo_running ? '运行中' : '未运行'],
      ['LAN 透明代理', interception(lanRuntime?.lan_proxy_enabled, lanRuntime?.transparent_proxy_ready)],
      ['DNS 接管', interception(lanRuntime?.dns_hijack_enabled, lanRuntime?.dns_ready)],
    ] },
    { title: '管理服务', items: [
      ['控制接口', stopped ? '未运行' : health(snapshot.runtime.controller_available)],
      ['实时面板', stopped ? '未运行' : lanRuntime?.dashboard_lan_ready === true ? '正常 · 局域网访问' : lanRuntime?.api_listen && lanRuntime.api_listen !== '0.0.0.0:9090' ? '未开放局域网' : health(lanRuntime?.dashboard_lan_ready)],
      ['周期选优', supervisor?.running ? snapshot.selection?.automation_paused ? '手动暂停' : '运行中' : '未运行'],
    ] },
  ];
  return (
    <div className="nf-status-strip" aria-label="运行状态">
      {groups.map(group => (
        <section className="nf-status-group" key={group.title} aria-label={group.title}>
          <h3>{group.title}</h3><dl>{group.items.map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl>
        </section>
      ))}
    </div>
  );
}
