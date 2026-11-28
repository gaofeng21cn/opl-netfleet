import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type FormEvent,
  type MouseEvent,
  type ReactNode,
} from "react";
import type { Site, Source, ThemeMode } from "./api.js";
import { IconCheck, IconClose, IconCopy, IconEye, IconSearch } from "./charts.js";

function ModalDialog({
  open,
  title,
  labelledBy,
  onClose,
  initialFocusRef,
  className,
  children,
}: {
  open: boolean;
  title?: string;
  labelledBy: string;
  onClose: () => void;
  initialFocusRef?: { current: HTMLElement | null };
  className?: string;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) {
      dialog.returnValue = "";
      dialog.showModal();
      if (initialFocusRef?.current) {
        initialFocusRef.current.focus();
      }
    } else if (!open && dialog.open) {
      dialog.close();
      dialog.returnValue = "";
    }
  }, [open, initialFocusRef]);

  function handleBackdropClick(event: MouseEvent<HTMLDialogElement>) {
    const dialog = ref.current;
    if (!dialog || "closedBy" in HTMLDialogElement.prototype) return;
    if (event.target !== dialog) return;
    const rect = dialog.getBoundingClientRect();
    const inside =
      rect.top <= event.clientY &&
      event.clientY <= rect.top + rect.height &&
      rect.left <= event.clientX &&
      event.clientX <= rect.left + rect.width;
    if (!inside) onClose();
  }

  return (
    <dialog
      ref={ref}
      {...({ closedby: "any" } as Record<string, string>)}
      aria-labelledby={labelledBy}
      className={className ? `modal ${className}` : "modal"}
      onClose={() => {
        if (ref.current) ref.current.returnValue = "";
        onClose();
      }}
      onClick={handleBackdropClick}
    >
      {title && (
        <header className="modal-head">
          <h2 id={labelledBy}>{title}</h2>
          <button
            type="button"
            className="icon-btn"
            aria-label="关闭弹窗"
            onClick={onClose}
          >
            <IconClose />
          </button>
        </header>
      )}
      {children}
    </dialog>
  );
}

export function ConfirmDialog({
  state,
  busy,
  onClose,
  onConfirm,
}: {
  state: {
    title: string;
    message: string;
    confirmLabel: string;
    danger?: boolean;
  } | null;
  busy: boolean;
  onClose: () => void;
  onConfirm: () => Promise<void> | void;
}) {
  const cancelRef = useRef<HTMLButtonElement>(null);

  return (
    <ModalDialog
      open={!!state}
      title={state?.title ?? "确认操作"}
      labelledBy="confirm-dialog-title"
      initialFocusRef={cancelRef}
      onClose={onClose}
      className="modal-sm"
    >
      {state && (
        <div className="modal-body">
          <p className="muted-copy">{state.message}</p>
          <footer className="modal-actions">
            <button
              ref={cancelRef}
              type="button"
              className="btn secondary"
              autoFocus
              disabled={busy}
              onClick={onClose}
            >
              取消
            </button>
            <button
              type="button"
              className={state.danger ? "btn danger" : "btn primary"}
              disabled={busy}
              onClick={() => void onConfirm()}
            >
              {busy ? "处理中…" : state.confirmLabel}
            </button>
          </footer>
        </div>
      )}
    </ModalDialog>
  );
}

