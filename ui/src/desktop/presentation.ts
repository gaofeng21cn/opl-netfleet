import type { DesktopSnapshot } from './types';
export const sampledAt = (value: number) => new Date(value * 1000).toLocaleString('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' });

// Both desktop source management and the provider list use the same owner cache evidence.
export function sourcePreparation(snapshot: DesktopSnapshot, id: string): string {
  const source = snapshot.subscriptions[id];
  const provider = snapshot.status?.providers.find(item => (item.subscription_section || item.id) === id);
  const cache = snapshot.status?.subscriptions?.find(item => item.section === id || item.section === provider?.subscription_section);
  if (source.imported && !source.hasUrl) return '本地导入 · 不会自动下载';
  if (cache?.cache_present) return cache.last_success ? `缓存已更新 · ${sampledAt(cache.last_success)}` : '已有订阅缓存';
  if (source.updatedAt) return `已下载 · ${new Date(source.updatedAt).toLocaleString('zh-CN')}`;
  return source.nodeCount != null ? `${source.nodeCount} 条节点记录` : '下载记录未提供';
}
