import type { StatusSnapshot } from '../types';
import { displayVersion } from '../lib/version';

export function StatusStrip({ snapshot }: { snapshot: StatusSnapshot }) {
  const supervisor = snapshot.runtime.supervisor;
  const lanRuntime = snapshot.runtime.lan_runtime;
  const mode = { openwrt: 'OpenWrt 原生直连', mihomo: 'Mihomo 原生代理', netfleet: 'NetFleet 增强代理' };
  const groups = [
    { title: '运行概况', items: [
      ['NetFleet', displayVersion(snapshot.build?.version)],
      ['运行模式', snapshot.operating_mode ? mode[snapshot.operating_mode] : '状态未确认'],
      ['当前配置', snapshot.active ? 'NetFleet 运行配置' : snapshot.recovery_profile_display_name || '当前原生配置'],
    ] },
    { title: '网络接管', items: [
      ['Mihomo', snapshot.runtime.mihomo_running ? '运行中' : '未运行'],
      ['LAN 透明代理', lanRuntime?.transparent_proxy_ready ? '可用' : snapshot.active ? '不可用' : '未接管'],
      ['DNS 接管', lanRuntime?.dns_ready ? '可用' : snapshot.active ? '不可用' : '未接管'],
    ] },
    { title: '管理服务', items: [
      ['控制接口', snapshot.runtime.controller_available ? '可读取' : '不可用'],
      ['实时面板', lanRuntime?.dashboard_lan_ready ? 'LAN 可访问' : 'LAN 不可访问'],
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
