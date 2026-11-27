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
            aria-label="Close dialog"
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
      title={state?.title ?? "Confirm action"}
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
              Cancel
            </button>
            <button
              type="button"
              className={state.danger ? "btn danger" : "btn primary"}
              disabled={busy}
              onClick={() => void onConfirm()}
            >
              {busy ? "Processing…" : state.confirmLabel}
            </button>
          </footer>
        </div>
      )}
    </ModalDialog>
  );
}

export function AddSiteDialog({
  open,
  busy,
  onClose,
  onCreate,
}: {
  open: boolean;
  busy: boolean;
  onClose: () => void;
  onCreate: (payload: {
    id: string;
    name: string;
    issueToken: boolean;
  }) => Promise<boolean>;
}) {
  const [issueToken, setIssueToken] = useState(true);
  const [localError, setLocalError] = useState("");
  const formRef = useRef<HTMLFormElement>(null);

  useEffect(() => {
    if (!open) {
      setLocalError("");
      setIssueToken(true);
      formRef.current?.reset();
    }
  }, [open]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLocalError("");
    const data = new FormData(event.currentTarget);
    const id = String(data.get("id") ?? "").trim();
    const name = String(data.get("name") ?? "").trim();
    if (!/^[a-z][a-z0-9-]{1,47}$/.test(id)) {
      setLocalError("Site ID must start with a lowercase letter and use 2–48 lowercase letters, digits, or hyphens.");
      return;
    }
    if (!name) {
      setLocalError("Site display name is required.");
      return;
    }
    const ok = await onCreate({ id, name, issueToken });
    if (ok) onClose();
  }

  return (
    <ModalDialog
      open={open}
      title="Add Managed Site"
      labelledBy="add-site-title"
      onClose={onClose}
      className="modal-md"
    >
      <form ref={formRef} className="modal-body form-stack" onSubmit={submit}>
        <div className="field-group">
          <label htmlFor="new-site-id">Site Identifier</label>
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
            Immutable slug used in agent config and API routes (<code>[a-z][a-z0-9-]</code>).
          </p>
        </div>
        <div className="field-group">
          <label htmlFor="new-site-name">Display Name</label>
          <input
            id="new-site-name"
            name="name"
            required
            maxLength={120}
            placeholder="Tokyo Primary Edge"
            autoComplete="off"
          />
        </div>
        <label className="checkbox-inline">
          <input
            type="checkbox"
            checked={issueToken}
            onChange={(event) => setIssueToken(event.target.checked)}
          />
          <span>Immediately issue a one-time Device Token after creating the site</span>
        </label>
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
            Cancel
          </button>
          <button type="submit" className="btn primary" disabled={busy}>
            {busy ? "Creating…" : "Create Site"}
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
      setLocalError("Subscription ID must match ^[a-z][a-z0-9_-]{1,47}$.");
      return;
    }
    if (!name) {
      setLocalError("Subscription name is required.");
      return;
    }
    if ((!source || url.length > 0) && !url.startsWith("https://")) {
      setLocalError("Subscription URL must use HTTPS and exclude embedded credentials.");
      return;
    }
    const ok = await onSubmit({ id: source ? undefined : id, name, url });
    if (ok) onClose();
  }

  return (
    <ModalDialog
      open={open}
      title={source ? `Update Subscription · ${source.id}` : "Add Encrypted Subscription"}
      labelledBy="sub-dialog-title"
      onClose={onClose}
      className="modal-md"
    >
      <form ref={formRef} className="modal-body form-stack" onSubmit={submit}>
        {!source && (
          <div className="field-group">
            <label htmlFor="sub-id">Subscription Identifier</label>
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
              Referenced inside each site&apos;s <code>sections</code> map in OpenWrt <code>site-sync</code> config.
            </p>
          </div>
        )}
        <div className="field-group">
          <label htmlFor="sub-name">Display Name</label>
          <input
            id="sub-name"
            name="name"
            required
            maxLength={120}
            defaultValue={source?.name ?? ""}
            placeholder="Upstream Transit Alpha"
            autoComplete="off"
          />
        </div>
        <div className="field-group">
          <label htmlFor="sub-url">HTTPS Subscription URL</label>
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
                  ? "Leave blank to preserve existing encrypted URL"
                  : "https://provider.example.invalid/subscribe?..."
              }
            />
            <button
              type="button"
              className="icon-btn"
              aria-label={showUrl ? "Hide subscription URL" : "Reveal subscription URL"}
              onClick={() => setShowUrl((prev) => !prev)}
            >
              <IconEye open={showUrl} />
            </button>
          </div>
          <p className="field-hint">
            Sealed with AES-256-GCM before storage. Never returned back to browsers after saving.
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
            Cancel
          </button>
          <button type="submit" className="btn primary" disabled={busy}>
            {busy ? "Saving…" : source ? "Save Changes" : "Encrypt & Add"}
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
      title={issued ? `Device Token Issued · ${issued.id}` : "Device Token"}
      labelledBy="token-dialog-title"
      onClose={onClose}
      className="modal-lg"
    >
      {issued && (
        <div className="modal-body form-stack">
          <div className="callout is-warn">
            This secret token is shown once and stored on the server strictly as a SHA-256 hash. Save it into the target router&apos;s private config before closing.
          </div>
          <div className="terminal-panel">
            <div className="terminal-bar">
              <span className="mono-xs">ONE-TIME BEARER TOKEN</span>
              <button
                type="button"
                className="btn-inline"
                onClick={() => copy("token", issued.device_token)}
              >
                {copiedPart === "token" ? <IconCheck /> : <IconCopy />}
                <span>{copiedPart === "token" ? "Copied" : "Copy token"}</span>
              </button>
            </div>
            <pre className="terminal-code">
              <code>{issued.device_token}</code>
            </pre>
          </div>
          <div className="terminal-panel">
            <div className="terminal-bar">
              <span className="mono-xs">
                /etc/opl-netfleet/site-sync/config.json (0600)
              </span>
              <button
                type="button"
                className="btn-inline"
                onClick={() => copy("config", configSnippet)}
              >
                {copiedPart === "config" ? <IconCheck /> : <IconCopy />}
                <span>{copiedPart === "config" ? "Copied" : "Copy JSON"}</span>
              </button>
            </div>
            <pre className="terminal-code">
              <code>{configSnippet}</code>
            </pre>
          </div>
          <footer className="modal-actions">
            <button type="button" className="btn primary" onClick={onClose}>
              Done
            </button>
          </footer>
        </div>
      )}
    </ModalDialog>
  );
}

