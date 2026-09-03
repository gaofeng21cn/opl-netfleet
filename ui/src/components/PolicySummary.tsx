import { Clock3, Gauge, ShieldCheck, TimerReset } from 'lucide-react';
import type { StatusSnapshot } from '../types';

const seconds = (value?: number) => value == null
  ? '未提供'
  : value >= 60 && value % 60 === 0 ? `${value / 60} 分钟` : `${value} 秒`;

export function PolicySummary({ snapshot }: { snapshot: StatusSnapshot }) {
  const automation = snapshot.selection?.automation;
  const items = [
    { label: '自动选优周期', value: seconds(automation?.selection_interval_seconds), icon: Clock3 },
    { label: '启动收敛等待', value: seconds(automation?.startup_grace_seconds), icon: Clock3 },
    { label: '地区切换门槛', value: snapshot.selection?.region_switch_margin_ms == null ? '未提供' : `${snapshot.selection.region_switch_margin_ms} ms`, icon: Gauge },
    { label: '节点切换门槛', value: snapshot.selection?.leaf_switch_margin_ms == null ? '未提供' : `${snapshot.selection.leaf_switch_margin_ms} ms`, icon: TimerReset },
    { label: '运行失联保护', value: seconds(automation?.runtime_grace_seconds), icon: ShieldCheck },
  ];
  return (
    <section className="nf-policy-summary">
      <div className="nf-section-heading"><div><h2>运行口径</h2><p>全部读取自当前设备策略，不参与前端决策。</p></div></div>
      <div className="nf-policy-grid">
        {items.map(({ label, value, icon: Icon }) => (
          <dl key={label}><dt><Icon aria-hidden="true" />{label}</dt><dd>{value}</dd></dl>
        ))}
      </div>
    </section>
  );
}
