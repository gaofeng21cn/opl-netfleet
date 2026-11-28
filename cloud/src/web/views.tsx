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
  formatEvent,
  formatMode,
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
  needsTotp,
  onLogin,
}: {
  busy: boolean;
  error: string;
  needsTotp: boolean;
  onLogin: (email: string, password: string, totpCode?: string) => Promise<void>;
}) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [totpCode, setTotpCode] = useState("");
  const [showPassword, setShowPassword] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const trimmed = email.trim();
    if (!trimmed || !password) return;
    const submittedTotp = needsTotp ? totpCode.trim() : undefined;
    if (needsTotp && !submittedTotp) return;
    if (needsTotp) setTotpCode("");
    await onLogin(trimmed, password, submittedTotp);
  }

  return (
    <main className="login-shell">
      <section className="login-card" aria-labelledby="login-title">
        <div className="login-brand">
          <BrandMark />
          <div className="login-heading">
            <h1 id="login-title">OPL NetFleet Cloud</h1>
            <p className="muted">多站点网关性能监视与加密订阅同步控制面</p>
          </div>
        </div>
        <form className="form-stack" onSubmit={submit}>
          <div className="field-group">
            <label htmlFor="gateway-email">OPL Gateway 账号（邮箱）</label>
            <input
              id="gateway-email"
              name="email"
              type="email"
              autoComplete="username"
              required
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              placeholder="name@example.com"
            />
          </div>
          <div className="field-group">
            <label htmlFor="gateway-password">密码</label>
            <div className="input-with-action">
              <input
                id="gateway-password"
                name="password"
                type={showPassword ? "text" : "password"}
                autoComplete="current-password"
                required
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                placeholder="输入 OPL Gateway 登录密码"
              />
              <button
                type="button"
                className="icon-btn"
                aria-label={showPassword ? "隐藏密码" : "显示密码"}
                onClick={() => setShowPassword((prev) => !prev)}
              >
                <IconEye open={showPassword} />
              </button>
            </div>
            <p className="field-hint">
              通过 OPL Cloud 统一验证 OPL Gateway 身份与服务开通权限；各账号站点与订阅严格隔离，登录成功后仅签发短期{" "}
              <code>HttpOnly; SameSite=Lax</code> 会话 Cookie，服务端不保留登录密码。
            </p>
          </div>
          {needsTotp && (
            <div className="field-group">
              <label htmlFor="gateway-totp">两步验证码</label>
              <input
                id="gateway-totp"
                name="totp_code"
                type="text"
                inputMode="numeric"
                autoComplete="one-time-code"
                maxLength={16}
                required
                value={totpCode}
                onChange={(event) => setTotpCode(event.target.value)}
                placeholder="输入 6 位动态验证码"
              />
            </div>
          )}
          {error && (
            <p className="inline-error" role="alert">
              {error}
            </p>
          )}
          <button type="submit" className="btn primary btn-full" disabled={busy}>
            {busy ? "正在验证身份…" : needsTotp ? "验证并登录" : "登录"}
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
  onConnectDevice,
  onOpenSubscriptions,
}: {
  sites: Site[];
  sources: Source[];
  onOpenSite: (id: string) => void;
  onConnectDevice: () => void;
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
          <h1>多站点运行总览</h1>
          <p className="muted">
            集中监视全部网关在线状态、选中出口与 RTT 延迟、实时上下行速率及订阅配置版本。
          </p>
        </div>
        <div className="header-actions">
          <button type="button" className="btn secondary" onClick={onOpenSubscriptions}>
            管理订阅池（{sources.length}）
          </button>
          <button type="button" className="btn primary" onClick={onConnectDevice}>
            <IconPlus />
            <span>接入新设备</span>
          </button>
        </div>
      </div>

      <section className="kpi-strip" aria-label="全网站点汇总指标">
        <div className="kpi-cell">
          <span className="kpi-label">在线站点</span>
          <strong className="kpi-value tabular">
            {stats.onlineCount} / {sites.length}
          </strong>
          <span className="kpi-sub muted tabular">
            {stats.syncedCount} 已同步 · {stats.offlineCount} 离线
          </span>
        </div>
        <div className="kpi-cell">
          <span className="kpi-label">实时总吞吐</span>
          <strong className="kpi-value tabular">↓ {formatBps(stats.totalDownBps)}</strong>
          <span className="kpi-sub muted tabular">↑ {formatBps(stats.totalUpBps)} 上行</span>
        </div>
        <div className="kpi-cell">
          <span className="kpi-label">出口中位延迟</span>
          <strong className="kpi-value tabular">
            {stats.medianRtt != null ? `${stats.medianRtt} ms` : "暂无 RTT"}
          </strong>
          <span className="kpi-sub muted tabular">
            {stats.activeExits} 个已上报出口能力
          </span>
        </div>
        <div className="kpi-cell">
          <span className="kpi-label">订阅池与告警</span>
          <strong className="kpi-value tabular">{sources.length} 条订阅</strong>
          <span className="kpi-sub muted tabular">
            {stats.attentionCount} 个站点需关注
          </span>
        </div>
      </section>

      {stats.attentionSites.length > 0 && (
        <section className="attention-panel" aria-labelledby="attention-heading">
          <div className="attention-head">
            <div className="attention-title">
              <IconAlert />
              <h2 id="attention-heading">需要关注</h2>
            </div>
            <span className="mono-xs muted tabular">
              共 {stats.attentionSites.length} 个站点
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
                  查看详情
                </button>
              </li>
            ))}
          </ul>
        </section>
      )}

      <section className="panel" aria-labelledby="sites-directory-heading">
        <div className="panel-toolbar">
          <div className="panel-title-group">
            <h2 id="sites-directory-heading">站点列表</h2>
            <span className="count-badge tabular">{filteredSites.length}</span>
          </div>
          <div className="toolbar-controls">
            <div className="filter-pills" role="group" aria-label="按站点状态筛选">
              {(["all", "online", "attention", "offline"] as SiteFilter[]).map((key) => (
                <button
                  key={key}
                  type="button"
                  className={filter === key ? "pill-btn is-active" : "pill-btn"}
                  aria-pressed={filter === key}
                  onClick={() => setFilter(key)}
                >
                  {key === "all" ? "全部" : siteHealthLabel(key)}
                </button>
              ))}
            </div>
            <div className="search-input-wrap">
              <IconSearch />
              <label htmlFor="site-filter-search" className="sr-only">
                筛选站点
              </label>
              <input
                id="site-filter-search"
                type="search"
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="筛选站点、地区或出口能力…"
              />
            </div>
            <div className="view-switch" role="group" aria-label="视图切换">
              <button
                type="button"
                className={viewMode === "table" ? "switch-btn is-active" : "switch-btn"}
                aria-pressed={viewMode === "table"}
                onClick={() => setViewMode("table")}
                title="表格视图"
              >
                <IconTable />
                <span>表格</span>
              </button>
              <button
                type="button"
                className={viewMode === "cards" ? "switch-btn is-active" : "switch-btn"}
                aria-pressed={viewMode === "cards"}
                onClick={() => setViewMode("cards")}
                title="卡片视图"
              >
                <IconGrid />
                <span>卡片</span>
              </button>
            </div>
          </div>
        </div>

        {sites.length === 0 ? (
          <div className="empty-state">
            <h3>暂无已配对站点</h3>
            <p className="muted">
              在 OpenWrt 路由器 LuCI「云端站点同步」页或终端中使用 OPL Gateway 账号密码登录后，设备将自动完成注册配对并开始上报出口延迟、吞吐曲线与配置状态。
            </p>
            <button type="button" className="btn primary" onClick={onConnectDevice}>
              <IconPlus />
              <span>接入第一台设备</span>
            </button>
          </div>
        ) : filteredSites.length === 0 ? (
          <div className="empty-state">
            <h3>没有符合条件的站点</h3>
            <p className="muted">请清空筛选关键词或切换状态过滤标签以查看全部站点。</p>
            <button
              type="button"
              className="btn secondary"
              onClick={() => {
                setFilter("all");
                setSearch("");
              }}
            >
              重置筛选
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
                  <th scope="col">站点</th>
                  <th scope="col">状态</th>
                  <th scope="col">当前出口</th>
                  <th scope="col">延迟</th>
                  <th scope="col">速率与趋势</th>
                  <th scope="col">配置版本</th>
                  <th scope="col">授权订阅</th>
                  <th scope="col" className="col-right">
                    操作
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
                      <td data-label="状态">
                        <span className={`status-pill is-${health}`}>
                          <span className={`status-dot is-${health}`} aria-hidden="true" />
                          <span>{siteHealthLabel(health)}</span>
                        </span>
                        <div className="cell-sub muted mono-xs">
                          {site.snapshot
                            ? `${formatMode(latest?.mode)} · ${formatRelativeTime(site.snapshot.last_seen_at)}`
                            : "尚未上报"}
                        </div>
                      </td>
                      <td data-label="当前出口">
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
                      <td data-label="延迟">
                        {median != null ? (
                          <span className={`rtt-pill is-${tier} tabular`}>{median} ms</span>
                        ) : (
                          <span className="muted tabular">—</span>
                        )}
                      </td>
                      <td data-label="速率与趋势">
                        <div className="rate-spark-cell">
                          <div className="tabular mono-xs rate-lines">
                            <div>↓ {formatBps(latest?.traffic.download_bps)}</div>
                            <div className="muted">↑ {formatBps(latest?.traffic.upload_bps)}</div>
                          </div>
                          <ThroughputSparkline
                            points={site.snapshot?.trend ?? []}
                            label={`${site.name} 吞吐趋势图`}
                          />
                        </div>
                      </td>
                      <td data-label="配置版本">
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
                      <td data-label="授权订阅">
                        <span className="tabular">{site.grants.length} 条订阅</span>
                        <div className="cell-sub muted mono-xs">
                          {site.token_active ? "已配对 Token" : "未签发 Token"}
                        </div>
                      </td>
                      <td data-label="操作" className="col-right">
                        <button
                          type="button"
                          className="btn secondary btn-sm"
                          onClick={() => onOpenSite(site.id)}
                        >
                          详情
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
                      <dt>实时速率</dt>
                      <dd>
                        ↓ {formatBps(latest?.traffic.download_bps)} · ↑{" "}
                        {formatBps(latest?.traffic.upload_bps)}
                      </dd>
                    </div>
                    <div>
                      <dt>出口中位延迟</dt>
                      <dd>{median != null ? `${median} ms` : "—"}</dd>
                    </div>
                    <div>
                      <dt>运行模式</dt>
                      <dd>{formatMode(latest?.mode)}</dd>
                    </div>
                    <div>
                      <dt>配置版本</dt>
                      <dd>
                        {latest?.applied_revision ?? "—"} / {site.revision}{" "}
                        {synced ? "· 已同步" : "· 待同步"}
                      </dd>
                    </div>
                  </dl>

                  <footer className="site-card-foot">
                    <span className="mono-xs muted">
                      {reasons[0]} · 已授权 {site.grants.length} 条
                    </span>
                    <button
                      type="button"
                      className="btn secondary btn-sm"
                      onClick={() => onOpenSite(site.id)}
                    >
                      查看详情
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
  onRenameSite,
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
  onRenameSite: (site: Site) => void;
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
    { id: "telemetry", label: "运行遥测" },
    { id: "subscriptions", label: "订阅授权", count: site.grants.length },
    { id: "pairing", label: "设备配对" },
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
      token: "<请填入 43 位一次性设备 Token>",
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
            {reasons.join(" · ")} · 设备凭据：{site.token_active ? "已配置" : "未签发"}
          </p>
        </div>
        <div className="header-actions">
          <button type="button" className="btn secondary" onClick={onBack}>
            返回总览
          </button>
          <button
            type="button"
            className="btn secondary"
            disabled={busy}
            onClick={() => onRenameSite(site)}
          >
            <IconEdit />
            <span>重命名</span>
          </button>
          <button
            type="button"
            className="btn primary"
            disabled={busy}
            onClick={() => onRotateToken(site)}
          >
            <IconKey />
            <span>{site.token_active ? "轮转 Token" : "签发 Token"}</span>
          </button>
          {site.token_active && (
            <button
              type="button"
              className="btn secondary"
              disabled={busy}
              onClick={() => onRevokeToken(site)}
            >
              吊销 Token
            </button>
          )}
          <button
            type="button"
            className="btn danger-outline"
            disabled={busy}
            onClick={() => onDeleteSite(site)}
          >
            <IconTrash />
            <span>删除站点</span>
          </button>
        </div>
      </div>

      <section className="kpi-strip is-compact" aria-label="站点实时运行指标">
        <div className="kpi-cell">
          <span className="kpi-label">最后心跳</span>
          <strong className="kpi-value-sm tabular">
            {formatRelativeTime(site.snapshot?.last_seen_at)}
          </strong>
          <span className="kpi-sub muted mono-xs">
            模式：{formatMode(latest?.mode)}
          </span>
        </div>
        <div className="kpi-cell">
          <span className="kpi-label">配置版本</span>
          <strong className="kpi-value-sm tabular">
            {latest?.applied_revision ?? "—"} / {site.revision}
          </strong>
          <span className="kpi-sub muted">
            {synced ? "设备版本与云端一致" : "等待设备下个心跳拉取"}
          </span>
        </div>
        <div className="kpi-cell">
          <span className="kpi-label">实时速率</span>
          <strong className="kpi-value-sm tabular">
            ↓ {formatBps(latest?.traffic.download_bps)}
          </strong>
          <span className="kpi-sub muted tabular">
            ↑ {formatBps(latest?.traffic.upload_bps)} 上行
          </span>
        </div>
        <div className="kpi-cell">
          <span className="kpi-label">累计流量</span>
          <strong className="kpi-value-sm tabular">
            ↓ {formatBytes(latest?.traffic.download_bytes)}
          </strong>
          <span className="kpi-sub muted tabular">
            ↑ {formatBytes(latest?.traffic.upload_bytes)}
            {latest?.event ? ` · ${formatEvent(latest.event)}` : ""}
          </span>
        </div>
      </section>

      <section className="panel">
        <div className="tabs-header" role="tablist" aria-label="站点详情分类">
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
                    <h3>吞吐速率趋势</h3>
                    <span className="mono-xs muted">近 24 小时</span>
                  </div>
                  <ThroughputAreaChart points={trend} />
                </div>
                <div className="subpanel">
                  <div className="subpanel-head">
                    <h3>出口延迟与心跳连续性</h3>
                    <span className="mono-xs muted">实测 RTT</span>
                  </div>
                  <RttBarChart points={trend} />
                  <div className="pulse-footer">
                    <span className="mono-xs muted">心跳时间窗</span>
                    <PulseStrip points={trend} online={site.online} slots={40} />
                  </div>
                </div>
              </div>

              <div className="detail-split">
                <div className="subpanel">
                  <div className="subpanel-head">
                    <h3 id="exits-table-heading">活跃出口与策略能力</h3>
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
                            <th scope="col">能力标识</th>
                            <th scope="col">机场来源</th>
                            <th scope="col">地区</th>
                            <th scope="col">节点脱敏指纹</th>
                            <th scope="col" className="col-right">
                              实测延迟
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
                                <td data-label="机场来源">
                                  {cap.provider ?? <span className="muted">—</span>}
                                </td>
                                <td data-label="地区">
                                  {cap.region ?? <span className="muted">—</span>}
                                </td>
                                <td data-label="节点脱敏指纹">
                                  <code className="mono-xs">
                                    {cap.node ?? "—"}
                                  </code>
                                </td>
                                <td data-label="实测延迟" className="col-right">
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
                    <p className="muted-copy">最近一次心跳暂未上报启用的出口能力。</p>
                  )}
                </div>

                <div className="subpanel">
                  <div className="subpanel-head">
                    <h3>机场订阅剩余流量</h3>
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
                              剩余 {formatBytes(quota.remaining_bytes)} /{" "}
                              {formatBytes(quota.total_bytes)}
                            </span>
                          </div>
                          {quota.total_bytes != null && quota.remaining_bytes != null ? (
                            <QuotaProgressSvg
                              remaining={quota.remaining_bytes}
                              total={quota.total_bytes}
                            />
                          ) : (
                            <span className="mono-xs muted">该订阅未返回总量配额</span>
                          )}
                        </li>
                      ))}
                    </ul>
                  ) : (
                    <p className="muted-copy">该网关暂未上报机场剩余流量数据。</p>
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
                  <h3>获准下发订阅子集</h3>
                  <p className="muted">
                    仅勾选的订阅源会在该站点请求 <code>/api/v1/agent/subscriptions</code> 时解密返回；保存后自动递增期望版本号。
                  </p>
                </div>
                <div className="header-actions nowrap-actions">
                  <button
                    type="button"
                    className="btn secondary"
                    disabled={busy || !grantsDirty}
                    onClick={() => setDraftGrants(site.grants)}
                  >
                    重置
                  </button>
                  <button
                    type="button"
                    className="btn primary"
                    disabled={busy || !grantsDirty}
                    onClick={() => void onSaveGrants(site.id, normalizedDraft)}
                  >
                    <IconCheck />
                    <span>{busy ? "保存中…" : "保存授权"}</span>
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
                  <h3>订阅池暂无订阅源</h3>
                  <p className="muted">
                    请先前往「订阅与授权」页面添加 HTTPS 加密订阅源，再在此为站点勾选分配子集。
                  </p>
                  <button
                    type="button"
                    className="btn primary"
                    onClick={onOpenSubscriptions}
                  >
                    前往订阅池
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
                  <h3>设备认证与自动配对状态</h3>
                  <p className="muted">
                    推荐在 OpenWrt 端「云端站点同步」插件或 SSH 终端用 OPL Gateway 账号密码自动配对及续期；服务端仅保存 43 位 Bearer Token 的单向 SHA-256 哈希，轮转后旧凭据立即失效。
                  </p>
                  {site.device_id && (
                    <p className="muted mono-xs">
                      已绑定设备标识：<code>{site.device_id}</code>（重装或二次登录将自动识别并更新当前站点）
                    </p>
                  )}
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
                      {site.token_active ? "轮转设备 Token" : "签发设备 Token"}
                    </span>
                  </button>
                  {site.token_active && (
                    <button
                      type="button"
                      className="btn danger-outline"
                      disabled={busy}
                      onClick={() => onRevokeToken(site)}
                    >
                      吊销 Token
                    </button>
                  )}
                </div>
              </div>

              <details className="advanced-box">
                <summary>
                  高级选项：手动写入 /etc/opl-netfleet/site-sync/config.json 示例
                </summary>
                <div className="advanced-body">
                  <div className="terminal-panel">
                    <div className="terminal-bar">
                      <span className="mono-xs">
                        目标设备配置文件：/etc/opl-netfleet/site-sync/config.json（权限 0600）
                      </span>
                      <span className="mono-xs">
                        {site.token_active ? "Token 已生效" : "尚未签发"}
                      </span>
                    </div>
                    <pre className="terminal-code">
                      <code>{configExample}</code>
                    </pre>
                  </div>
                </div>
              </details>

              <div className="callout is-info">
                <span>
                  <strong>Fail-Open 安全边界：</strong> 当云端不可达、返回非 200 或本地订阅编译校验失败时，
                  <code>opl-netfleet-plugin-site-sync</code> 会严格保留设备既有本地订阅与运行配置，绝不中断局域网网络。
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
          <h1>订阅池与站点授权</h1>
          <p className="muted">
            上游 HTTPS 订阅链接静态经 AES-256-GCM 加密保管；通过授权矩阵按站点最小权限精准下发子集。
          </p>
        </div>
        <div className="header-actions">
          <button type="button" className="btn primary" onClick={onAddSubscription}>
            <IconPlus />
            <span>添加订阅</span>
          </button>
        </div>
      </div>

      <section className="panel" aria-labelledby="pool-heading">
        <div className="panel-toolbar">
          <div className="panel-title-group">
            <h2 id="pool-heading">加密订阅池</h2>
            <span className="count-badge tabular">{sources.length}</span>
          </div>
          <span className="mono-xs muted">
            AES-256-GCM · 明文地址绝不回传浏览器
          </span>
        </div>

        {sources.length ? (
          <div tabIndex={0} role="region" aria-labelledby="pool-heading" className="table-wrapper">
            <table className="data-table">
              <thead>
                <tr>
                  <th scope="col">名称</th>
                  <th scope="col">订阅 ID</th>
                  <th scope="col">链接 SHA-256 指纹</th>
                  <th scope="col">已授权站点数</th>
                  <th scope="col" className="col-right">
                    操作
                  </th>
                </tr>
              </thead>
              <tbody>
                {sources.map((source) => (
                  <tr key={source.id}>
                    <th scope="row" className="sticky-col">
                      <strong>{source.name}</strong>
                    </th>
                    <td data-label="订阅 ID">
                      <code>{source.id}</code>
                    </td>
                    <td data-label="链接指纹">
                      <code className="mono-pill">{source.fingerprint}</code>
                    </td>
                    <td data-label="已授权站点数" className="tabular">
                      {grantCounts.get(source.id) ?? 0} / {sites.length}
                    </td>
                    <td data-label="操作" className="col-right">
                      <div className="inline-actions">
                        <button
                          type="button"
                          className="btn secondary btn-sm"
                          disabled={busy}
                          onClick={() => onEditSubscription(source)}
                        >
                          <IconEdit />
                          <span>编辑 / 更换链接</span>
                        </button>
                        <button
                          type="button"
                          className="btn danger-outline btn-sm"
                          disabled={busy}
                          onClick={() => onDeleteSubscription(source)}
                        >
                          <IconTrash />
                          <span>删除</span>
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
            <h3>加密订阅池为空</h3>
            <p className="muted">
              添加第一条 HTTPS 机场订阅源后，即可在下方矩阵为不同站点勾选分发的订阅子集。
            </p>
            <button type="button" className="btn primary" onClick={onAddSubscription}>
              <IconPlus />
              <span>添加第一条订阅</span>
            </button>
          </div>
        )}
      </section>

      <section className="panel" aria-labelledby="matrix-heading">
        <div className="panel-toolbar">
          <div className="panel-title-group">
            <h2 id="matrix-heading">站点授权矩阵</h2>
            <span className="count-badge tabular">{sites.length} 个站点</span>
          </div>
          <span className="mono-xs muted">
            保存修改后将自动递增对应站点的期望配置版本号
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
                  <th scope="col">站点</th>
                  {sources.map((source) => (
                    <th key={source.id} scope="col" className="col-center">
                      <div>{source.name}</div>
                      <div className="mono-xs muted matrix-sub-id">{source.id}</div>
                    </th>
                  ))}
                  <th scope="col" className="col-right">
                    保存变更
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
                            {site.id} · 版本 {site.revision}
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
                                aria-label={`允许站点 ${site.name} 拉取 ${source.name}`}
                                onChange={() => toggleCell(site, source.id)}
                              />
                              <span className="matrix-mobile-label">{source.name}</span>
                            </label>
                          </td>
                        );
                      })}
                      <td data-label="保存变更" className="col-right">
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
                                重置
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
                                保存
                              </button>
                            </>
                          ) : (
                            <span className="mono-xs muted">已同步</span>
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
                ? "请先创建至少一个纳管站点后再分配订阅权限。"
                : "请先在上方添加至少一条订阅源后再配置站点授权矩阵。"}
            </p>
          </div>
        )}
      </section>
    </div>
  );
}