export function ConnectDeviceDialog({
  open,
  busy,
  onClose,
  onManualCreate,
}: {
  open: boolean;
  busy: boolean;
  onClose: () => void;
  onManualCreate: (payload: {
    id: string;
    name: string;
    issueToken: boolean;
  }) => Promise<boolean>;
}) {
  const [issueToken, setIssueToken] = useState(true);
  const [localError, setLocalError] = useState("");
  const [copiedPart, setCopiedPart] = useState<"origin" | "cli" | null>(null);
  const formRef = useRef<HTMLFormElement>(null);

  const origin = window.location.origin;
  const cliCommand = useMemo(
    () =>
      [
        "printf 'OPL Gateway 邮箱: '; read -r E; printf '密码: '; stty -echo; read -r P; stty echo; echo",
        `printf '{"origin":"%s","email":"%s","password":"%s"}\\n' "${origin}" "$E" "$P" | ucode /usr/libexec/opl-netfleet/main.uc site-sync-enroll`,
      ].join("\n"),
    [origin],
  );

  useEffect(() => {
    if (!open) {
      setLocalError("");
      setIssueToken(true);
      setCopiedPart(null);
      formRef.current?.reset();
    }
  }, [open]);

  function copy(kind: "origin" | "cli", value: string) {
    void navigator.clipboard
      .writeText(value)
      .then(() => {
        setCopiedPart(kind);
        window.setTimeout(() => setCopiedPart(null), 2000);
      })
      .catch(() => {});
  }

  async function submitManual(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLocalError("");
    const data = new FormData(event.currentTarget);
    const id = String(data.get("id") ?? "").trim();
    const name = String(data.get("name") ?? "").trim();
    if (!/^[a-z][a-z0-9-]{1,47}$/.test(id)) {
      setLocalError("站点 ID 必须以小写字母开头，仅含 2–48 位小写字母、数字或连字符。");
      return;
    }
    if (!name) {
      setLocalError("请填写站点显示名称。");
      return;
    }
    const ok = await onManualCreate({ id, name, issueToken });
    if (ok) onClose();
  }

  return (
    <ModalDialog
      open={open}
      title="接入新设备"
      labelledBy="connect-device-title"
      onClose={onClose}
      className="modal-lg"
    >
      <div className="modal-body form-stack">
        <div className="callout is-info">
          <span>
            无需预先在云端创建站点。在 OpenWrt 路由器端使用您的{" "}
            <strong>OPL Gateway 账号与密码</strong>{" "}
            登录配对后，站点将自动注册、认领并立即出现在当前面板；路由器不落盘保存账号密码。
          </span>
        </div>

        <ol className="connect-steps">
          <li className="connect-step">
            <span className="connect-step-num" aria-hidden="true">
              1
            </span>
            <div className="connect-step-body">
              <strong>在 LuCI 界面一键登录配对（推荐）</strong>
              <p className="muted">
                打开设备 LuCI 中的「服务 → OPL NetFleet → 云端站点同步」，填入下方云端服务地址，并使用当前{" "}
                OPL Gateway 邮箱与密码登录即可。
              </p>
              <div className="origin-copy-bar">
                <code className="origin-copy-url">{origin}</code>
                <button
                  type="button"
                  className="btn secondary btn-sm"
                  onClick={() => copy("origin", origin)}
                >
                  {copiedPart === "origin" ? <IconCheck /> : <IconCopy />}
                  <span>{copiedPart === "origin" ? "已复制" : "复制地址"}</span>
                </button>
              </div>
            </div>
          </li>
          <li className="connect-step">
            <span className="connect-step-num" aria-hidden="true">
              2
            </span>
            <div className="connect-step-body">
              <strong>或通过 OpenWrt SSH 终端交互配对</strong>
              <p className="muted">
                命令会通过隐藏输入读取密码并经标准输入一次性交换设备 Token，避免凭据进入进程列表或 Shell 历史：
              </p>
              <div className="terminal-panel">
                <div className="terminal-bar">
                  <span className="mono-xs">OpenWrt 终端命令（site-sync-enroll）</span>
                  <button
                    type="button"
                    className="btn-inline"
                    onClick={() => copy("cli", cliCommand)}
                  >
                    {copiedPart === "cli" ? <IconCheck /> : <IconCopy />}
                    <span>{copiedPart === "cli" ? "已复制" : "复制命令"}</span>
                  </button>
                </div>
                <pre className="terminal-code">
                  <code>{cliCommand}</code>
                </pre>
              </div>
            </div>
          </li>
        </ol>

        <details className="advanced-box">
          <summary>高级选项：手动预注册站点与签发一次性 Token</summary>
          <form ref={formRef} className="advanced-body form-stack" onSubmit={submitManual}>
            <div className="field-group">
              <label htmlFor="new-site-id">站点 ID（不可修改）</label>
              <input
                id="new-site-id"
                name="id"
                required
                minLength={2}
                maxLength={48}
                pattern="[a-z][a-z0-9\-]{1,47}"
                placeholder="edge-tokyo-01"
                autoComplete="off"
              />
              <p className="field-hint">
                仅用于离线预配置场景（规则 <code>[a-z][a-z0-9-]</code>）。
              </p>
            </div>
            <div className="field-group">
              <label htmlFor="new-site-name">站点显示名称</label>
              <input
                id="new-site-name"
                name="name"
                required
                maxLength={120}
                placeholder="例如：主节点网关"
                autoComplete="off"
              />
            </div>
            <label className="checkbox-inline">
              <input
                type="checkbox"
                checked={issueToken}
                onChange={(event) => setIssueToken(event.target.checked)}
              />
              <span>创建后立即签发一次性设备 Token</span>
            </label>
            {localError && (
              <p className="inline-error" role="alert">
                {localError}
              </p>
            )}
            <div className="modal-actions">
              <button type="submit" className="btn secondary" disabled={busy}>
                {busy ? "创建中…" : "手动创建站点"}
              </button>
            </div>
          </form>
        </details>

        <footer className="modal-actions">
          <button type="button" className="btn primary" onClick={onClose}>
            完成
          </button>
        </footer>
      </div>
    </ModalDialog>
  );
}

