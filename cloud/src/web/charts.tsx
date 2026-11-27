import type { ReactNode } from "react";
import type { Trend } from "../contracts.js";
import { formatBps, formatShortTime, rttTier } from "./api.js";

function SvgIcon({
  children,
  className,
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <svg
      className={className ? `icon ${className}` : "icon"}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.6}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {children}
    </svg>
  );
}

export function BrandMark() {
  return (
    <svg className="brand-mark" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <rect
        x="2.5"
        y="2.5"
        width="19"
        height="19"
        rx="5"
        stroke="currentColor"
        strokeWidth="1.7"
      />
      <circle cx="8" cy="12" r="2" fill="currentColor" />
      <circle cx="16" cy="8.5" r="1.75" stroke="currentColor" strokeWidth="1.6" />
      <circle cx="16" cy="15.5" r="1.75" stroke="currentColor" strokeWidth="1.6" />
      <path
        d="M9.8 11.2L14.3 9.1M9.8 12.8L14.3 14.9"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
      />
    </svg>
  );
}

export const IconOverview = () => (
  <SvgIcon>
    <rect x="2.2" y="2.2" width="4.8" height="4.8" rx="1" />
    <rect x="9" y="2.2" width="4.8" height="4.8" rx="1" />
    <rect x="2.2" y="9" width="4.8" height="4.8" rx="1" />
    <rect x="9" y="9" width="4.8" height="4.8" rx="1" />
  </SvgIcon>
);

export const IconSites = () => (
  <SvgIcon>
    <rect x="2.2" y="2.8" width="11.6" height="4.2" rx="1" />
    <rect x="2.2" y="9" width="11.6" height="4.2" rx="1" />
    <circle cx="4.8" cy="4.9" r="0.6" fill="currentColor" stroke="none" />
    <circle cx="4.8" cy="11.1" r="0.6" fill="currentColor" stroke="none" />
  </SvgIcon>
);

export const IconSubscriptions = () => (
  <SvgIcon>
    <path d="M2.5 5.2L8 2.3l5.5 2.9v5.6L8 13.7l-5.5-2.9V5.2z" />
    <path d="M2.5 5.2L8 8.1l5.5-2.9M8 8.1v5.6" />
  </SvgIcon>
);

export const IconSearch = () => (
  <SvgIcon>
    <circle cx="7" cy="7" r="4.5" />
    <path d="M10.5 10.5L13.8 13.8" />
  </SvgIcon>
);

export const IconSun = () => (
  <SvgIcon>
    <circle cx="8" cy="8" r="2.8" />
    <path d="M8 2v1.3M8 12.7V14M2 8h1.3M12.7 8H14M3.8 3.8l.9.9M11.3 11.3l.9.9M12.2 3.8l-.9.9M4.7 11.3l-.9.9" />
  </SvgIcon>
);

export const IconMoon = () => (
  <SvgIcon>
    <path d="M12.8 9.8A5 5 0 016.2 3.2a5.2 5.2 0 106.6 6.6z" />
  </SvgIcon>
);

export const IconMonitor = () => (
  <SvgIcon>
    <rect x="2" y="2.6" width="12" height="8.4" rx="1.2" />
    <path d="M5.5 13.4h5M8 11v2.4" />
  </SvgIcon>
);

export const IconRefresh = ({ spinning }: { spinning?: boolean }) => (
  <SvgIcon className={spinning ? "spin" : undefined}>
    <path d="M13.3 7.5A5.4 5.4 0 004 4.2L2.6 5.6M2.7 2.8v2.8h2.8M2.7 8.5A5.4 5.4 0 0012 11.8l1.4-1.4M13.3 13.2v-2.8h-2.8" />
  </SvgIcon>
);

export const IconSignOut = () => (
  <SvgIcon>
    <path d="M6.2 2.5H3.5a1 1 0 00-1 1v9a1 1 0 001 1h2.7M10.5 11l3-3-3-3M13.5 8H6" />
  </SvgIcon>
);

export const IconPlus = () => (
  <SvgIcon>
    <path d="M8 3.2v9.6M3.2 8h9.6" />
  </SvgIcon>
);