export type PaletteAction = {
  id: string;
  group: "Navigation" | "Sites" | "Subscriptions" | "Actions";
  title: string;
  meta: string;
  badge?: string;
  run: () => void;
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
  onAddSite,
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
  onAddSite: () => void;
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
        group: "Navigation",
        title: "Overview",
        meta: "Fleet health, active exits, throughput",
        run: onNavigateOverview,
      },
      {
        id: "nav-subs",
        group: "Navigation",
        title: "Subscriptions & Grant Matrix",
        meta: "Encrypted subscription pool and site permissions",
        run: onNavigateSubscriptions,
      },
      ...sites.map((site) => ({
        id: `site-${site.id}`,
        group: "Sites" as const,
        title: site.name,
        meta: `${site.id} · rev ${site.snapshot?.latest.applied_revision ?? "—"}/${site.revision}`,
        badge: site.online ? "Online" : "Offline",
        run: () => onNavigateSite(site.id),
      })),
      ...sources.map((src) => ({
        id: `sub-${src.id}`,
        group: "Subscriptions" as const,
        title: src.name,
        meta: `${src.id} · ${src.fingerprint}`,
        run: onNavigateSubscriptions,
      })),
      {
        id: "act-add-site",
        group: "Actions",
        title: "Add Managed Site",
        meta: "Register a router and issue a device token",
        run: onAddSite,
      },
      {
        id: "act-add-sub",
        group: "Actions",
        title: "Add Encrypted Subscription",
        meta: "Encrypt an HTTPS source URL into the pool",
        run: onAddSubscription,
      },
      {
        id: "act-refresh",
        group: "Actions",
        title: "Refresh Telemetry",
        meta: "Pull latest snapshots and subscription metadata",
        run: onRefresh,
      },
      {
        id: "act-theme",
        group: "Actions",
        title: `Switch Theme (Current: ${theme})`,
        meta: "Cycle system, light, and dark modes",
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
    onAddSite,
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
          Search sites, subscriptions, pages, and actions
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
          placeholder="Search sites, subscriptions, pages, and actions…"
          autoComplete="off"
        />
        <kbd className="kbd-pill">ESC</kbd>
      </div>
      <div className="palette-list" role="listbox" aria-label="Command matches">
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
                    item.badge === "Online" ? "status-pill is-online" : "status-pill is-offline"
                  }
                >
                  {item.badge}
                </span>
              )}
            </button>
          ))
        ) : (
          <p className="palette-empty muted">No matching pages, sites, or actions.</p>
        )}
      </div>
    </ModalDialog>
  );
}