export function RenameSiteDialog({
  open,
  site,
  busy,
  onClose,
  onRename,
}: {
  open: boolean;
  site: Site | null;
  busy: boolean;
  onClose: () => void;
  onRename: (id: string, name: string) => Promise<boolean>;
}) {
  const [name, setName] = useState("");
  const [localError, setLocalError] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (open && site) {
      setName(site.name);
      setLocalError("");
    }
  }, [open, site]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!site) return;
    const trimmed = name.trim();
    if (!trimmed) {
      setLocalError("请填写站点显示名称。");
      return;
    }
    if (trimmed.length > 120) {
      setLocalError("站点显示名称长度不能超过 120 个字符。");
      return;
    }
    const ok = await onRename(site.id, trimmed);
    if (ok) onClose();
  }

  return (
    <ModalDialog
      open={open && !!site}
      title={site ? `重命名站点 · ${site.id}` : "重命名站点"}
      labelledBy="rename-site-title"
      initialFocusRef={inputRef}
      onClose={onClose}
      className="modal-sm"
    >
      <form className="modal-body form-stack" onSubmit={submit}>
        <div className="field-group">
          <label htmlFor="rename-site-name">站点显示名称</label>
          <input
            ref={inputRef}
            id="rename-site-name"
            name="name"
            required
            maxLength={120}
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder="例如：主节点网关"
            autoComplete="off"
          />
          <p className="field-hint">
            不会影响设备 ID（<code>{site?.id ?? ""}</code>）或已签发的设备凭据。
          </p>
        </div>
        {localError && (
          <p className="inline-error" role="alert">
            {localError}
          </p>
        )}
        <footer className="modal-actions">
          <button
            type="button"
            className="btn secondary"
            disabled={busy}
            onClick={onClose}
          >
            取消
          </button>
          <button type="submit" className="btn primary" disabled={busy}>
            {busy ? "保存中…" : "保存名称"}
          </button>
        </footer>
      </form>
    </ModalDialog>
  );
}

