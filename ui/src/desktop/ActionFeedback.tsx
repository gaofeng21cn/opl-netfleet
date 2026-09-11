import { useEffect, useState } from 'react';
import { CheckCircle2, CircleAlert, LoaderCircle, X } from 'lucide-react';

type Result = { id: string; title: string; detail: string; warning?: boolean };
export function ActionFeedback({ progress, elapsed, result, inline = false, onDismiss }: {
  progress: { title: string } | null; elapsed: number; result: Result | null;
  inline?: boolean; onDismiss(): void;
}) {
  const [hovered, setHovered] = useState(false);
  const [focused, setFocused] = useState(false);
  useEffect(() => {
    if (!result || result.warning || hovered || focused || inline) return;
    const timer = setTimeout(onDismiss, 6000);
    return () => clearTimeout(timer);
  }, [result?.id, result?.warning, hovered, focused, inline, onDismiss]);
  if (!progress && !result) return null;
  const Icon = progress ? LoaderCircle : result?.warning ? CircleAlert : CheckCircle2;
  return <section className={`nf-desktop-feedback${inline ? ' is-inline' : ''}${result?.warning ? ' is-warning' : ''}`}
    role="status" aria-live="polite" aria-atomic="true"
    onMouseEnter={() => setHovered(true)} onMouseLeave={() => setHovered(false)}
    onFocusCapture={() => setFocused(true)} onBlurCapture={event => { if (!event.currentTarget.contains(event.relatedTarget)) setFocused(false); }}>
    <Icon aria-hidden="true" className={progress ? 'is-spinning' : undefined} />
    <div><strong>{progress?.title || result?.title}</strong><p>{progress ? `正在执行 · 已等待 ${elapsed} 秒` : result?.detail}</p></div>
    {!progress && <button type="button" aria-label="关闭操作提示" onClick={onDismiss}><X aria-hidden="true" /></button>}
  </section>;
}
