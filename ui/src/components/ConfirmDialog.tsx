import { AlertTriangle, X } from 'lucide-react';
import { useEffect, useId, useRef, type ReactNode } from 'react';

interface ConfirmDialogProps {
  title: string;
  description: string;
  confirmLabel: string;
  danger?: boolean;
  busy?: boolean;
  children?: ReactNode;
  onCancel(): void;
  onConfirm(): void;
}

export function ConfirmDialog({ title, description, confirmLabel, danger, busy, children, onCancel, onConfirm }: ConfirmDialogProps) {
  const dialog = useRef<HTMLElement>(null);
  const titleId = useId();
  const cancel = useRef(onCancel);
  cancel.current = onCancel;
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    const element = dialog.current;
    element?.focus();
    const keyboard = (event: KeyboardEvent) => {
      if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); cancel.current(); }
      if (event.key !== 'Tab' || !element) return;
      const controls = Array.from(element.querySelectorAll<HTMLElement>('button:not(:disabled), select:not(:disabled), input:not(:disabled), textarea:not(:disabled), [href], [tabindex="0"]')).filter(item => item.getClientRects().length > 0);
      const first = controls[0], last = controls.at(-1);
      if (!first) { event.preventDefault(); element.focus(); }
      else if (event.shiftKey && (document.activeElement === first || document.activeElement === element)) { event.preventDefault(); last?.focus(); }
      else if (!event.shiftKey && (document.activeElement === last || document.activeElement === element)) { event.preventDefault(); first.focus(); }
    };
    element?.addEventListener('keydown', keyboard);
    return () => { element?.removeEventListener('keydown', keyboard); if (previous?.isConnected) previous.focus(); };
  }, []);
  return (
    <div className="nf-dialog-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onCancel()}>
      <section ref={dialog} tabIndex={-1} className="nf-dialog" role="dialog" aria-modal="true" aria-labelledby={titleId}>
        <button className="nf-icon-button nf-dialog-close" type="button" onClick={onCancel} aria-label="关闭对话框">
          <X aria-hidden="true" />
        </button>
        <div className={`nf-dialog-icon ${danger ? 'is-danger' : ''}`}><AlertTriangle aria-hidden="true" /></div>
        <h2 id={titleId}>{title}</h2>
        <p>{description}</p>
        {children}
        <div className="nf-dialog-actions">
          <button type="button" onClick={onCancel} disabled={busy}>取消</button>
          <button className={danger ? 'nf-button-danger' : 'nf-button-primary'} type="button" onClick={onConfirm} disabled={busy}>
            {confirmLabel}
          </button>
        </div>
      </section>
    </div>
  );
}
