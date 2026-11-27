import type { Snapshot, Trend } from "../contracts.js";

export type Site = {
  id: string;
  name: string;
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
  unauthorized: "Authentication failed or session expired. Sign in with an authorized Gateway Access Token.",
  origin_forbidden: "Cross-site state-changing requests are blocked by same-origin policy.",
  invalid_site: "Site ID must match ^[a-z][a-z0-9-]{1,47}$ and display name must be 1–120 printable characters.",
  site_exists: "A site with that identifier already exists.",
  site_limit: "Maximum configured site capacity (64) has been reached.",
  site_not_found: "Site was not found or belongs to another owner.",
  invalid_subscription: "Provide a lowercase source ID, printable name, and HTTPS subscription URL.",
  subscription_exists: "A subscription with that identifier already exists.",
  subscription_limit: "Maximum configured subscription pool capacity (64) has been reached.",
  subscription_not_found: "Subscription source was not found or has already been removed.",
  invalid_grants: "Grant selection must reference valid subscription IDs (up to 16 per site).",
  service_unavailable: "Cloud control plane temporarily unavailable. Retry in a few seconds.",
};

export class ApiError extends Error {
  readonly code?: string;

  constructor(readonly status: number, code?: string) {
    super(
      (code && ERROR_MESSAGES[code]) ||
        `Request failed with HTTP ${status}${code ? ` (${code})` : ""}.`,
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
  if (!iso) return "Never";
  const parsed = Date.parse(iso);
  if (!Number.isFinite(parsed)) return "Unknown";
  const diffSec = Math.max(0, Math.round((Date.now() - parsed) / 1000));
  if (diffSec < 10) return "just now";
  if (diffSec < 60) return `${diffSec}s ago`;
  const diffMin = Math.round(diffSec / 60);
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHr = Math.round(diffMin / 60);
  if (diffHr < 48) return `${diffHr}h ago`;
  return `${Math.round(diffHr / 24)}d ago`;
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
    reasons.push("Awaiting first heartbeat");
  } else if (!site.online) {
    reasons.push("Heartbeat overdue");
  }
  if (site.snapshot?.latest.recovery) {
    reasons.push("Recovery mode active");
  }
  if (site.snapshot && site.snapshot.latest.applied_revision !== site.revision) {
    reasons.push(
      `Revision lag (${site.snapshot.latest.applied_revision}/${site.revision})`,
    );
  }
  if (site.snapshot?.latest.event === "failed") {
    reasons.push("Last sync event failed");
  }

  if (!site.online) {
    return { health: site.snapshot ? "offline" : "attention", reasons };
  }
  if (reasons.length > 0) {
    return { health: "attention", reasons };
  }
  return { health: "online", reasons: ["Healthy"] };
}

export function siteHealthLabel(health: SiteHealth): string {
  switch (health) {
    case "online":
      return "Online";
    case "attention":
      return "Attention";
    case "offline":
      return "Offline";
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
