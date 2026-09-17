// The AppKit host mirrors page state and forwards menu or menu-bar commands.
// Business state stays in the page; the host only reflects it.

import type { HostState } from './hostState';

interface NativeBridge {
  saveBackup?: { postMessage(value: { contents: string }): void };
  netfleetState?: { postMessage(value: HostState): void };
  openDashboard?: { postMessage(value: { url: string }): void };
  installUpdate?: { postMessage(value: Record<string, never>): void };
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

export function reportHostState(value: HostState): void {
  bridge()?.netfleetState?.postMessage(value);
}

// The panel URL carries the controller credential for this session only. The
// host loads it in its own non-persistent window, so it never reaches browser
// history, the page URL or the display cache.
export function openDashboardThroughHost(url: string): boolean {
  const handler = bridge()?.openDashboard;
  if (!handler) return false;
  handler.postMessage({ url });
  return true;
}

// 更新已经通过校验并暂存；退出交给宿主既有的优雅退出路径（它会先停止核心、
// 撤销网络接管并确认清理成功），然后由替换进程在应用退出后接管。
export function installUpdateThroughHost(): boolean {
  const handler = bridge()?.installUpdate;
  if (!handler) return false;
  handler.postMessage({});
  return true;
}