export function SubscriptionDialog({
  open,
  source,
  busy,
  onClose,
  onSubmit,
}: {
  open: boolean;
  source?: Source | null;
  busy: boolean;
  onClose: () => void;
  onSubmit: (payload: { id?: string; name: string; url: string }) => Promise<boolean>;
}) {
  const [showUrl, setShowUrl] = useState(false);
  const [localError, setLocalError] = useState("");
  const formRef = useRef<HTMLFormElement>(null);

  useEffect(() => {
    if (!open) {
      setShowUrl(false);
      setLocalError("");
      formRef.current?.reset();
    }
  }, [open]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLocalError("");
    const data = new FormData(event.currentTarget);
    const id = source ? source.id : String(data.get("id") ?? "").trim();
    const name = String(data.get("name") ?? "").trim();
    const url = String(data.get("url") ?? "").trim();

    if (!source && !/^[a-z][a-z0-9_-]{1,47}$/.test(id)) {
      setLocalError("订阅 ID 须符合 ^[a-z][a-z0-9_-]{1,47}$。");
      return;
    }
    if (!name) {
      setLocalError("请填写订阅显示名称。");
      return;
    }
    if ((!source || url.length > 0) && !url.startsWith("https://")) {
      setLocalError("订阅 URL 必须以 https:// 开头，且不可包含内嵌用户名密码。");
      return;
    }
    const ok = await onSubmit({ id: source ? undefined : id, name, url });
    if (ok) onClose();
  }

  return (
    <ModalDialog
      open={open}
      title={source ? `编辑订阅 · ${source.id}` : "添加加密订阅"}
      labelledBy="sub-dialog-title"
      onClose={onClose}
      className="modal-md"
    >
      <form ref={formRef} className="modal-body form-stack" onSubmit={submit}>
        {!source && (
          <div className="field-group">
            <label htmlFor="sub-id">订阅 ID（英文标识）</label>
            <input
              id="sub-id"
              name="id"
              required
              minLength={2}
              maxLength={48}
              pattern="[a-z][a-z0-9_\-]{1,47}"
              placeholder="provider-alpha"
              autoComplete="off"
            />
            <p className="field-hint">
              供各站点的 OpenWrt <code>site-sync</code> 配置中的 <code>sections</code> 映射使用。
            </p>
          </div>
        )}
        <div className="field-group">
          <label htmlFor="sub-name">显示名称</label>
          <input
            id="sub-name"
            name="name"
            required
            maxLength={120}
            defaultValue={source?.name ?? ""}
            placeholder="例如：主线机场 A"
            autoComplete="off"
          />
        </div>
        <div className="field-group">
          <label htmlFor="sub-url">HTTPS 订阅链接</label>
          <div className="input-with-action">
            <input
              id="sub-url"
              name="url"
              type={showUrl ? "url" : "password"}
              autoComplete="off"
              required={!source}
              maxLength={2048}
              placeholder={
                source
                  ? "留空则保留当前已加密链接"
                  : "https://provider.example.invalid/subscribe?..."
              }
            />
            <button
              type="button"
              className="icon-btn"
              aria-label={showUrl ? "隐藏订阅链接" : "显示订阅链接"}
              onClick={() => setShowUrl((prev) => !prev)}
            >
              <IconEye open={showUrl} />
            </button>
          </div>
          <p className="field-hint">
            入库前使用 AES-256-GCM 主密钥信封加密，保存后绝不向浏览器回显明文链接。
          </p>
        </div>
        {localError && (
          <p className="inline-error" role="alert">
            {localError}
          </p>
        )}
        <footer className="modal-actions">
          <button
            type="button"
            className="btn secondary"
            disabled={busy}
            onClick={onClose}
          >
            取消
          </button>
          <button type="submit" className="btn primary" disabled={busy}>
            {busy ? "保存中…" : source ? "保存修改" : "加密并添加"}
          </button>
        </footer>
      </form>
    </ModalDialog>
  );
}

