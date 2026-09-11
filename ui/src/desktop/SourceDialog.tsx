import { useEffect, useRef, type ReactNode } from 'react';
export function SourceDialog({ open, onClose, children }: { open: boolean; onClose(): void; children: ReactNode }) {
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => { if (open && !dialog.current?.open) dialog.current?.showModal(); else if (!open && dialog.current?.open) dialog.current.close(); }, [open]);
  return <dialog ref={dialog} className="nf-source-dialog" aria-label="管理订阅来源" onCancel={onClose} onClose={onClose}>
    <div className="nf-source-dialog-header"><h2>管理订阅来源</h2><button type="button" className="nf-button-secondary" onClick={onClose}>关闭</button></div>
    {children}
  </dialog>;
}
