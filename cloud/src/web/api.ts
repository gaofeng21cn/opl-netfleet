import type { Snapshot, Trend } from "../contracts.js";

export type AuthUser = {
  email: string;
  role: "owner" | "admin";
};

export type Site = {
  id: string;
  name: string;
  device_id?: string;
  revision: number;
  grants: string[];
  token_active: boolean;
  online: boolean;
  snapshot: Snapshot | null;
};

export type Source = {
  id: string;
  name: string;
  fingerprint: string;
};

export type Verb = "GET" | "POST" | "PUT" | "DELETE";
export type ThemeMode = "system" | "light" | "dark";
export type SiteFilter = "all" | "online" | "attention" | "offline";
export type ViewMode = "table" | "cards";
export type SiteHealth = "online" | "attention" | "offline";

const ERROR_MESSAGES: Record<string, string> = {
  unauthorized: "账号、密码校验未通过，或当前用户不在管理员白名单内，或会话已过期。",
  origin_forbidden: "同源策略已拦截跨站状态修改请求。",
  invalid_site: "站点 ID 须符合 ^[a-z][a-z0-9-]{1,47}$，显示名称须为 1–120 个可打印字符。",
  site_exists: "该站点 ID 已存在。",
  site_limit: "已达到单实例最大纳管站点数量限制（64）。",
  site_not_found: "未找到该站点，或当前账号无权操作。",
  invalid_subscription: "请填写规范的小写订阅 ID、名称与 HTTPS 订阅链接。",
  subscription_exists: "该订阅 ID 已存在。",
  subscription_limit: "已达到最大订阅池数量限制（64）。",
  subscription_not_found: "未找到该订阅源，或已被移除。",
  invalid_grants: "授权列表须为有效订阅 ID（单站点最多 16 条）。",
  service_unavailable: "云端控制面暂时不可用，请稍后重试。",
};

export class ApiError extends Error {
  readonly code?: string;

  constructor(readonly status: number, code?: string) {
    super(
      (code && ERROR_MESSAGES[code]) ||
        `请求失败（HTTP ${status}${code ? ` · ${code}` : ""}）。`,
    );
    this.code = code;
  }
}

export async function api<T>(
  path: string,
  method: Verb = "GET",
  data?: unknown,
): Promise<T> {
  const response = await fetch(`/api/v1${path}`, {
    method,
    headers:
      data === undefined ? undefined : { "content-type": "application/json" },
    body: data === undefined ? undefined : JSON.stringify(data),
  });
  let payload: unknown = null;
  try {
    payload = await response.json();
  } catch {
    payload = null;
  }
  if (!response.ok) {
    const code =
      payload && typeof payload === "object" && "error" in payload && typeof payload.error === "string"
        ? payload.error
        : undefined;
    throw new ApiError(response.status, code);
  }
  return payload as T;
}

export function formatBytes(value: number | undefined): string {
  if (value == null || !Number.isFinite(value)) return "—";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let current = value;
  let unit = 0;
  while (current >= 1024 && unit < units.length - 1) {
    current /= 1024;
    unit += 1;
  }
  return `${current.toLocaleString(undefined, { maximumFractionDigits: current >= 100 ? 0 : 1 })} ${units[unit]}`;
}

export function formatBps(value: number | undefined): string {
  if (value == null || !Number.isFinite(value)) return "—";
  if (value >= 1_000_000_000) return `${(value / 1_000_000_000).toFixed(2)} Gbps`;
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)} Mbps`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(0)} kbps`;
  return `${Math.round(value)} bps`;
}

export function formatRelativeTime(iso: string | undefined): string {
  if (!iso) return "从未上报";
  const parsed = Date.parse(iso);
  if (!Number.isFinite(parsed)) return "未知";
  const diffSec = Math.max(0, Math.round((Date.now() - parsed) / 1000));
  if (diffSec < 10) return "刚刚";
  if (diffSec < 60) return `${diffSec} 秒前`;
  const diffMin = Math.round(diffSec / 60);
  if (diffMin < 60) return `${diffMin} 分钟前`;
  const diffHr = Math.round(diffMin / 60);
  if (diffHr < 48) return `${diffHr} 小时前`;
  return `${Math.round(diffHr / 24)} 天前`;
}

export function formatShortTime(iso: string | undefined): string {
  if (!iso) return "—";
  const parsed = new Date(iso);
  if (Number.isNaN(parsed.getTime())) return "—";
  return parsed.toLocaleTimeString(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

export function formatMode(mode: string | undefined): string {
  switch (mode) {
    case "netfleet":
      return "NetFleet 原生";
    case "mihomo":
      return "Mihomo";
    case "openwrt":
      return "OpenWrt";
    case "unknown":
      return "未知模式";
    default:
      return mode ?? "未上报";
  }
}

export function formatEvent(event: string | undefined): string {
  switch (event) {
    case "updated":
      return "订阅已更新";
    case "unchanged":
      return "订阅无变化";
    case "failed":
      return "同步失败";
    case "recovering":
      return "故障恢复中";
    case "restored":
      return "已恢复";
    default:
      return event ?? "";
  }
}

export function siteMedianRtt(site: Site): number | null {
  const samples = (site.snapshot?.latest.capabilities ?? [])
    .map((cap) => cap.rtt_ms)
    .filter((rtt): rtt is number => typeof rtt === "number");
  if (!samples.length) return null;
  const sorted = [...samples].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

export function isRevisionSynced(site: Site): boolean {
  const applied = site.snapshot?.latest.applied_revision;
  return applied != null && applied === site.revision;
}

export function classifySite(site: Site): {
  health: SiteHealth;
  reasons: string[];
} {
  const reasons: string[] = [];
  if (!site.snapshot) {
    reasons.push("等待首次心跳");
  } else if (!site.online) {
    reasons.push("心跳已超时");
  }
  if (site.snapshot?.latest.recovery) {
    reasons.push("处于恢复模式");
  }
  if (site.snapshot && site.snapshot.latest.applied_revision !== site.revision) {
    reasons.push(
      `待同步 (${site.snapshot.latest.applied_revision}/${site.revision})`,
    );
  }
  if (site.snapshot?.latest.event === "failed") {
    reasons.push("最近同步失败");
  }

  if (!site.online) {
    return { health: site.snapshot ? "offline" : "attention", reasons };
  }
  if (reasons.length > 0) {
    return { health: "attention", reasons };
  }
  return { health: "online", reasons: ["运行正常"] };
}

export function siteHealthLabel(health: SiteHealth): string {
  switch (health) {
    case "online":
      return "在线";
    case "attention":
      return "需关注";
    case "offline":
      return "离线";
  }
}

export function rttTier(rtt: number | undefined): "low" | "mid" | "high" | "none" {
  if (rtt == null) return "none";
  if (rtt < 80) return "low";
  if (rtt < 180) return "mid";
  return "high";
}

export function trendDomain(points: Trend[], key: "download_bps" | "upload_bps" | "rtt_ms"): number[] {
  return points.map((point) => point[key] ?? 0);
}
