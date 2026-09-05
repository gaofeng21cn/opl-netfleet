import { LifeBuoy, Router } from 'lucide-react';
import { recoveryPreferredLabel } from '../lib/format';
import type { StatusSnapshot } from '../types';

export function RecoverySection({ snapshot }: { snapshot: StatusSnapshot }) {
  const preferred = recoveryPreferredLabel(snapshot);
  return (
    <section className="nf-recovery-section">
      <div className="nf-section-heading"><div><h2>退出与故障恢复</h2><p>两项是优先恢复与失败条件下的最终退路，不是连续执行步骤。</p></div></div>
      <div className="nf-recovery-options">
        <div><span className="nf-recovery-icon"><Router aria-hidden="true" /></span><dl><dt>优先恢复</dt><dd>{preferred}</dd></dl></div>
        <div><span className="nf-recovery-icon"><LifeBuoy aria-hidden="true" /></span><dl><dt>最终退路</dt><dd>原生配置恢复失败时，停止 {snapshot.runtime.backend?.display_name || '当前代理后端'} 并恢复网络直通</dd></dl></div>
      </div>
    </section>
  );
}
