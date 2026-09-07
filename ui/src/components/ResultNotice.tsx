import { useState, type ReactNode } from 'react';
import { X } from 'lucide-react';

export const resultTime = (value?: number | null, label = '完成于') => value && value > 0
  ? `${label} ${new Date(value * 1000).toLocaleString()}` : '';

function SessionResult({ storageKey, identity, title, warning, children }: {
  storageKey: string; identity: string; title: string; warning?: boolean; children: ReactNode;
}) {
  const [dismissed, setDismissed] = useState(() => {
    try { return sessionStorage.getItem(storageKey); } catch { return null; }
  });
  if (dismissed === identity) return null;
  return <section className={`nf-operation is-result${warning ? ' is-warning' : ''}`} role="status">
    <div className="nf-result-body"><strong>{title}</strong><div className="nf-operation-detail">{children}</div></div>
    <button type="button" className="nf-result-close" title="关闭此条结果" aria-label={`关闭${title}结果`} onClick={() => {
      setDismissed(identity);
      try { sessionStorage.setItem(storageKey, identity); } catch { /* Keep dismiss usable when storage is blocked. */ }
    }}><X aria-hidden="true" /></button>
  </section>;
}

export function ResultNotice({ scope = '', slot, ...props }: {
  scope?: string; slot: string; identity: string; title: string; warning?: boolean; children: ReactNode;
}) {
  const storageKey = `netfleet:result:v1:${scope}:${slot}`;
  return <SessionResult key={storageKey} storageKey={storageKey} {...props} />;
}
