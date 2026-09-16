// The AppKit host mirrors page state and forwards menu or menu-bar commands.
// Business state stays in the page; the host only reflects it.

interface NativeBridge {
  saveBackup?: { postMessage(value: { contents: string }): void };
  netfleetState?: { postMessage(value: { running: boolean; configured: boolean; busy: boolean }): void };
}

const bridge = () => {
  if (typeof window === 'undefined') return undefined;
  return (window as Window & { webkit?: { messageHandlers?: NativeBridge } }).webkit?.messageHandlers;
};

export function saveBackupThroughHost(contents: string): boolean {
  const handler = bridge()?.saveBackup;
  if (!handler) return false;
  handler.postMessage({ contents });
  return true;
}

export function reportHostState(value: { running: boolean; configured: boolean; busy: boolean }): void {
  bridge()?.netfleetState?.postMessage(value);
}
