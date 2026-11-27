import type { Heartbeat, Snapshot, Trend } from "./contracts.js";

export type RecordValue = Record<string, unknown>;
export function record(input: unknown): input is RecordValue {
  return input !== null && typeof input === "object" && !Array.isArray(input);
}
export function only(value: RecordValue, keys: string[]) {
  return Object.keys(value).every((key) => keys.includes(key));
}
export const siteId = (value: unknown): value is string =>
  typeof value === "string" && /^[a-z][a-z0-9-]{1,47}$/.test(value);
export const sourceId = (value: unknown): value is string =>
  typeof value === "string" && /^[a-z][a-z0-9_-]{1,47}$/.test(value);
const identifier = (value: unknown) =>
  typeof value === "string" && /^[a-z][a-z0-9_-]{0,47}$/i.test(value);
const magnitude = (value: unknown) =>
  typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
const mode = ["netfleet", "mihomo", "openwrt", "unknown"];
const events = ["updated", "unchanged", "failed", "recovering", "restored"];

export function validHeartbeat(value: unknown): value is Heartbeat {
  if (
    !record(value) ||
    !only(value, [
      "site_id",
      "applied_revision",
      "mode",
      "capabilities",
      "traffic",
      "quotas",
      "recovery",
      "event",
    ]) ||
    !siteId(value.site_id) ||
    !magnitude(value.applied_revision) ||
    typeof value.mode !== "string" ||
    !mode.includes(value.mode)
  )
    return false;
  if (
    !Array.isArray(value.capabilities) ||
    value.capabilities.length > 32 ||
    value.capabilities.some(
      (item) =>
        !record(item) ||
        !only(item, ["id", "region", "node", "provider", "rtt_ms"]) ||
        !identifier(item.id) ||
        (item.region !== undefined && !identifier(item.region)) ||
        (item.provider !== undefined && !identifier(item.provider)) ||
        (item.node !== undefined &&
          (typeof item.node !== "string" ||
            !/^node-[a-f0-9]{12}$/.test(item.node))) ||
        (item.rtt_ms !== undefined &&
          (!magnitude(item.rtt_ms) || Number(item.rtt_ms) > 600000)),
    )
  )
    return false;
  if (
    !record(value.traffic) ||
    !only(value.traffic, [
      "upload_bps",
      "download_bps",
      "upload_bytes",
      "download_bytes",
    ]) ||
    !Object.values(value.traffic).every(magnitude)
  )
    return false;
  if (
    value.quotas !== undefined &&
    (!Array.isArray(value.quotas) ||
      value.quotas.length > 32 ||
      value.quotas.some(
        (item) =>
          !record(item) ||
          !only(item, ["provider", "remaining_bytes", "total_bytes"]) ||
          !identifier(item.provider) ||
          (item.remaining_bytes !== undefined &&
            !magnitude(item.remaining_bytes)) ||
          (item.total_bytes !== undefined && !magnitude(item.total_bytes)),
      ))
  )
    return false;
  return (
    (value.recovery === undefined || typeof value.recovery === "boolean") &&
    (value.event === undefined ||
      (typeof value.event === "string" && events.includes(value.event)))
  );
}

export function snapshot(
  old: Snapshot | null,
  value: Heartbeat,
  now: number,
): Snapshot {
  const window = 600000;
  const at = new Date(Math.floor(now / window) * window).toISOString();
  const sample: Trend = { at, ...value.traffic };
  const delays = value.capabilities.flatMap((item) =>
    item.rtt_ms === undefined ? [] : [item.rtt_ms],
  );
  if (delays.length)
    sample.rtt_ms = Math.round(
      delays.reduce((sum, delay) => sum + delay, 0) / delays.length,
    );
  const trend = (old?.trend ?? []).filter(
    (point) => point.at !== at && Date.parse(point.at) >= now - 86400000,
  );
  trend.push(sample);
  return {
    last_seen_at: new Date(now).toISOString(),
    latest: value,
    trend: trend.slice(-144),
  };
}