export const IconKey = () => (
  <SvgIcon>
    <circle cx="5.5" cy="9.5" r="2.8" />
    <path d="M7.6 7.5l5.4-5.4M11 4.1l2 2M12.6 2.5l1.5 1.5" />
  </SvgIcon>
);

export const IconTrash = () => (
  <SvgIcon>
    <path d="M3 4.5h10M6 4.5V3h4v1.5M4.5 4.5l.6 8.5a1 1 0 001 .9h3.8a1 1 0 001-.9l.6-8.5" />
  </SvgIcon>
);

export const IconCopy = () => (
  <SvgIcon>
    <rect x="5.5" y="5.5" width="7.8" height="7.8" rx="1.2" />
    <path d="M10.5 5.5V3.7a1 1 0 00-1-1H3.7a1 1 0 00-1 1v5.8a1 1 0 001 1h1.8" />
  </SvgIcon>
);

export const IconCheck = () => (
  <SvgIcon>
    <path d="M3.2 8.4l3 3 6.6-6.8" />
  </SvgIcon>
);

export const IconAlert = () => (
  <SvgIcon>
    <path d="M8 2.4L14 13H2L8 2.4z" />
    <path d="M8 6.4v3.2" />
    <circle cx="8" cy="11.3" r="0.6" fill="currentColor" stroke="none" />
  </SvgIcon>
);

export const IconMenu = () => (
  <SvgIcon>
    <path d="M2.5 4.5h11M2.5 8h11M2.5 11.5h11" />
  </SvgIcon>
);

export const IconClose = () => (
  <SvgIcon>
    <path d="M3.8 3.8l8.4 8.4M12.2 3.8l-8.4 8.4" />
  </SvgIcon>
);

export const IconChevronRight = () => (
  <SvgIcon>
    <path d="M6 3.5L10.5 8 6 12.5" />
  </SvgIcon>
);

export const IconEdit = () => (
  <SvgIcon>
    <path d="M9.8 3.2l3 3-7.3 7.3H2.5v-3l7.3-7.3z" />
  </SvgIcon>
);

export const IconTable = () => (
  <SvgIcon>
    <rect x="2.2" y="2.8" width="11.6" height="10.4" rx="1" />
    <path d="M2.2 6.5h11.6M6.5 6.5v6.7" />
  </SvgIcon>
);

export const IconGrid = () => (
  <SvgIcon>
    <rect x="2.2" y="2.2" width="5" height="5" rx="1" />
    <rect x="8.8" y="2.2" width="5" height="5" rx="1" />
    <rect x="2.2" y="8.8" width="5" height="5" rx="1" />
    <rect x="8.8" y="8.8" width="5" height="5" rx="1" />
  </SvgIcon>
);

export const IconEye = ({ open }: { open: boolean }) => (
  <SvgIcon>
    <path d="M1.8 8s2.4-4 6.2-4 6.2 4 6.2 4-2.4 4-6.2 4-6.2-4-6.2-4z" />
    <circle cx="8" cy="8" r="1.7" />
    {!open && <path d="M2.6 13.4L13.4 2.6" />}
  </SvgIcon>
);

export function ThroughputSparkline({
  points,
  label,
}: {
  points: Trend[];
  label: string;
}) {
  const recent = points.slice(-24);
  const series = recent.map((point) => point.download_bps ?? point.upload_bps ?? 0);
  if (series.length < 2) {
    return <span className="muted mono-xs">暂无采样</span>;
  }
  const width = 112;
  const height = 26;
  const padY = 3;
  const max = Math.max(1, ...series);
  const coords = series.map((value, index) => {
    const x = (index / (series.length - 1)) * width;
    const y = height - padY - (value / max) * (height - padY * 2);
    return { x: Number(x.toFixed(1)), y: Number(y.toFixed(1)) };
  });
  const line = coords.map((p, idx) => `${idx === 0 ? "M" : "L"}${p.x} ${p.y}`).join(" ");
  const area = `${line} L${width} ${height} L0 ${height} Z`;
  const last = coords[coords.length - 1];

  return (
    <svg
      className="sparkline-svg"
      viewBox={`0 0 ${width} ${height}`}
      role="img"
      aria-label={label}
    >
      <path className="spark-area" d={area} />
      <path className="spark-line" d={line} />
      <circle className="spark-dot" cx={last.x} cy={last.y} r="2.2" />
    </svg>
  );
}

