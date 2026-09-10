import type { ConnectionsSnapshot, NetFleetClient } from '../types';
import type { DesktopSnapshot } from './types';

// Share the business actions without pretending macOS owns OpenWrt maintenance APIs.
type BusinessClient = Pick<NetFleetClient, 'status' | 'events' | 'enable' | 'disable' | 'selectAuto' | 'refresh' | 'connections'>;

const messages: Record<string, string> = {
  unauthorized: '本机会话已失效，请退出并重新打开应用。',
  stop_proxy_before_policy_change: '请先停止代理，再切换业务策略。',
  builtin_ruleset_missing: '内置规则文件缺失，请重新打开应用恢复随包资源。原策略已保留。',
  builtin_ruleset_mismatch: '内置规则校验失败，请重新打开应用恢复随包资源。原策略已保留。',
  builtin_policy_missing: '内置策略资源缺失，请重新构建或打开完整的应用。',
  stop_proxy_before_import: '请先停止代理，再导入基础配置。',
  stop_proxy_before_restore: '请先停止代理，再恢复备份。',
  initial_policy_needs_configuration: '无法从节点自动识别完整策略，请补充业务策略后编译。',
  profile_has_no_nodes: '配置需要包含代理节点或节点订阅来源。',
  invalid_policy: '业务策略格式无效，请检查后再保存。',
  subscription_download_failed: '订阅下载失败，请检查地址、网络或订阅是否失效。原有配置仍保留。',
  subscription_has_no_nodes: '订阅没有返回可用节点，请使用 Clash / Mihomo 格式的订阅地址。',
  subscription_too_large: '订阅内容超过 8 MB，请检查是否使用了正确的订阅地址。',
  subscription_already_exists: '这个订阅地址已经添加，请更新已有来源。',
  subscription_required: '请先添加一个机场订阅。',
  subscription_url_required: '请填写机场订阅地址。',
  stop_proxy_before_subscription_change: '请先停止代理，再增删或修改订阅来源。日常更新无需停止。',
  last_provider_required: '至少需要保留一个启用的机场。请先添加替代订阅。',
  policy_unreadable: '尚未生成业务配置，请先添加订阅并完成准备。',
  mihomo_configuration_rejected: 'Mihomo 无法接受这份配置，请检查订阅格式或节点协议。原有配置仍保留。',
  profile_yaml_invalid: '订阅或配置内容无法解析，请使用 Clash / Mihomo 格式。',
  active_precondition_failed: '当前代理未通过更新前检查，未应用订阅变化。请检查连接后重试。',
  upstream_unavailable: '当前无法连接订阅服务器，原有缓存仍保留。',
  invalid_subscriptions: '机场订阅格式无效。',
  invalid_subscription_url: '订阅地址必须是有效的 HTTP 或 HTTPS 地址。',
  invalid_backup: '请选择有效的 NetFleet macOS 配置备份。',
  controller_unavailable: '代理控制接口读取失败，请检查核心状态后重试。',
  mihomo_connections_unavailable: '无法读取代理连接信息，请检查核心状态后重试。',
  config_revision_conflict: '配置已被其他操作修改，请重新载入配置后再保存。当前草稿仍保留。',
  active_requires_apply: '请先退出 NetFleet 增强代理，再保存配置。',
  config_invalid: '配置校验失败，请检查机场、地区、出口绑定与探针设置。',
  'not-authorized': '系统授权未完成，网络接管未启用。',
};
function message(error: unknown): string {
  if (typeof error === 'string') return messages[error] ?? error;
  if (error && typeof error === 'object' && 'message' in error) return message(error.message);
  return '本机操作失败，请检查诊断信息。';
}

export class DesktopNetFleetClient implements BusinessClient {
  constructor(private readonly token: string | null, private readonly fetcher: typeof fetch = (input, init) => fetch(input, init)) {}

  private async request<T>(path: string, body?: Record<string, unknown>): Promise<T> {
    if (!this.token) throw new Error(messages.unauthorized);
    const response = await this.fetcher(path, {
      method: body ? 'POST' : 'GET',
      credentials: 'omit',
      cache: 'no-store',
      headers: { Authorization: `Bearer ${this.token}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    const payload = await response.json();
    if (!response.ok || payload.ok !== true || payload.result?.ok === false || payload.result?.result?.ok === false) {
      throw new Error(message(payload.error ?? payload.result?.error ?? payload.result?.result?.reason ?? payload.result?.status));
    }
    return payload.result as T;
  }

  async readSnapshot(): Promise<DesktopSnapshot> {
    const value = await this.request<DesktopSnapshot>('/api/state');
    if (value?.runtime?.platform !== 'macos' || typeof value.runtime.running !== 'boolean'
      || typeof value.runtime.configured !== 'boolean' || !value.subscriptions || !value.network
      || (value.status !== null && (!Array.isArray(value.status?.capabilities) || !Array.isArray(value.status?.providers) || !Array.isArray(value.status?.regions)))
      || (value.config != null && (typeof value.config.revision !== 'string' || !Array.isArray(value.config.providers) || !Array.isArray(value.config.regions) || !Array.isArray(value.config.capabilities)))
      || (value.events !== null && !Array.isArray(value.events?.events))) {
      throw new Error('本机状态格式无效，已停止更新界面。');
    }
    return value;
  }
  action<T = unknown>(action: string, input: Record<string, unknown> = {}): Promise<T> {
    return this.request<T>('/api/action', { ...input, action });
  }
  async status() {
    const value = await this.readSnapshot();
    if (!value.status) throw new Error(value.error || '业务策略尚未编译。');
    return value.status;
  }
  async events() {
    const value = await this.readSnapshot();
    if (!value.events) throw new Error(value.error || '尚无业务事件数据。');
    return value.events;
  }
  enable() { return this.action('enable', { authorize: true }); }
  disable() { return this.action('disable'); }
  selectAuto(capability: string) { return this.action('select-auto', { capability }); }
  selectRegion(capability: string, region: string) { return this.action('select-region', { capability, region }); }
  refresh() { return this.action('refresh'); }
  logs() { return this.action<{ text: string }>('logs'); }
  exportBackup() { return this.action('backup-export'); }
  connections() { return this.action<ConnectionsSnapshot>('connections'); }
}
