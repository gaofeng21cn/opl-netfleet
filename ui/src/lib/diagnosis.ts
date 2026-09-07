import type { ConnectionsSnapshot, StatusSnapshot } from '../types';

export function targetHost(input: string): string | null {
  const value = input.trim();
  if (!value || value.length > 2048 || /\s/.test(value)) return null;
  try {
    const address = value.includes('://') ? value : `https://${value.includes(':') && !value.includes('/') && !value.startsWith('[') && value.split(':').length > 2 ? `[${value}]` : value}`;
    const url = new URL(address);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return null;
    return url.hostname.toLowerCase().replace(/\.$/, '').replace(/^\[|\]$/g, '') || null;
  } catch { return null; }
}

export function diagnose(status: StatusSnapshot, snapshot: ConnectionsSnapshot, query: string, error?: string | null, stale = false) {
  const host = targetHost(query);
  const ip = host != null && (host.includes(':') || /^\d+\.\d+\.\d+\.\d+$/.test(host));
  const matches = host ? snapshot.connections.filter(item => {
    const destination = targetHost(item.destination);
    return destination === host || (!ip && destination?.endsWith(`.${host}`));
  }) : [];
  const runtime = status.runtime;
  const lan = runtime.lan_runtime;
  const state = (ready: boolean | undefined) => stale ? '需要重新读取' : ready === true ? '已就绪' : ready === false ? '未就绪' : '未取得状态';
  const checks = [
    { label: 'Mihomo', value: state(runtime.mihomo_running) },
    { label: '控制接口', value: state(runtime.controller_available) },
    { label: 'DNS 接入', value: state(lan?.dns_ready) },
    { label: '透明代理', value: state(lan?.transparent_proxy_ready) },
  ];
  let message = '输入目标域名或 IP，查看当前连接的实际命中结果。';
  if (query.trim() && !host) message = '请输入有效域名、IP 或 HTTP/HTTPS 地址，不包含账户凭据。';
  else if (stale) message = '设备状态不是最新读取结果，请先重新读取；以下连接不能作为当前网络结论。';
  else if (error) message = '当前连接读取失败，不能判断此网站的实际链路。';
  else if (host) message = matches.length
    ? `捕获到 ${matches.length} 条相关连接；连接存在不代表请求成功或速度达标。`
    : '当前快照没有捕获到相关连接，不代表网站不可达。连接可能已结束、未进入代理，或仅记录了 IP。';
  const next = stale || error ? '重新读取状态；若仍失败，查看核心启动与运行日志。'
    : runtime.mihomo_running === false ? '核心未运行，先查看启动日志；不要通过反复更新订阅恢复。'
      : runtime.controller_available === false ? '核心控制接口不可读，先查看核心日志和监听配置。'
        : status.active && (lan?.dns_ready === false || lan?.transparent_proxy_ready === false)
          ? '检查网络接入配置与接管状态；此处不能判断具体域名是否解析成功。'
          : host && !matches.length ? '在发生问题的设备上再次访问目标，然后重新读取；更多连接请打开 Zashboard。'
            : '对照下方实际规则与链路；涉及协议或长连接时，可继续查看 HTTPS 兼容诊断。';
  return { host, matches, checks, message, next, truncated: snapshot.truncated, readAt: snapshot.read_at };
}
