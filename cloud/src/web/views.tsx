import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type FormEvent,
  type KeyboardEvent,
} from "react";
import {
  classifySite,
  formatBps,
  formatBytes,
  formatRelativeTime,
  isRevisionSynced,
  rttTier,
  siteHealthLabel,
  siteMedianRtt,
  type Site,
  type SiteFilter,
  type Source,
  type ViewMode,
} from "./api.js";
import {
  BrandMark,
  IconAlert,
  IconCheck,
  IconEdit,
  IconEye,
  IconGrid,
  IconKey,
  IconPlus,
  IconSearch,
  IconTable,
  IconTrash,
  PulseStrip,
  QuotaProgressSvg,
  RttBarChart,
  ThroughputAreaChart,
  ThroughputSparkline,
} from "./charts.js";

export function LoginView({
  busy,
  error,
  onLogin,
}: {
  busy: boolean;
  error: string;
  onLogin: (token: string) => Promise<void>;
}) {
  const [showToken, setShowToken] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = event.currentTarget;
    const raw = String(new FormData(form).get("token") ?? "").trim();
    if (!raw) return;
    form.reset();
    await onLogin(raw);
  }

  return (
    <main className="login-shell">
      <section className="login-card" aria-labelledby="login-title">
        <div className="login-brand">
          <BrandMark />
          <div className="login-heading">
            <h1 id="login-title">OPL NetFleet Cloud</h1>
            <p className="muted">Multi-site gateway telemetry and encrypted subscription control plane</p>
          </div>
        </div>
        <form className="form-stack" onSubmit={submit}>
          <div className="field-group">
            <label htmlFor="gateway-token">Gateway Access Token</label>
            <div className="input-with-action">
              <input
                id="gateway-token"
                name="token"
                type={showToken ? "text" : "password"}
                autoComplete="off"
                required
                placeholder="Paste authorized Gateway Bearer token"
              />
              <button
                type="button"
                className="icon-btn"
                aria-label={showToken ? "Hide access token" : "Reveal access token"}
                onClick={() => setShowToken((prev) => !prev)}
              >
                <IconEye open={showToken} />
              </button>
            </div>
            <p className="field-hint">
              Verified upstream against OPL Gateway <code>/api/v1/auth/me</code> and bound to a short-lived <code>HttpOnly; SameSite=Lax</code> cookie.
            </p>
          </div>
          {error && (
            <p className="inline-error" role="alert">
              {error}
            </p>
          )}
          <button type="submit" className="btn primary btn-full" disabled={busy}>
            {busy ? "Verifying session…" : "Sign in"}
          </button>
        </form>
      </section>
    </main>
  );
}