export function TokenRevealDialog({
  issued,
  site,
  onClose,
}: {
  issued: { id: string; device_token: string } | null;
  site?: Site;
  onClose: () => void;
}) {
  const [copiedPart, setCopiedPart] = useState<"token" | "config" | null>(null);

  useEffect(() => {
    setCopiedPart(null);
  }, [issued]);

  const configSnippet = useMemo(() => {
    if (!issued) return "";
    const sections = Object.fromEntries(
      (site?.grants.length ? site.grants : ["provider-a"]).map((id) => [
        id,
        id.replace(/-/g, "_"),
      ]),
    );
    return JSON.stringify(
      {
        enabled: true,
        origin: window.location.origin,
        site_id: issued.id,
        token: issued.device_token,
        sections,
      },
      null,
      2,
    );
  }, [issued, site]);

  function copy(kind: "token" | "config", value: string) {
    void navigator.clipboard
      .writeText(value)
      .then(() => {
        setCopiedPart(kind);
        window.setTimeout(() => setCopiedPart(null), 2000);
      })
      .catch(() => {});
  }

  return (
    <ModalDialog
      open={!!issued}
      title={issued ? `设备 Token 已签发 · ${issued.id}` : "设备 Token"}
      labelledBy="token-dialog-title"
      onClose={onClose}
      className="modal-lg"
    >
      {issued && (
        <div className="modal-body form-stack">
          <div className="callout is-warn">
            该一次性设备密钥仅在本次显示，服务端数据库只保存单向 SHA-256 哈希。关闭前请复制并写入目标路由器私有配置文件。
          </div>
          <div className="terminal-panel">
            <div className="terminal-bar">
              <span className="mono-xs">一次性设备 BEARER TOKEN</span>
              <button
                type="button"
                className="btn-inline"
                onClick={() => copy("token", issued.device_token)}
              >
                {copiedPart === "token" ? <IconCheck /> : <IconCopy />}
                <span>{copiedPart === "token" ? "已复制" : "复制 Token"}</span>
              </button>
            </div>
            <pre className="terminal-code">
              <code>{issued.device_token}</code>
            </pre>
          </div>
          <div className="terminal-panel">
            <div className="terminal-bar">
              <span className="mono-xs">
                /etc/opl-netfleet/site-sync/config.json（权限 0600）
              </span>
              <button
                type="button"
                className="btn-inline"
                onClick={() => copy("config", configSnippet)}
              >
                {copiedPart === "config" ? <IconCheck /> : <IconCopy />}
                <span>{copiedPart === "config" ? "已复制" : "复制配置 JSON"}</span>
              </button>
            </div>
            <pre className="terminal-code">
              <code>{configSnippet}</code>
            </pre>
          </div>
          <footer className="modal-actions">
            <button type="button" className="btn primary" onClick={onClose}>
              我已保存，完成
            </button>
          </footer>
        </div>
      )}
    </ModalDialog>
  );
}

export type PaletteAction = {
  id: string;
  group: "页面导航" | "纳管站点" | "订阅源" | "快捷操作";
  title: string;
  meta: string;
  badge?: string;
  run: () => void;
};

const THEME_NAMES: Record<ThemeMode, string> = {
  system: "跟随系统",
  light: "浅色",
  dark: "深色",
};

