import { useCallback, useEffect, useMemo, useState } from "react";
import {
  api,
  ApiError,
  classifySite,
  isRevisionSynced,
  type AuthUser,
  type Site,
  type Source,
  type ThemeMode,
} from "./api.js";
import {
  BrandMark,
  IconChevronRight,
  IconMenu,
  IconMonitor,
  IconMoon,
  IconOverview,
  IconRefresh,
  IconSearch,
  IconSignOut,
  IconSites,
  IconSubscriptions,
  IconSun,
} from "./charts.js";
import {
  CommandPaletteDialog,
  ConfirmDialog,
  ConnectDeviceDialog,
  RenameSiteDialog,
  SubscriptionDialog,
  TokenRevealDialog,
} from "./dialogs.js";
import { LoginView, OverviewView, SiteDetailView, SubscriptionsView } from "./views.js";

type Route =
  | { page: "overview" }
  | { page: "subscriptions" }
  | { page: "site"; siteId: string };

const THEME_STORAGE_KEY = "opl-netfleet-cloud-theme";

const THEME_LABELS: Record<ThemeMode, string> = {
  system: "跟随系统",
  light: "浅色",
  dark: "深色",
};

function parseHashRoute(): Route {
  const hash = window.location.hash.replace(/^#\/?/, "");
  if (hash === "subscriptions") return { page: "subscriptions" };
  if (hash.startsWith("sites/")) {
    const id = decodeURIComponent(hash.slice("sites/".length));
    if (/^[a-z][a-z0-9-]{1,47}$/.test(id)) return { page: "site", siteId: id };
  }
  return { page: "overview" };
}

function hashForRoute(route: Route): string {
  switch (route.page) {
    case "overview":
      return "#/overview";
    case "subscriptions":
      return "#/subscriptions";
    case "site":
      return `#/sites/${encodeURIComponent(route.siteId)}`;
  }
}

export function App() {
  const [auth, setAuth] = useState<"loading" | "signed-out" | "signed-in">("loading");
  const [user, setUser] = useState<AuthUser | null>(null);
  const [sites, setSites] = useState<Site[]>([]);
  const [sources, setSources] = useState<Source[]>([]);
  const [route, setRoute] = useState<Route>(() => parseHashRoute());
  const [error, setError] = useState("");
  const [toast, setToast] = useState("");
  const [busy, setBusy] = useState(false);
  const [lastUpdated, setLastUpdated] = useState<string>("");
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  const [theme, setTheme] = useState<ThemeMode>(() => {
    const saved = window.localStorage.getItem(THEME_STORAGE_KEY);
    return saved === "light" || saved === "dark" || saved === "system" ? saved : "system";
  });

  const [connectOpen, setConnectOpen] = useState(false);
  const [renameSiteTarget, setRenameSiteTarget] = useState<Site | null>(null);
  const [subDialog, setSubDialog] = useState<{ open: boolean; source: Source | null }>({
    open: false,
    source: null,
  });
  const [issuedToken, setIssuedToken] = useState<{ id: string; device_token: string } | null>(null);
  const [needsTotp, setNeedsTotp] = useState(false);
  const [confirmState, setConfirmState] = useState<{
    title: string;
    message: string;
    confirmLabel: string;
    danger?: boolean;
    action: () => Promise<void>;
  } | null>(null);
  const [paletteOpen, setPaletteOpen] = useState(false);

  const modalOpen =
    connectOpen ||
    !!renameSiteTarget ||
    subDialog.open ||
    !!issuedToken ||
    !!confirmState ||
    paletteOpen;

  useEffect(() => {
    window.localStorage.setItem(THEME_STORAGE_KEY, theme);
    if (theme === "system") {
      document.documentElement.removeAttribute("data-theme");
    } else {
      document.documentElement.setAttribute("data-theme", theme);
    }
  }, [theme]);

  useEffect(() => {
    const onHash = () => setRoute(parseHashRoute());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  const navigate = useCallback((next: Route) => {
    const targetHash = hashForRoute(next);
    if (window.location.hash !== targetHash) {
      window.location.hash = targetHash;
    }
    setRoute(next);
    setMobileNavOpen(false);
  }, []);

  useEffect(() => {
    if (!toast) return;
    const timer = window.setTimeout(() => setToast(""), 4000);
    return () => window.clearTimeout(timer);
  }, [toast]);

  const showToast = useCallback((message: string) => {
    setToast(message);
  }, []);

  const signedOut = useCallback(() => {
    setAuth("signed-out");
    setUser(null);
    setSites([]);
    setSources([]);
    setIssuedToken(null);
    setConfirmState(null);
    setConnectOpen(false);
    setRenameSiteTarget(null);
    setNeedsTotp(false);
  }, []);

  const report = useCallback(
    (cause: unknown) => {
      if (cause instanceof ApiError && cause.status === 401) {
        signedOut();
        setError(cause.message);
      } else {
        setError(cause instanceof Error ? cause.message : "请求失败。");
        setAuth((prev) => (prev === "loading" ? "signed-out" : prev));
      }
    },
    [signedOut],
  );

  const load = useCallback(async () => {
    const [meRes, siteRes, subRes] = await Promise.all([
      api<AuthUser>("/auth/me"),
      api<{ sites: Site[] }>("/sites"),
      api<{ subscriptions: Source[] }>("/subscriptions"),
    ]);
    setUser(meRes);
    setSites(siteRes.sites);
    setSources(subRes.subscriptions);
    setAuth("signed-in");
    setLastUpdated(
      new Date().toLocaleTimeString(undefined, {
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hour12: false,
      }),
    );
  }, []);

  useEffect(() => {
    void load().catch((cause) => {
      if (cause instanceof ApiError && cause.status === 401) {
        signedOut();
      } else {
        report(cause);
      }
    });
  }, [load, report, signedOut]);

  useEffect(() => {
    if (auth !== "signed-in" || busy || modalOpen) return;
    const timer = window.setInterval(() => {
      if (!document.hidden) void load().catch(report);
    }, 30000);
    return () => window.clearInterval(timer);
  }, [auth, busy, modalOpen, load, report]);

  useEffect(() => {
    if (auth !== "signed-in") return;
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setPaletteOpen((prev) => !prev);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [auth]);

  async function mutate<T>(
    path: string,
    method: "POST" | "PUT" | "DELETE",
    body?: unknown,
    successToast?: string,
  ): Promise<T | null> {
    setBusy(true);
    setError("");
    try {
      const result = await api<T>(path, method, body);
      await load();
      if (successToast) showToast(successToast);
      return result;
    } catch (cause) {
      report(cause);
      return null;
    } finally {
      setBusy(false);
    }
  }

  async function handleLogin(
    email: string,
    password: string,
    totpCode?: string,
  ) {
    setBusy(true);
    setError("");
    try {
      const result = await api<{ ok?: boolean; requires_2fa?: boolean }>(
        "/auth/login",
        "POST",
        {
          email,
          password,
          ...(totpCode ? { totp_code: totpCode } : {}),
        },
      );
      if (result?.requires_2fa) {
        setNeedsTotp(true);
        setError("该账号已开启两步验证，请输入 6 位动态验证码后继续登录。");
        return;
      }
      setNeedsTotp(false);
      await load();
    } catch (cause) {
      report(cause);
    } finally {
      setBusy(false);
    }
  }

  async function handleLogout() {
    setBusy(true);
    setError("");
    try {
      await api("/auth/logout", "POST");
      signedOut();
    } catch (cause) {
      report(cause);
    } finally {
      setBusy(false);
    }
  }

  function cycleTheme() {
    setTheme((prev) =>
      prev === "system" ? "light" : prev === "light" ? "dark" : "system",
    );
  }

  const activeSite = useMemo(
    () => (route.page === "site" ? sites.find((s) => s.id === route.siteId) ?? null : null),
    [route, sites],
  );

  useEffect(() => {
    if (auth === "signed-in" && route.page === "site" && !activeSite) {
      navigate({ page: "overview" });
    }
  }, [auth, route, activeSite, navigate]);

  async function handleCreateSite(payload: {
    id: string;
    name: string;
    issueToken: boolean;
  }): Promise<boolean> {
    const created = await mutate<{ id: string }>(
      "/sites",
      "POST",
      { id: payload.id, name: payload.name },
      `站点「${payload.id}」已创建。`,
    );
    if (!created) return false;
    if (payload.issueToken) {
      const issued = await mutate<{ id: string; device_token: string }>(
        `/sites/${payload.id}/token`,
        "POST",
      );
      if (issued) setIssuedToken(issued);
    }
    navigate({ page: "site", siteId: payload.id });
    return true;
  }

  async function handleRenameSite(id: string, name: string): Promise<boolean> {
    const updated = await mutate<{ ok: true; id: string; name: string }>(
      `/sites/${id}`,
      "PUT",
      { name },
      `站点名称已更新为「${name}」。`,
    );
    return !!updated;
  }

  async function handleSaveSubscription(payload: {
    id?: string;
    name: string;
    url: string;
  }): Promise<boolean> {
    if (subDialog.source) {
      const body: { name: string; url?: string } = { name: payload.name };
      if (payload.url) body.url = payload.url;
      const updated = await mutate(
        `/subscriptions/${subDialog.source.id}`,
        "PUT",
        body,
        `已更新订阅「${subDialog.source.id}」。`,
      );
      return !!updated;
    }
    const created = await mutate(
      "/subscriptions",
      "POST",
      payload,
      `已加密添加订阅「${payload.id}」。`,
    );
    return !!created;
  }

  function requestRotateToken(site: Site) {
    if (!site.token_active) {
      void mutate<{ id: string; device_token: string }>(
        `/sites/${site.id}/token`,
        "POST",
      ).then((issued) => {
        if (issued) setIssuedToken(issued);
      });
      return;
    }
    setConfirmState({
      title: `轮转设备 Token · ${site.id}`,
      message:
        "轮转后将生成新的一次性设备凭据，路由器当前使用的旧 Token 会立即失效。确定继续？",
      confirmLabel: "确认轮转",
      danger: true,
      action: async () => {
        const issued = await mutate<{ id: string; device_token: string }>(
          `/sites/${site.id}/token`,
          "POST",
        );
        setConfirmState(null);
        if (issued) setIssuedToken(issued);
      },
    });
  }

  function requestRevokeToken(site: Site) {
    setConfirmState({
      title: `吊销设备 Token · ${site.id}`,
      message:
        "吊销后该路由器将立即无法上报心跳或拉取订阅更新，直到重新签发并写入新 Token。",
      confirmLabel: "确认吊销",
      danger: true,
      action: async () => {
        await mutate(
          `/sites/${site.id}/token`,
          "DELETE",
          undefined,
          `已吊销站点 ${site.id} 的设备 Token。`,
        );
        setConfirmState(null);
      },
    });
  }

  function requestDeleteSite(site: Site) {
    setConfirmState({
      title: `删除站点 · ${site.name}`,
      message: `删除「${site.id}」将永久清除其设备凭据、订阅授权与历史遥测快照，确定继续？`,
      confirmLabel: "删除站点",
      danger: true,
      action: async () => {
        const ok = await mutate(
          `/sites/${site.id}`,
          "DELETE",
          undefined,
          `已删除站点 ${site.id}。`,
        );
        setConfirmState(null);
        if (ok && route.page === "site" && route.siteId === site.id) {
          navigate({ page: "overview" });
        }
      },
    });
  }

  function requestDeleteSubscription(source: Source) {
    setConfirmState({
      title: `删除订阅 · ${source.name}`,
      message: `删除「${source.id}」会从所有已授权站点移除该订阅，并递增对应站点的期望配置版本号。`,
      confirmLabel: "确认删除",
      danger: true,
      action: async () => {
        await mutate(
          `/subscriptions/${source.id}`,
          "DELETE",
          undefined,
          `已移除订阅 ${source.id}。`,
        );
        setConfirmState(null);
      },
    });
  }

  if (auth === "loading") {
    return (
      <main className="login-shell">
        <div className="loading-state" role="status">
          <IconRefresh spinning />
          <span>正在检查登录会话…</span>
        </div>
      </main>
    );
  }

  if (auth === "signed-out") {
    return (
      <LoginView
        busy={busy}
        error={error}
        needsTotp={needsTotp}
        onLogin={handleLogin}
      />
    );
  }

  const onlineSites = sites.filter((s) => s.online).length;
  const syncedSites = sites.filter(isRevisionSynced).length;

  return (
    <div
      className={
        sidebarCollapsed ? "app-shell is-sidebar-collapsed" : "app-shell"
      }
    >
      {mobileNavOpen && (
        <button
          type="button"
          className="drawer-backdrop"
          aria-label="关闭导航菜单"
          onClick={() => setMobileNavOpen(false)}
        />
      )}

      <aside className={mobileNavOpen ? "sidebar is-open" : "sidebar"}>
        <div className="sidebar-head">
          <button
            type="button"
            className="sidebar-brand"
            onClick={() => navigate({ page: "overview" })}
          >
            <BrandMark />
            <span className="brand-text">NetFleet Cloud</span>
          </button>
        </div>

        <nav className="sidebar-nav" aria-label="主导航">
          <button
            type="button"
            className={route.page === "overview" ? "nav-item is-active" : "nav-item"}
            aria-current={route.page === "overview" ? "page" : undefined}
            onClick={() => navigate({ page: "overview" })}
          >
            <IconOverview />
            <span className="nav-label">站点总览</span>
          </button>
          <button
            type="button"
            className={
              route.page === "subscriptions" ? "nav-item is-active" : "nav-item"
            }
            aria-current={route.page === "subscriptions" ? "page" : undefined}
            onClick={() => navigate({ page: "subscriptions" })}
          >
            <IconSubscriptions />
            <span className="nav-label">订阅与授权</span>
            <span className="count-badge tabular">{sources.length}</span>
          </button>

          <div className="nav-section">
            <div className="nav-section-head">
              <IconSites />
              <span>纳管站点</span>
              <span className="count-badge tabular">{sites.length}</span>
            </div>
            <div className="nav-site-list">
              {sites.map((site) => {
                const { health } = classifySite(site);
                const selected =
                  route.page === "site" && route.siteId === site.id;
                return (
                  <button
                    key={site.id}
                    type="button"
                    className={
                      selected ? "nav-sub-item is-active" : "nav-sub-item"
                    }
                    aria-current={selected ? "page" : undefined}
                    onClick={() => navigate({ page: "site", siteId: site.id })}
                  >
                    <span
                      className={`status-dot is-${health}`}
                      aria-hidden="true"
                    />
                    <span className="nav-site-name">{site.name}</span>
                  </button>
                );
              })}
              {sites.length === 0 && (
                <span className="nav-empty muted">暂无站点</span>
              )}
            </div>
          </div>
        </nav>

        <div className="sidebar-foot">
          <button
            type="button"
            className="nav-item collapse-toggle"
            onClick={() => setSidebarCollapsed((prev) => !prev)}
          >
            <IconChevronRight />
            <span className="nav-label">
              {sidebarCollapsed ? "展开侧栏" : "收起侧栏"}
            </span>
          </button>
        </div>
      </aside>

      <div className="workspace">
        <header className="topbar">
          <div className="topbar-left">
            <button
              type="button"
              className="icon-btn mobile-menu-btn"
              aria-label="打开导航菜单"
              onClick={() => setMobileNavOpen(true)}
            >
              <IconMenu />
            </button>
            <nav className="breadcrumbs" aria-label="页面路径">
              <button
                type="button"
                className="crumb-btn"
                onClick={() => navigate({ page: "overview" })}
              >
                多站点
              </button>
              <IconChevronRight />
              <span className="crumb-current">
                {route.page === "overview"
                  ? "总览"
                  : route.page === "subscriptions"
                    ? "订阅与授权"
                    : activeSite?.name ?? route.siteId}
              </span>
            </nav>
          </div>

          <div className="topbar-right">
            <button
              type="button"
              className="search-trigger"
              onClick={() => setPaletteOpen(true)}
            >
              <IconSearch />
              <span className="search-trigger-label">快速搜索…</span>
              <kbd className="kbd-pill">⌘K</kbd>
            </button>
            <button
              type="button"
              className="icon-btn"
              aria-label="刷新全网遥测"
              title={lastUpdated ? `最近更新：${lastUpdated}` : "刷新数据"}
              disabled={busy}
              onClick={() => void load().catch(report)}
            >
              <IconRefresh spinning={busy} />
            </button>
            <button
              type="button"
              className="theme-btn"
              onClick={cycleTheme}
              aria-label={`切换主题（当前：${THEME_LABELS[theme]}）`}
              title={`外观主题：${THEME_LABELS[theme]}`}
            >
              {theme === "light" ? (
                <IconSun />
              ) : theme === "dark" ? (
                <IconMoon />
              ) : (
                <IconMonitor />
              )}
              <span className="theme-label">{THEME_LABELS[theme]}</span>
            </button>
            {user?.email && (
              <span className="user-badge hide-xs mono-xs" title={user.email}>
                {user.email}
              </span>
            )}
            <button
              type="button"
              className="btn secondary btn-sm"
              disabled={busy}
              aria-label="退出登录"
              onClick={() => void handleLogout()}
            >
              <IconSignOut />
              <span className="hide-xs">退出登录</span>
            </button>
          </div>
        </header>

        <main className="main-content">
          {error && (
            <div className="callout is-danger" role="alert">
              <span>{error}</span>
              <button
                type="button"
                className="btn-inline-link"
                onClick={() => setError("")}
              >
                关闭
              </button>
            </div>
          )}

          {route.page === "overview" && (
            <OverviewView
              sites={sites}
              sources={sources}
              onOpenSite={(siteId) => navigate({ page: "site", siteId })}
              onConnectDevice={() => setConnectOpen(true)}
              onOpenSubscriptions={() => navigate({ page: "subscriptions" })}
            />
          )}

          {route.page === "site" && activeSite && (
            <SiteDetailView
              site={activeSite}
              sources={sources}
              busy={busy}
              onBack={() => navigate({ page: "overview" })}
              onRenameSite={(target) => setRenameSiteTarget(target)}
              onSaveGrants={async (siteId, subscription_ids) =>
                !!(await mutate(
                  `/sites/${siteId}/grants`,
                  "PUT",
                  { subscription_ids },
                  `已更新站点 ${siteId} 的订阅授权子集。`,
                ))
              }
              onRotateToken={requestRotateToken}
              onRevokeToken={requestRevokeToken}
              onDeleteSite={requestDeleteSite}
              onOpenSubscriptions={() => navigate({ page: "subscriptions" })}
            />
          )}

          {route.page === "subscriptions" && (
            <SubscriptionsView
              sites={sites}
              sources={sources}
              busy={busy}
              onAddSubscription={() =>
                setSubDialog({ open: true, source: null })
              }
              onEditSubscription={(source) =>
                setSubDialog({ open: true, source })
              }
              onDeleteSubscription={requestDeleteSubscription}
              onSaveSiteGrants={async (siteId, subscription_ids) =>
                !!(await mutate(
                  `/sites/${siteId}/grants`,
                  "PUT",
                  { subscription_ids },
                  `已保存站点 ${siteId} 的订阅授权配置。`,
                ))
              }
              onOpenSite={(siteId) => navigate({ page: "site", siteId })}
            />
          )}
        </main>

        <footer className="statusbar">
          <div className="statusbar-left tabular">
            <span
              className={
                onlineSites === sites.length && sites.length > 0
                  ? "status-dot is-online"
                  : "status-dot is-warn"
              }
              aria-hidden="true"
            />
            <span>
              {onlineSites}/{sites.length} 在线 · {syncedSites} 已同步 ·{" "}
              {sources.length} 条加密订阅
            </span>
          </div>
          <div className="statusbar-right mono-xs muted">
            {lastUpdated ? `更新于 ${lastUpdated}` : "每 30 秒自动刷新"}
          </div>
        </footer>
      </div>

      {toast && (
        <div className="toast-banner" role="status" aria-live="polite">
          <span>{toast}</span>
        </div>
      )}

      <ConnectDeviceDialog
        open={connectOpen}
        busy={busy}
        onClose={() => setConnectOpen(false)}
        onManualCreate={handleCreateSite}
      />
      <RenameSiteDialog
        open={!!renameSiteTarget}
        site={renameSiteTarget}
        busy={busy}
        onClose={() => setRenameSiteTarget(null)}
        onRename={handleRenameSite}
      />
      <SubscriptionDialog
        open={subDialog.open}
        source={subDialog.source}
        busy={busy}
        onClose={() => setSubDialog({ open: false, source: null })}
        onSubmit={handleSaveSubscription}
      />
      <TokenRevealDialog
        issued={issuedToken}
        site={sites.find((s) => s.id === issuedToken?.id)}
        onClose={() => setIssuedToken(null)}
      />
      <ConfirmDialog
        state={confirmState}
        busy={busy}
        onClose={() => setConfirmState(null)}
        onConfirm={() => confirmState?.action()}
      />
      <CommandPaletteDialog
        open={paletteOpen}
        sites={sites}
        sources={sources}
        theme={theme}
        onClose={() => setPaletteOpen(false)}
        onNavigateOverview={() => navigate({ page: "overview" })}
        onNavigateSite={(siteId) => navigate({ page: "site", siteId })}
        onNavigateSubscriptions={() => navigate({ page: "subscriptions" })}
        onConnectDevice={() => setConnectOpen(true)}
        onAddSubscription={() => setSubDialog({ open: true, source: null })}
        onCycleTheme={cycleTheme}
        onRefresh={() => void load().catch(report)}
      />
    </div>
  );
}