export function OverviewView({
  sites,
  sources,
  onOpenSite,
  onAddSite,
  onOpenSubscriptions,
}: {
  sites: Site[];
  sources: Source[];
  onOpenSite: (id: string) => void;
  onAddSite: () => void;
  onOpenSubscriptions: () => void;
}) {
  const [filter, setFilter] = useState<SiteFilter>("all");
  const [search, setSearch] = useState("");
  const [viewMode, setViewMode] = useState<ViewMode>("table");

  const stats = useMemo(() => {
    let onlineCount = 0;
    let offlineCount = 0;
    let attentionCount = 0;
    let totalDownBps = 0;
    let totalUpBps = 0;
    let activeExits = 0;
    const rttList: number[] = [];
    const attentionSites: { site: Site; health: "attention" | "offline"; reasons: string[] }[] = [];

    for (const site of sites) {
      const classified = classifySite(site);
      if (site.online) onlineCount += 1;
      else if (site.snapshot) offlineCount += 1;
      if (classified.health !== "online") {
        attentionCount += 1;
        attentionSites.push({
          site,
          health: classified.health,
          reasons: classified.reasons,
        });
      }
      const latest = site.snapshot?.latest;
      if (site.online && latest) {
        totalDownBps += latest.traffic.download_bps ?? 0;
        totalUpBps += latest.traffic.upload_bps ?? 0;
      }
      if (latest) {
        activeExits += latest.capabilities.length;
        for (const cap of latest.capabilities) {
          if (typeof cap.rtt_ms === "number") rttList.push(cap.rtt_ms);
        }
      }
    }

    rttList.sort((a, b) => a - b);
    const medianRtt = rttList.length ? rttList[Math.floor(rttList.length / 2)] : null;
    const syncedCount = sites.filter(isRevisionSynced).length;

    return {
      onlineCount,
      offlineCount,
      attentionCount,
      totalDownBps,
      totalUpBps,
      activeExits,
      medianRtt,
      syncedCount,
      attentionSites,
    };
  }, [sites]);

  const filteredSites = useMemo(() => {
    const needle = search.trim().toLowerCase();
    return sites.filter((site) => {
      const { health } = classifySite(site);
      if (filter !== "all" && health !== filter) return false;
      if (!needle) return true;
      const caps = (site.snapshot?.latest.capabilities ?? [])
        .flatMap((c) => [c.id, c.region, c.provider])
        .filter(Boolean)
        .join(" ");
      return (
        site.name.toLowerCase().includes(needle) ||
        site.id.toLowerCase().includes(needle) ||
        caps.toLowerCase().includes(needle)
      );
    });
  }, [sites, filter, search]);

  return (
    <div className="page-stack">
      <div className="page-header">
        <div>
          <h1>Fleet Overview</h1>
          <p className="muted">
            Live multi-site gateway status, egress latency, throughput, and desired config revision alignment.
          </p>
        </div>
        <div className="header-actions">
          <button type="button" className="btn secondary" onClick={onOpenSubscriptions}>
            Manage Subscriptions ({sources.length})
          </button>
          <button type="button" className="btn primary" onClick={onAddSite}>
            <IconPlus />
            <span>Add Site</span>
          </button>
        </div>
      </div>

      <section className="kpi-strip" aria-label="Fleet telemetry summary">
        <div className="kpi-cell">
          <span className="kpi-label">SITES ONLINE</span>
          <strong className="kpi-value tabular">
            {stats.onlineCount} / {sites.length}
          </strong>
          <span className="kpi-sub muted tabular">
            {stats.syncedCount} synced · {stats.offlineCount} offline
          </span>
        </div>
        <div className="kpi-cell">
          <span className="kpi-label">LIVE THROUGHPUT</span>
          <strong className="kpi-value tabular">↓ {formatBps(stats.totalDownBps)}</strong>
          <span className="kpi-sub muted tabular">↑ {formatBps(stats.totalUpBps)} upload</span>
        </div>
        <div className="kpi-cell">
          <span className="kpi-label">MEDIAN EXIT RTT</span>
          <strong className="kpi-value tabular">
            {stats.medianRtt != null ? `${stats.medianRtt} ms` : "No RTT"}
          </strong>
          <span className="kpi-sub muted tabular">
            {stats.activeExits} reported capabilities
          </span>
        </div>
        <div className="kpi-cell">
          <span className="kpi-label">POOL &amp; ALERTS</span>
          <strong className="kpi-value tabular">{sources.length} sources</strong>
          <span className="kpi-sub muted tabular">
            {stats.attentionCount} requiring attention
          </span>
        </div>
      </section>

      {stats.attentionSites.length > 0 && (
        <section className="attention-panel" aria-labelledby="attention-heading">
          <div className="attention-head">
            <div className="attention-title">
              <IconAlert />
              <h2 id="attention-heading">Needs Attention</h2>
            </div>
            <span className="mono-xs muted tabular">
              {stats.attentionSites.length} site{stats.attentionSites.length === 1 ? "" : "s"}
            </span>
          </div>
          <ul className="attention-list">
            {stats.attentionSites.map(({ site, health, reasons }) => (
              <li key={site.id} className="attention-row">
                <div className="attention-meta">
                  <span
                    className={
                      health === "offline" ? "status-dot is-offline" : "status-dot is-warn"
                    }
                    aria-hidden="true"
                  />
                  <strong>{site.name}</strong>
                  <code className="mono-pill">{site.id}</code>
                  <span className="attention-reasons">{reasons.join(" · ")}</span>
                </div>
                <button
                  type="button"
                  className="btn-inline-link"
                  onClick={() => onOpenSite(site.id)}
                >
                  Inspect
                </button>
              </li>
            ))}
          </ul>
        </section>
      )}

      <section className="panel" aria-labelledby="sites-directory-heading">
        <div className="panel-toolbar">
          <div className="panel-title-group">
            <h2 id="sites-directory-heading">Sites</h2>
            <span className="count-badge tabular">{filteredSites.length}</span>
          </div>
          <div className="toolbar-controls">
            <div className="filter-pills" role="group" aria-label="Filter sites by status">
              {(["all", "online", "attention", "offline"] as SiteFilter[]).map((key) => (
                <button
                  key={key}
                  type="button"
                  className={filter === key ? "pill-btn is-active" : "pill-btn"}
                  aria-pressed={filter === key}
                  onClick={() => setFilter(key)}
                >
                  {key === "all" ? "All" : siteHealthLabel(key)}
                </button>
              ))}
            </div>
            <div className="search-input-wrap">
              <IconSearch />
              <label htmlFor="site-filter-search" className="sr-only">
                Filter sites
              </label>
              <input
                id="site-filter-search"
                type="search"
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="Filter sites, regions, exits…"
              />
            </div>
            <div className="view-switch" role="group" aria-label="Layout mode">
              <button
                type="button"
                className={viewMode === "table" ? "switch-btn is-active" : "switch-btn"}
                aria-pressed={viewMode === "table"}
                onClick={() => setViewMode("table")}
                title="Table view"
              >
                <IconTable />
                <span>Table</span>
              </button>
              <button
                type="button"
                className={viewMode === "cards" ? "switch-btn is-active" : "switch-btn"}
                aria-pressed={viewMode === "cards"}
                onClick={() => setViewMode("cards")}
                title="Card view"
              >
                <IconGrid />
                <span>Cards</span>
              </button>
            </div>
          </div>
        </div>

        {sites.length === 0 ? (
          <div className="empty-state">
            <h3>No sites registered yet</h3>
            <p className="muted">
              Register your first OpenWrt or gateway router to monitor exit latency, throughput, and push isolated encrypted subscriptions.
            </p>
            <button type="button" className="btn primary" onClick={onAddSite}>
              <IconPlus />
              <span>Add first site</span>
            </button>
          </div>
        ) : filteredSites.length === 0 ? (
          <div className="empty-state">
            <h3>No sites match your filter</h3>
            <p className="muted">Clear the active status pill or search query to inspect all sites.</p>
            <button
              type="button"
              className="btn secondary"
              onClick={() => {
                setFilter("all");
                setSearch("");
              }}
            >
              Reset filters
            </button>
          </div>
        ) : viewMode === "table" ? (
          <div
            tabIndex={0}
            role="region"
            aria-labelledby="sites-directory-heading"
            className="table-wrapper"
          >
            <table className="data-table">
              <thead>
                <tr>
                  <th scope="col">Site</th>
                  <th scope="col">Status</th>
                  <th scope="col">Active Exits</th>
                  <th scope="col">Latency</th>
                  <th scope="col">Rate &amp; Trend</th>
                  <th scope="col">Revision</th>
                  <th scope="col">Grants</th>
                  <th scope="col" className="col-right">
                    Action
                  </th>
                </tr>
              </thead>
              <tbody>
                {filteredSites.map((site) => {
                  const { health } = classifySite(site);
                  const latest = site.snapshot?.latest;
                  const median = siteMedianRtt(site);
                  const tier = rttTier(median ?? undefined);
                  const synced = isRevisionSynced(site);
                  return (
                    <tr key={site.id}>
                      <th scope="row" className="sticky-col">
                        <button
                          type="button"
                          className="row-title-btn"
                          onClick={() => onOpenSite(site.id)}
                        >
                          <span className="row-title-text">{site.name}</span>
                          <span className="mono-xs muted">{site.id}</span>
                        </button>
                      </th>
                      <td data-label="Status">
                        <span className={`status-pill is-${health}`}>
                          <span className={`status-dot is-${health}`} aria-hidden="true" />
                          <span>{siteHealthLabel(health)}</span>
                        </span>
                        <div className="cell-sub muted mono-xs">
                          {site.snapshot
                            ? `${latest?.mode ?? "unknown"} · ${formatRelativeTime(site.snapshot.last_seen_at)}`
                            : "No heartbeat"}
                        </div>
                      </td>
                      <td data-label="Active Exits">
                        {latest?.capabilities.length ? (
                          <div className="exit-chip-list">
                            {latest.capabilities.slice(0, 2).map((cap) => (
                              <span key={cap.id} className="exit-chip">
                                {cap.id}
                                {cap.region ? ` · ${cap.region}` : ""}
                              </span>
                            ))}
                            {latest.capabilities.length > 2 && (
                              <span className="mono-xs muted">
                                +{latest.capabilities.length - 2}
                              </span>
                            )}
                          </div>
                        ) : (
                          <span className="muted">—</span>
                        )}
                      </td>
                      <td data-label="Latency">
                        {median != null ? (
                          <span className={`rtt-pill is-${tier} tabular`}>{median} ms</span>
                        ) : (
                          <span className="muted tabular">—</span>
                        )}
                      </td>
                      <td data-label="Rate & Trend">
                        <div className="rate-spark-cell">
                          <div className="tabular mono-xs rate-lines">
                            <div>↓ {formatBps(latest?.traffic.download_bps)}</div>
                            <div className="muted">↑ {formatBps(latest?.traffic.upload_bps)}</div>
                          </div>
                          <ThroughputSparkline
                            points={site.snapshot?.trend ?? []}
                            label={`${site.name} throughput sparkline`}
                          />
                        </div>
                      </td>
                      <td data-label="Revision">
                        <span
                          className={
                            synced
                              ? "rev-pill is-synced tabular"
                              : "rev-pill is-pending tabular"
                          }
                        >
                          {latest?.applied_revision ?? "—"} / {site.revision}
                        </span>
                      </td>
                      <td data-label="Grants">
                        <span className="tabular">
                          {site.grants.length} sub{site.grants.length === 1 ? "" : "s"}
                        </span>
                        <div className="cell-sub muted mono-xs">
                          {site.token_active ? "Token active" : "No token"}
                        </div>
                      </td>
                      <td data-label="Action" className="col-right">
                        <button
                          type="button"
                          className="btn secondary btn-sm"
                          onClick={() => onOpenSite(site.id)}
                        >
                          Details
                        </button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="site-card-grid">
            {filteredSites.map((site) => {
              const { health, reasons } = classifySite(site);
              const latest = site.snapshot?.latest;
              const median = siteMedianRtt(site);
              const synced = isRevisionSynced(site);

              return (
                <article key={site.id} className="site-card">
                  <header className="site-card-head">
                    <div className="site-card-title">
                      <h3>
                        <button
                          type="button"
                          className="card-link-btn"
                          onClick={() => onOpenSite(site.id)}
                        >
                          {site.name}
                        </button>
                      </h3>
                      <code className="mono-xs muted">{site.id}</code>
                    </div>
                    <span className={`status-pill is-${health}`}>
                      <span className={`status-dot is-${health}`} aria-hidden="true" />
                      <span>{siteHealthLabel(health)}</span>
                    </span>
                  </header>

                  <div className="site-card-pulse">
                    <PulseStrip
                      points={site.snapshot?.trend ?? []}
                      online={site.online}
                      slots={28}
                    />
                    <span className="mono-xs muted tabular">
                      {formatRelativeTime(site.snapshot?.last_seen_at)}
                    </span>
                  </div>

                  <dl className="site-card-metrics tabular">
                    <div>
                      <dt>Throughput</dt>
                      <dd>
                        ↓ {formatBps(latest?.traffic.download_bps)} · ↑{" "}
                        {formatBps(latest?.traffic.upload_bps)}
                      </dd>
                    </div>
                    <div>
                      <dt>Median RTT</dt>
                      <dd>{median != null ? `${median} ms` : "—"}</dd>
                    </div>
                    <div>
                      <dt>Mode</dt>
                      <dd>{latest?.mode ?? "unreported"}</dd>
                    </div>
                    <div>
                      <dt>Revision</dt>
                      <dd>
                        {latest?.applied_revision ?? "—"} / {site.revision}{" "}
                        {synced ? "· Synced" : "· Pending"}
                      </dd>
                    </div>
                  </dl>

                  <footer className="site-card-foot">
                    <span className="mono-xs muted">
                      {reasons[0]} · {site.grants.length} granted
                    </span>
                    <button
                      type="button"
                      className="btn secondary btn-sm"
                      onClick={() => onOpenSite(site.id)}
                    >
                      Inspect
                    </button>
                  </footer>
                </article>
              );
            })}
          </div>
        )}
      </section>
    </div>
  );
}

type SiteTab = "telemetry" | "subscriptions" | "pairing";

export function SiteDetailView({
  site,
  sources,
  busy,
  onBack,
  onSaveGrants,
  onRotateToken,
  onRevokeToken,
  onDeleteSite,
  onOpenSubscriptions,
}: {
  site: Site;
  sources: Source[];
  busy: boolean;
  onBack: () => void;
  onSaveGrants: (siteId: string, grants: string[]) => Promise<boolean>;
  onRotateToken: (site: Site) => void;
  onRevokeToken: (site: Site) => void;
  onDeleteSite: (site: Site) => void;
  onOpenSubscriptions: () => void;
}) {
  const [tab, setTab] = useState<SiteTab>("telemetry");
  const [draftGrants, setDraftGrants] = useState<string[]>(site.grants);
  const tabRefs = useRef<(HTMLButtonElement | null)[]>([]);

  useEffect(() => {
    setDraftGrants(site.grants);
  }, [site.id, site.grants]);

  const { health, reasons } = classifySite(site);
  const latest = site.snapshot?.latest;
  const trend = site.snapshot?.trend ?? [];
  const synced = isRevisionSynced(site);

  const normalizedDraft = [...new Set(draftGrants)].sort();
  const normalizedSaved = [...new Set(site.grants)].sort();
  const grantsDirty = normalizedDraft.join(",") !== normalizedSaved.join(",");

  const tabs: { id: SiteTab; label: string; count?: number }[] = [
    { id: "telemetry", label: "Telemetry" },
    { id: "subscriptions", label: "Subscriptions", count: site.grants.length },
    { id: "pairing", label: "Pairing & Agent" },
  ];

  function handleTabKeyDown(event: KeyboardEvent<HTMLButtonElement>, idx: number) {
    let next = idx;
    if (event.key === "ArrowRight") next = (idx + 1) % tabs.length;
    else if (event.key === "ArrowLeft") next = (idx - 1 + tabs.length) % tabs.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = tabs.length - 1;
    else return;

    event.preventDefault();
    setTab(tabs[next].id);
    tabRefs.current[next]?.focus();
  }

  function toggleGrant(sourceId: string) {
    setDraftGrants((prev) =>
      prev.includes(sourceId)
        ? prev.filter((id) => id !== sourceId)
        : [...prev, sourceId],
    );
  }

  const configExample = JSON.stringify(
    {
      enabled: true,
      origin: window.location.origin,
      site_id: site.id,
      token: "<paste-43-char-device-token>",
      sections: Object.fromEntries(
        (site.grants.length ? site.grants : ["provider-a"]).map((id) => [
          id,
          id.replace(/-/g, "_"),
        ]),
      ),
    },
    null,
    2,
  );

  return (
    <div className="page-stack">
      <div className="page-header">
        <div className="detail-title-wrap">
          <div className="detail-title-row">
            <span className={`status-dot is-${health}`} aria-hidden="true" />
            <h1>{site.name}</h1>
            <code className="mono-pill">{site.id}</code>
            <span className={`status-pill is-${health}`}>{siteHealthLabel(health)}</span>
          </div>
          <p className="muted">
            {reasons.join(" · ")} · Token{" "}
            {site.token_active ? "provisioned" : "not provisioned"}
          </p>
        </div>
        <div className="header-actions">
          <button type="button" className="btn secondary" onClick={onBack}>
            Back to Overview
          </button>
          <button
            type="button"
            className="btn primary"
            disabled={busy}
            onClick={() => onRotateToken(site)}
          >
            <IconKey />
            <span>{site.token_active ? "Rotate Token" : "Issue Token"}</span>
          </button>
          {site.token_active && (
            <button
              type="button"
              className="btn secondary"
              disabled={busy}
              onClick={() => onRevokeToken(site)}
            >
              Revoke Token
            </button>
          )}
          <button
            type="button"
            className="btn danger-outline"
            disabled={busy}
            onClick={() => onDeleteSite(site)}
          >
            <IconTrash />
            <span>Delete</span>
          </button>
        </div>
      </div>

      <section className="kpi-strip is-compact" aria-label="Site live counters">
        <div className="kpi-cell">
          <span className="kpi-label">LAST HEARTBEAT</span>
          <strong className="kpi-value-sm tabular">
            {formatRelativeTime(site.snapshot?.last_seen_at)}
          </strong>
          <span className="kpi-sub muted mono-xs">
            Mode: {latest?.mode ?? "—"}
          </span>
        </div>
        <div className="kpi-cell">
          <span className="kpi-label">CONFIG REVISION</span>
          <strong className="kpi-value-sm tabular">
            {latest?.applied_revision ?? "—"} / {site.revision}
          </strong>
          <span className="kpi-sub muted">
            {synced ? "Applied matches desired" : "Pending next agent pull"}
          </span>
        </div>
        <div className="kpi-cell">
          <span className="kpi-label">LIVE RATE</span>
          <strong className="kpi-value-sm tabular">
            ↓ {formatBps(latest?.traffic.download_bps)}
          </strong>
          <span className="kpi-sub muted tabular">
            ↑ {formatBps(latest?.traffic.upload_bps)}
          </span>
        </div>
        <div className="kpi-cell">
          <span className="kpi-label">TOTAL VOLUME</span>
          <strong className="kpi-value-sm tabular">
            ↓ {formatBytes(latest?.traffic.download_bytes)}
          </strong>
          <span className="kpi-sub muted tabular">
            ↑ {formatBytes(latest?.traffic.upload_bytes)}
            {latest?.event ? ` · ${latest.event}` : ""}
          </span>
        </div>
      </section>

      <section className="panel">
        <div className="tabs-header" role="tablist" aria-label="Site details sections">
          {tabs.map((item, idx) => {
            const active = tab === item.id;
            return (
              <button
                key={item.id}
                ref={(el) => {
                  tabRefs.current[idx] = el;
                }}
                id={`tab-${item.id}`}
                type="button"
                role="tab"
                aria-selected={active}
                aria-controls={`panel-${item.id}`}
                tabIndex={active ? 0 : -1}
                className={active ? "tab-btn is-active" : "tab-btn"}
                onClick={() => setTab(item.id)}
                onKeyDown={(event) => handleTabKeyDown(event, idx)}
              >
                <span>{item.label}</span>
                {item.count !== undefined && (
                  <span className="count-badge tabular">{item.count}</span>
                )}
              </button>
            );
          })}
        </div>

        <div
          id="panel-telemetry"
          role="tabpanel"
          aria-labelledby="tab-telemetry"
          hidden={tab !== "telemetry"}
          className="tab-panel"
        >
          {tab === "telemetry" && (
            <div className="detail-stack">
              <div className="chart-grid">
                <div className="subpanel">
                  <div className="subpanel-head">
                    <h3>Throughput History</h3>
                    <span className="mono-xs muted">24h window</span>
                  </div>
                  <ThroughputAreaChart points={trend} />
                </div>
                <div className="subpanel">
                  <div className="subpanel-head">
                    <h3>Exit Latency &amp; Pulse</h3>
                    <span className="mono-xs muted">Measured RTT</span>
                  </div>
                  <RttBarChart points={trend} />
                  <div className="pulse-footer">
                    <span className="mono-xs muted">Window Continuity</span>
                    <PulseStrip points={trend} online={site.online} slots={40} />
                  </div>
                </div>
              </div>

              <div className="detail-split">
                <div className="subpanel">
                  <div className="subpanel-head">
                    <h3 id="exits-table-heading">Active Capabilities &amp; Exits</h3>
                    <span className="count-badge tabular">
                      {latest?.capabilities.length ?? 0}
                    </span>
                  </div>
                  {latest?.capabilities.length ? (
                    <div
                      tabIndex={0}
                      role="region"
                      aria-labelledby="exits-table-heading"
                      className="table-wrapper"
                    >
                      <table className="data-table is-compact">
                        <thead>
                          <tr>
                            <th scope="col">Capability</th>
                            <th scope="col">Provider</th>
                            <th scope="col">Region</th>
                            <th scope="col">Node Hash</th>
                            <th scope="col" className="col-right">
                              RTT
                            </th>
                          </tr>
                        </thead>
                        <tbody>
                          {latest.capabilities.map((cap) => {
                            const tier = rttTier(cap.rtt_ms);
                            return (
                              <tr key={cap.id}>
                                <th scope="row" className="sticky-col">
                                  <strong>{cap.id}</strong>
                                </th>
                                <td data-label="Provider">
                                  {cap.provider ?? <span className="muted">—</span>}
                                </td>
                                <td data-label="Region">
                                  {cap.region ?? <span className="muted">—</span>}
                                </td>
                                <td data-label="Node Hash">
                                  <code className="mono-xs">
                                    {cap.node ?? "—"}
                                  </code>
                                </td>
                                <td data-label="RTT" className="col-right">
                                  {cap.rtt_ms != null ? (
                                    <span className={`rtt-pill is-${tier} tabular`}>
                                      {cap.rtt_ms} ms
                                    </span>
                                  ) : (
                                    <span className="muted">—</span>
                                  )}
                                </td>
                              </tr>
                            );
                          })}
                        </tbody>
                      </table>
                    </div>
                  ) : (
                    <p className="muted-copy">
                      No active capability exits reported in the latest heartbeat.
                    </p>
                  )}
                </div>

                <div className="subpanel">
                  <div className="subpanel-head">
                    <h3>Provider Quotas</h3>
                    <span className="count-badge tabular">
                      {latest?.quotas?.length ?? 0}
                    </span>
                  </div>
                  {latest?.quotas?.length ? (
                    <ul className="quota-list">
                      {latest.quotas.map((quota) => (
                        <li key={quota.provider} className="quota-row">
                          <div className="quota-row-top">
                            <strong>{quota.provider}</strong>
                            <span className="mono-xs tabular">
                              {formatBytes(quota.remaining_bytes)} remaining /{" "}
                              {formatBytes(quota.total_bytes)}
                            </span>
                          </div>
                          {quota.total_bytes != null && quota.remaining_bytes != null ? (
                            <QuotaProgressSvg
                              remaining={quota.remaining_bytes}
                              total={quota.total_bytes}
                            />
                          ) : (
                            <span className="mono-xs muted">
                              Provider did not return quota ceiling
                            </span>
                          )}
                        </li>
                      ))}
                    </ul>
                  ) : (
                    <p className="muted-copy">
                      No provider quota telemetry reported by this gateway yet.
                    </p>
                  )}
                </div>
              </div>
            </div>
          )}
        </div>

        <div
          id="panel-subscriptions"
          role="tabpanel"
          aria-labelledby="tab-subscriptions"
          hidden={tab !== "subscriptions"}
          className="tab-panel"
        >
          {tab === "subscriptions" && (
            <div className="detail-stack">
              <div className="subpanel-head">
                <div>
                  <h3>Authorized Subscription Subset</h3>
                  <p className="muted">
                    Only checked sources are decrypted and returned when this site calls <code>/api/v1/agent/subscriptions</code>. Saving increments desired revision.
                  </p>
                </div>
                <div className="header-actions nowrap-actions">
                  <button
                    type="button"
                    className="btn secondary"
                    disabled={busy || !grantsDirty}
                    onClick={() => setDraftGrants(site.grants)}
                  >
                    Reset
                  </button>
                  <button
                    type="button"
                    className="btn primary"
                    disabled={busy || !grantsDirty}
                    onClick={() => void onSaveGrants(site.id, normalizedDraft)}
                  >
                    <IconCheck />
                    <span>{busy ? "Saving…" : "Save Grants"}</span>
                  </button>
                </div>
              </div>

              {sources.length ? (
                <div className="grant-grid">
                  {sources.map((source) => {
                    const checked = draftGrants.includes(source.id);
                    return (
                      <label key={source.id} className="grant-card">
                        <input
                          type="checkbox"
                          checked={checked}
                          onChange={() => toggleGrant(source.id)}
                        />
                        <div className="grant-card-body">
                          <div className="grant-card-top">
                            <strong>{source.name}</strong>
                            <code className="mono-xs muted">{source.fingerprint}</code>
                          </div>
                          <span className="mono-xs muted">{source.id}</span>
                        </div>
                      </label>
                    );
                  })}
                </div>
              ) : (
                <div className="empty-state">
                  <h3>No encrypted subscriptions in pool</h3>
                  <p className="muted">
                    Add HTTPS subscription URLs in the Subscriptions view first, then authorize individual sites here.
                  </p>
                  <button
                    type="button"
                    className="btn primary"
                    onClick={onOpenSubscriptions}
                  >
                    Go to Subscriptions Pool
                  </button>
                </div>
              )}
            </div>
          )}
        </div>

        <div
          id="panel-pairing"
          role="tabpanel"
          aria-labelledby="tab-pairing"
          hidden={tab !== "pairing"}
          className="tab-panel"
        >
          {tab === "pairing" && (
            <div className="detail-stack">
              <div className="subpanel-head">
                <div>
                  <h3>Device Authentication &amp; Agent Config</h3>
                  <p className="muted">
                    Each router uses an independent 43-character Bearer token stored as SHA-256 on the server. Rotating invalidates the previous router credential immediately.
                  </p>
                </div>
                <div className="header-actions">
                  <button
                    type="button"
                    className="btn primary"
                    disabled={busy}
                    onClick={() => onRotateToken(site)}
                  >
                    <IconKey />
                    <span>
                      {site.token_active ? "Rotate Device Token" : "Issue Device Token"}
                    </span>
                  </button>
                  {site.token_active && (
                    <button
                      type="button"
                      className="btn danger-outline"
                      disabled={busy}
                      onClick={() => onRevokeToken(site)}
                    >
                      Revoke Token
                    </button>
                  )}
                </div>
              </div>

              <div className="terminal-panel">
                <div className="terminal-bar">
                  <span className="mono-xs">
                    TARGET FILE: /etc/opl-netfleet/site-sync/config.json (0600)
                  </span>
                  <span className="mono-xs">
                    {site.token_active ? "TOKEN ACTIVE" : "NOT PROVISIONED"}
                  </span>
                </div>
                <pre className="terminal-code">
                  <code>{configExample}</code>
                </pre>
              </div>

              <div className="callout is-info">
                <span>
                  <strong>Fail-Open Safety Boundary:</strong> If Cloud Run is unreachable, returns non-200, or local compilation fails, <code>opl-netfleet-plugin-site-sync</code> preserves existing local subscriptions and active policy without disrupting LAN connectivity.
                </span>
              </div>
            </div>
          )}
        </div>
      </section>
    </div>
  );
}

export function SubscriptionsView({
  sites,
  sources,
  busy,
  onAddSubscription,
  onEditSubscription,
  onDeleteSubscription,
  onSaveSiteGrants,
  onOpenSite,
}: {
  sites: Site[];
  sources: Source[];
  busy: boolean;
  onAddSubscription: () => void;
  onEditSubscription: (source: Source) => void;
  onDeleteSubscription: (source: Source) => void;
  onSaveSiteGrants: (siteId: string, grants: string[]) => Promise<boolean>;
  onOpenSite: (siteId: string) => void;
}) {
  const [drafts, setDrafts] = useState<Record<string, string[]>>({});

  useEffect(() => {
    setDrafts((prev) => {
      const next: Record<string, string[]> = {};
      for (const site of sites) {
        next[site.id] = prev[site.id]
          ? prev[site.id].filter((id) => sources.some((src) => src.id === id))
          : [...site.grants];
      }
      return next;
    });
  }, [sites, sources]);

  const grantCounts = useMemo(() => {
    const counts = new Map<string, number>();
    for (const site of sites) {
      for (const id of site.grants) {
        counts.set(id, (counts.get(id) ?? 0) + 1);
      }
    }
    return counts;
  }, [sites]);

  function isSiteDirty(site: Site): boolean {
    const draft = [...new Set(drafts[site.id] ?? site.grants)].sort();
    const saved = [...new Set(site.grants)].sort();
    return draft.join(",") !== saved.join(",");
  }

  function toggleCell(site: Site, sourceId: string) {
    const current = drafts[site.id] ?? site.grants;
    const next = current.includes(sourceId)
      ? current.filter((id) => id !== sourceId)
      : [...current, sourceId];
    setDrafts((prev) => ({ ...prev, [site.id]: next }));
  }

  return (
    <div className="page-stack">
      <div className="page-header">
        <div>
          <h1>Subscriptions &amp; Grant Matrix</h1>
          <p className="muted">
            Upstream HTTPS URLs are encrypted with AES-256-GCM at rest. Assign exact per-site subsets to isolate semi-trusted locations.
          </p>
        </div>
        <div className="header-actions">
          <button type="button" className="btn primary" onClick={onAddSubscription}>
            <IconPlus />
            <span>Add Subscription</span>
          </button>
        </div>
      </div>

      <section className="panel" aria-labelledby="pool-heading">
        <div className="panel-toolbar">
          <div className="panel-title-group">
            <h2 id="pool-heading">Encrypted Subscription Pool</h2>
            <span className="count-badge tabular">{sources.length}</span>
          </div>
          <span className="mono-xs muted">
            AES-256-GCM · Plaintext URLs never echo back
          </span>
        </div>

        {sources.length ? (
          <div tabIndex={0} role="region" aria-labelledby="pool-heading" className="table-wrapper">
            <table className="data-table">
              <thead>
                <tr>
                  <th scope="col">Name</th>
                  <th scope="col">Identifier</th>
                  <th scope="col">URL Fingerprint</th>
                  <th scope="col">Authorized Sites</th>
                  <th scope="col" className="col-right">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody>
                {sources.map((source) => (
                  <tr key={source.id}>
                    <th scope="row" className="sticky-col">
                      <strong>{source.name}</strong>
                    </th>
                    <td data-label="Identifier">
                      <code>{source.id}</code>
                    </td>
                    <td data-label="URL Fingerprint">
                      <code className="mono-pill">{source.fingerprint}</code>
                    </td>
                    <td data-label="Authorized Sites" className="tabular">
                      {grantCounts.get(source.id) ?? 0} / {sites.length}
                    </td>
                    <td data-label="Actions" className="col-right">
                      <div className="inline-actions">
                        <button
                          type="button"
                          className="btn secondary btn-sm"
                          disabled={busy}
                          onClick={() => onEditSubscription(source)}
                        >
                          <IconEdit />
                          <span>Edit / Rotate URL</span>
                        </button>
                        <button
                          type="button"
                          className="btn danger-outline btn-sm"
                          disabled={busy}
                          onClick={() => onDeleteSubscription(source)}
                        >
                          <IconTrash />
                          <span>Delete</span>
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="empty-state">
            <h3>Subscription pool is empty</h3>
            <p className="muted">
              Add your first HTTPS subscription source to start distributing subsets across sites.
            </p>
            <button type="button" className="btn primary" onClick={onAddSubscription}>
              <IconPlus />
              <span>Add first subscription</span>
            </button>
          </div>
        )}
      </section>

      <section className="panel" aria-labelledby="matrix-heading">
        <div className="panel-toolbar">
          <div className="panel-title-group">
            <h2 id="matrix-heading">Site Authorization Matrix</h2>
            <span className="count-badge tabular">{sites.length} sites</span>
          </div>
          <span className="mono-xs muted">
            Saving bumps desired revision for the updated site
          </span>
        </div>

        {sites.length && sources.length ? (
          <div
            tabIndex={0}
            role="region"
            aria-labelledby="matrix-heading"
            className="table-wrapper"
          >
            <table className="data-table matrix-table">
              <thead>
                <tr>
                  <th scope="col">Site</th>
                  {sources.map((source) => (
                    <th key={source.id} scope="col" className="col-center">
                      <div>{source.name}</div>
                      <div className="mono-xs muted matrix-sub-id">{source.id}</div>
                    </th>
                  ))}
                  <th scope="col" className="col-right">
                    Apply Changes
                  </th>
                </tr>
              </thead>
              <tbody>
                {sites.map((site) => {
                  const dirty = isSiteDirty(site);
                  const draft = drafts[site.id] ?? site.grants;
                  return (
                    <tr key={site.id} className={dirty ? "is-dirty-row" : undefined}>
                      <th scope="row" className="sticky-col">
                        <button
                          type="button"
                          className="row-title-btn"
                          onClick={() => onOpenSite(site.id)}
                        >
                          <span className="row-title-text">{site.name}</span>
                          <span className="mono-xs muted">
                            {site.id} · rev {site.revision}
                          </span>
                        </button>
                      </th>
                      {sources.map((source) => {
                        const checked = draft.includes(source.id);
                        return (
                          <td
                            key={source.id}
                            data-label={source.name}
                            className="col-center"
                          >
                            <label className="matrix-check">
                              <input
                                type="checkbox"
                                checked={checked}
                                disabled={busy}
                                aria-label={`Authorize ${source.name} for ${site.name}`}
                                onChange={() => toggleCell(site, source.id)}
                              />
                              <span className="matrix-mobile-label">{source.name}</span>
                            </label>
                          </td>
                        );
                      })}
                      <td data-label="Apply Changes" className="col-right">
                        <div className="inline-actions">
                          {dirty ? (
                            <>
                              <button
                                type="button"
                                className="btn secondary btn-sm"
                                disabled={busy}
                                onClick={() =>
                                  setDrafts((prev) => ({
                                    ...prev,
                                    [site.id]: [...site.grants],
                                  }))
                                }
                              >
                                Reset
                              </button>
                              <button
                                type="button"
                                className="btn primary btn-sm"
                                disabled={busy}
                                onClick={() =>
                                  void onSaveSiteGrants(
                                    site.id,
                                    [...new Set(draft)].sort(),
                                  )
                                }
                              >
                                Save
                              </button>
                            </>
                          ) : (
                            <span className="mono-xs muted">Synced</span>
                          )}
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="empty-state">
            <p className="muted">
              {sites.length === 0
                ? "Create at least one managed site before configuring grant assignments."
                : "Add at least one subscription source above to map site permissions."}
            </p>
          </div>
        )}
      </section>
    </div>
  );
}