export function CommandPaletteDialog({
  open,
  sites,
  sources,
  theme,
  onClose,
  onNavigateOverview,
  onNavigateSite,
  onNavigateSubscriptions,
  onConnectDevice,
  onAddSubscription,
  onCycleTheme,
  onRefresh,
}: {
  open: boolean;
  sites: Site[];
  sources: Source[];
  theme: ThemeMode;
  onClose: () => void;
  onNavigateOverview: () => void;
  onNavigateSite: (id: string) => void;
  onNavigateSubscriptions: () => void;
  onConnectDevice: () => void;
  onAddSubscription: () => void;
  onCycleTheme: () => void;
  onRefresh: () => void;
}) {
  const [query, setQuery] = useState("");
  const [activeIndex, setActiveIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (open) {
      setQuery("");
      setActiveIndex(0);
    }
  }, [open]);

  const items = useMemo<PaletteAction[]>(() => {
    const base: PaletteAction[] = [
      {
        id: "nav-overview",
        group: "页面导航",
        title: "站点总览",
        meta: "全部站点运行状态、出口延迟与实时吞吐",
        run: onNavigateOverview,
      },
      {
        id: "nav-subs",
        group: "页面导航",
        title: "订阅与站点授权",
        meta: "加密订阅池维护与按站点子集分发矩阵",
        run: onNavigateSubscriptions,
      },
      ...sites.map((site) => ({
        id: `site-${site.id}`,
        group: "纳管站点" as const,
        title: site.name,
        meta: `${site.id} · 版本 ${site.snapshot?.latest.applied_revision ?? "—"}/${site.revision}`,
        badge: site.online ? "在线" : "离线",
        run: () => onNavigateSite(site.id),
      })),
      ...sources.map((src) => ({
        id: `sub-${src.id}`,
        group: "订阅源" as const,
        title: src.name,
        meta: `${src.id} · 摘要 ${src.fingerprint}`,
        run: onNavigateSubscriptions,
      })),
      {
        id: "act-connect-device",
        group: "快捷操作",
        title: "接入新设备",
        meta: "通过设备端 OPL Gateway 账密自动注册并配对站点",
        run: onConnectDevice,
      },
      {
        id: "act-add-sub",
        group: "快捷操作",
        title: "添加加密订阅",
        meta: "将上游 HTTPS 订阅链接信封加密后加入订阅池",
        run: onAddSubscription,
      },
      {
        id: "act-refresh",
        group: "快捷操作",
        title: "立即刷新遥测数据",
        meta: "拉取最新站点心跳快照与订阅元信息",
        run: onRefresh,
      },
      {
        id: "act-theme",
        group: "快捷操作",
        title: `切换外观主题（当前：${THEME_NAMES[theme]}）`,
        meta: "在跟随系统、浅色与深色模式间切换",
        run: onCycleTheme,
      },
    ];
    const needle = query.trim().toLowerCase();
    if (!needle) return base;
    return base.filter(
      (item) =>
        item.title.toLowerCase().includes(needle) ||
        item.meta.toLowerCase().includes(needle) ||
        item.group.toLowerCase().includes(needle),
    );
  }, [
    query,
    sites,
    sources,
    theme,
    onNavigateOverview,
    onNavigateSite,
    onNavigateSubscriptions,
    onConnectDevice,
    onAddSubscription,
    onCycleTheme,
    onRefresh,
  ]);

  useEffect(() => {
    setActiveIndex(0);
  }, [query]);

  const safeIndex = items.length ? Math.min(activeIndex, items.length - 1) : 0;

  return (
    <ModalDialog
      open={open}
      labelledBy="palette-label"
      initialFocusRef={inputRef}
      onClose={onClose}
      className="modal-palette"
    >
      <div className="palette-head">
        <IconSearch />
        <label id="palette-label" htmlFor="palette-input" className="sr-only">
          搜索站点、订阅、页面或快捷操作
        </label>
        <input
          ref={inputRef}
          id="palette-input"
          type="search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "ArrowDown" && items.length) {
              event.preventDefault();
              setActiveIndex((prev) => (prev + 1) % items.length);
            } else if (event.key === "ArrowUp" && items.length) {
              event.preventDefault();
              setActiveIndex((prev) => (prev - 1 + items.length) % items.length);
            } else if (event.key === "Enter" && items[safeIndex]) {
              event.preventDefault();
              event.stopPropagation();
              items[safeIndex].run();
              onClose();
            }
          }}
          placeholder="搜索站点、订阅、页面或操作…"
          autoComplete="off"
        />
        <kbd className="kbd-pill">ESC</kbd>
      </div>
      <div className="palette-list" role="listbox" aria-label="匹配结果">
        {items.length ? (
          items.map((item, idx) => (
            <button
              key={item.id}
              type="button"
              role="option"
              aria-selected={idx === safeIndex}
              className={idx === safeIndex ? "palette-row is-selected" : "palette-row"}
              onMouseEnter={() => setActiveIndex(idx)}
              onClick={() => {
                item.run();
                onClose();
              }}
            >
              <div className="palette-row-main">
                <span className="palette-group">{item.group}</span>
                <strong>{item.title}</strong>
                <span className="muted mono-xs">{item.meta}</span>
              </div>
              {item.badge && (
                <span
                  className={
                    item.badge === "在线" ? "status-pill is-online" : "status-pill is-offline"
                  }
                >
                  {item.badge}
                </span>
              )}
            </button>
          ))
        ) : (
          <p className="palette-empty muted">没有匹配的页面、站点或操作。</p>
        )}
      </div>
    </ModalDialog>
  );
}