export function PulseStrip({
  points,
  online,
  slots = 40,
}: {
  points: Trend[];
  online: boolean;
  slots?: number;
}) {
  const slice = points.slice(-slots);
  const pad = Math.max(0, slots - slice.length);
  const width = slots * 6;
  const height = 22;

  return (
    <svg
      className="pulse-svg"
      viewBox={`0 0 ${width} ${height}`}
      role="img"
      aria-label={
        slice.length
          ? `${slice.length} 个心跳采样窗口（${online ? "在线" : "离线"}）`
          : "暂无心跳历史"
      }
    >
      {Array.from({ length: slots }, (_, index) => {
        const point = index >= pad ? slice[index - pad] : undefined;
        const tier = point ? rttTier(point.rtt_ms) : "empty";
        const cls = point
          ? tier === "high"
            ? "pulse-tick is-high"
            : tier === "mid"
              ? "pulse-tick is-mid"
              : "pulse-tick is-ok"
          : "pulse-tick is-empty";
        return (
          <rect
            key={index}
            className={cls}
            x={index * 6 + 1}
            y={point ? 2 : 6}
            width="3.6"
            height={point ? 18 : 10}
            rx="1.2"
          >
            {point && (
              <title>
                {`${formatShortTime(point.at)} · ${
                  point.rtt_ms != null ? `${point.rtt_ms} ms` : "无 RTT"
                } · 下行 ${formatBps(point.download_bps)}`}
              </title>
            )}
          </rect>
        );
      })}
    </svg>
  );
}

export function ThroughputAreaChart({ points }: { points: Trend[] }) {
  const recent = points.slice(-48);
  const down = recent.map((p) => p.download_bps ?? 0);
  const up = recent.map((p) => p.upload_bps ?? 0);
  const hasAny = recent.some(
    (p) => p.download_bps != null || p.upload_bps != null,
  );
  if (recent.length < 2 || !hasAny) {
    return (
      <div className="chart-empty">
        <p className="muted">至少需要 2 个速率采样窗口才能绘制吞吐趋势。</p>
      </div>
    );
  }

  const width = 620;
  const height = 160;
  const padX = 6;
  const padY = 12;
  const maxRate = Math.max(1000, ...down, ...up);
  const plotW = width - padX * 2;
  const plotH = height - padY * 2;

  const toPath = (values: number[]) =>
    values
      .map((val, idx) => {
        const x = padX + (idx / (values.length - 1)) * plotW;
        const y = padY + plotH - (val / maxRate) * plotH;
        return `${idx === 0 ? "M" : "L"}${x.toFixed(1)} ${y.toFixed(1)}`;
      })
      .join(" ");

  const downLine = toPath(down);
  const downArea = `${downLine} L${(padX + plotW).toFixed(1)} ${padY + plotH} L${padX} ${padY + plotH} Z`;
  const upLine = toPath(up);
  const peakDown = Math.max(...down);
  const peakUp = Math.max(...up);
  const latest = recent[recent.length - 1];

  return (
    <div className="chart-frame">
      <div className="chart-meta-row">
        <div className="chart-legend">
          <span className="legend-item">
            <span className="legend-swatch is-primary" aria-hidden="true" />
            下行 <strong>{formatBps(latest.download_bps)}</strong>
            <span className="muted">峰值 {formatBps(peakDown)}</span>
          </span>
          <span className="legend-item">
            <span className="legend-swatch is-secondary" aria-hidden="true" />
            上行 <strong>{formatBps(latest.upload_bps)}</strong>
            <span className="muted">峰值 {formatBps(peakUp)}</span>
          </span>
        </div>
        <span className="muted mono-xs">量程上限 {formatBps(maxRate)}</span>
      </div>
      <svg
        className="telemetry-svg"
        viewBox={`0 0 ${width} ${height}`}
        role="img"
        aria-label="上下行吞吐趋势图"
      >
        {[0, 0.25, 0.5, 0.75, 1].map((step) => {
          const y = Number((padY + plotH * step).toFixed(1));
          return (
            <line
              key={step}
              className="chart-grid"
              x1={padX}
              y1={y}
              x2={width - padX}
              y2={y}
            />
          );
        })}
        <path className="chart-area-primary" d={downArea} />
        <path className="chart-line-secondary" d={upLine} />
        <path className="chart-line-primary" d={downLine} />
      </svg>
      <div className="chart-axis mono-xs muted">
        <span>{formatShortTime(recent[0].at)}</span>
        <span>{recent.length} 个窗口（10 分钟粒度）</span>
        <span>{formatShortTime(latest.at)}</span>
      </div>
    </div>
  );
}

