import { AlertTriangle, X } from 'lucide-react';

interface ConfirmDialogProps {
  title: string;
  description: string;
  confirmLabel: string;
  danger?: boolean;
  busy?: boolean;
  onCancel(): void;
  onConfirm(): void;
}

export function ConfirmDialog({ title, description, confirmLabel, danger, busy, onCancel, onConfirm }: ConfirmDialogProps) {
  return (
    <div className="nf-dialog-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onCancel()}>
      <section className="nf-dialog" role="dialog" aria-modal="true" aria-labelledby="nf-dialog-title">
        <button className="nf-icon-button nf-dialog-close" type="button" onClick={onCancel} aria-label="关闭对话框">
          <X aria-hidden="true" />
        </button>
        <div className={`nf-dialog-icon ${danger ? 'is-danger' : ''}`}><AlertTriangle aria-hidden="true" /></div>
        <h2 id="nf-dialog-title">{title}</h2>
        <p>{description}</p>
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