export function RttBarChart({ points }: { points: Trend[] }) {
  const recent = points.slice(-40).filter((p) => p.rtt_ms != null);
  if (!recent.length) {
    return (
      <div className="chart-empty">
        <p className="muted">近期采样窗口内暂无出口 RTT 测量数据。</p>
      </div>
    );
  }

  const width = 620;
  const height = 136;
  const padX = 6;
  const padY = 12;
  const plotW = width - padX * 2;
  const plotH = height - padY * 2;
  const values = recent.map((p) => p.rtt_ms ?? 0);
  const maxRtt = Math.max(50, ...values);
  const avgRtt = Math.round(values.reduce((sum, v) => sum + v, 0) / values.length);
  const latestRtt = values[values.length - 1];
  const slotW = plotW / recent.length;
  const barW = Math.max(3, Math.min(12, slotW - 3));

  return (
    <div className="chart-frame">
      <div className="chart-meta-row">
        <div className="chart-legend">
          <span className="legend-item">
            最新 <strong>{latestRtt} ms</strong>
          </span>
          <span className="legend-item">
            均值 <strong>{avgRtt} ms</strong>
          </span>
          <span className="legend-item">
            峰值 <strong>{Math.max(...values)} ms</strong>
          </span>
        </div>
        <span className="muted mono-xs">量程 0–{maxRtt} ms</span>
      </div>
      <svg
        className="telemetry-svg"
        viewBox={`0 0 ${width} ${height}`}
        role="img"
        aria-label="出口 RTT 延迟柱状图"
      >
        {[0, 0.5, 1].map((step) => {
          const y = Number((padY + plotH * step).toFixed(1));
          return (
            <line
              key={step}
              className="chart-grid"
              x1={padX}
              y1={y}
              x2={width - padX}
              y2={y}
            />
          );
        })}
        {recent.map((point, index) => {
          const value = point.rtt_ms ?? 0;
          const barH = Math.max(4, (value / maxRtt) * plotH);
          const x = padX + index * slotW + (slotW - barW) / 2;
          const y = padY + plotH - barH;
          const tier = rttTier(value);
          return (
            <rect
              key={point.at}
              className={`rtt-bar is-${tier}`}
              x={Number(x.toFixed(1))}
              y={Number(y.toFixed(1))}
              width={Number(barW.toFixed(1))}
              height={Number(barH.toFixed(1))}
              rx="1.5"
            >
              <title>{`${formatShortTime(point.at)} · ${value} ms`}</title>
            </rect>
          );
        })}
      </svg>
      <div className="chart-axis mono-xs muted">
        <span>{formatShortTime(recent[0].at)}</span>
        <span>{recent.length} 个延迟窗口</span>
        <span>{formatShortTime(recent[recent.length - 1].at)}</span>
      </div>
    </div>
  );
}

export function QuotaProgressSvg({
  remaining,
  total,
}: {
  remaining: number;
  total: number;
}) {
  const ratio = total > 0 ? Math.max(0, Math.min(1, remaining / total)) : 0;
  const fillWidth = Number((ratio * 200).toFixed(1));
  const tone = ratio <= 0.1 ? "is-danger" : ratio <= 0.25 ? "is-warn" : "is-ok";

  return (
    <svg
      className="quota-svg"
      viewBox="0 0 200 8"
      preserveAspectRatio="none"
      role="img"
      aria-label={`剩余配额 ${Math.round(ratio * 100)}%`}
    >
      <rect className="quota-track" x="0" y="0" width="200" height="8" rx="4" />
      <rect
        className={`quota-fill ${tone}`}
        x="0"
        y="0"
        width={fillWidth}
        height="8"
        rx="4"
      />
    </svg>
  );
}
