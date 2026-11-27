import React, { useEffect, useState, type FormEvent } from "react";
import { createRoot } from "react-dom/client";
import type { Snapshot, Trend } from "../contracts.js";
import "./style.css";

type Site = {
  id: string;
  name: string;
  revision: number;
  grants: string[];
  token_active: boolean;
  online: boolean;
  snapshot: Snapshot | null;
};
type Source = { id: string; name: string; fingerprint: string };
type Verb = "GET" | "POST" | "PUT" | "DELETE";

class ApiError extends Error {
  constructor(readonly status: number) {
    super(`请求失败（HTTP ${status}）`);
  }
}

async function api<T>(
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
  if (!response.ok) throw new ApiError(response.status);
  return response.json() as Promise<T>;
}

function formatBytes(value: number | undefined) {
  if (value == null) return "—";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${value.toLocaleString(undefined, { maximumFractionDigits: 1 })} ${units[unit]}`;
}

const metrics = {
  download_bps: "下行速率",
  upload_bps: "上行速率",
  rtt_ms: "平均 RTT",
} as const;
function TrendView({ points }: { points: Trend[] }) {
  const [metric, setMetric] = useState<keyof typeof metrics>("download_bps");
  const values = points.flatMap((point) =>
    point[metric] == null ? [] : [{ time: point.at, value: point[metric] }],
  );
  if (!points.length) return null;
  const last = Date.parse(points.at(-1)!.at);
  const max = Math.max(1, ...values.map((point) => point.value));
  return (
    <details>
      <summary>最近 24 小时趋势</summary>
      <label>
        指标{" "}
        <select
          value={metric}
          onChange={(event) =>
            setMetric(event.target.value as keyof typeof metrics)
          }
        >
          {Object.entries(metrics).map(([key, name]) => (
            <option key={key} value={key}>
              {name}
            </option>
          ))}
        </select>
      </label>
      {values.length ? (
        <>
          <div className="trend" role="img" aria-label={metrics[metric]}>
            {values.map((point) => (
              <div
                key={point.time}
                className="bar"
                style={
                  {
                    "--x":
                      ((Date.parse(point.time) - last + 86400000) * 100) /
                        86400000 +
                      "%",
                    "--y": Math.max(2, (point.value * 100) / max) + "%",
                  } as React.CSSProperties
                }
                title={
                  new Date(point.time).toLocaleString() +
                  " · " +
                  point.value +
                  (metric === "rtt_ms" ? " ms" : " bit/s")
                }
              />
            ))}
          </div>
          <div className="axis">
            <span>24 小时前</span>
            <span>最近一档</span>
          </div>
        </>
      ) : (
        <p>暂无该指标的采样</p>
      )}
    </details>
  );
}

function SiteCard({ site }: { site: Site }) {
  const latest = site.snapshot?.latest;
  const traffic = latest?.traffic;
  return (
    <article className="site">
      <div className="site-head">
        <div>
          <h2>{site.name}</h2>
          <code>{site.id}</code>
        </div>
        <span className={site.online ? "online" : "offline"}>
          {site.online ? "在线" : "离线"}
        </span>
      </div>
      <dl>
        <div>
          <dt>最后心跳</dt>
          <dd>
            {site.snapshot
              ? new Date(site.snapshot.last_seen_at).toLocaleString()
              : "尚未上报"}
          </dd>
        </div>
        <div>
          <dt>运行模式</dt>
          <dd>
            {latest?.mode ?? "—"}
            {latest?.recovery ? " · 恢复中" : ""}
          </dd>
        </div>
        <div>
          <dt>已应用 / 目标版本</dt>
          <dd>
            {latest?.applied_revision ?? "—"} / {site.revision} ·{" "}
            {latest
              ? latest.applied_revision === site.revision
                ? "一致"
                : "待同步"
              : "待上报"}
          </dd>
        </div>
        <div>
          <dt>实时上行 / 下行</dt>
          <dd>
            {[traffic?.upload_bps, traffic?.download_bps]
              .map((value) =>
                value == null
                  ? "—"
                  : (value / 1000).toLocaleString() + " kbit/s",
              )
              .join(" / ")}
          </dd>
        </div>
        <div>
          <dt>累计上行 / 下行</dt>
          <dd>
            {formatBytes(traffic?.upload_bytes)} /{" "}
            {formatBytes(traffic?.download_bytes)}
          </dd>
        </div>
      </dl>
      {!!latest?.capabilities.length && (
        <ul className="metrics">
          {latest.capabilities.map((item) => (
            <li key={item.id}>
              <strong>{item.id}</strong>
              <span>
                {[
                  item.region,
                  item.provider,
                  item.node,
                  item.rtt_ms == null ? "无 RTT" : `${item.rtt_ms} ms`,
                ]
                  .filter(Boolean)
                  .join(" · ")}
              </span>
            </li>
          ))}
        </ul>
      )}
      {!!latest?.quotas?.length && (
        <ul className="metrics">
          {latest.quotas.map((quota) => (
            <li key={quota.provider}>
              <strong>{quota.provider}</strong>
              <span>
                剩余 {formatBytes(quota.remaining_bytes)} /{" "}
                {formatBytes(quota.total_bytes)}
              </span>
            </li>
          ))}
        </ul>
      )}
      <TrendView points={site.snapshot?.trend ?? []} />
    </article>
  );
}

type Mutation = <T>(
  path: string,
  method: Verb,
  body?: unknown,
) => Promise<T | undefined>;
function SubscriptionForm({
  source,
  mutate,
  done,
  busy,
}: {
  source?: Source;
  mutate: Mutation;
  done: () => void;
  busy: boolean;
}) {
  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = event.currentTarget;
    const fields = new FormData(form);
    const payload = { name: fields.get("name"), url: fields.get("url") };
    const result = await mutate(
      source ? `/subscriptions/${source.id}` : "/subscriptions",
      source ? "PUT" : "POST",
      source ? payload : { ...payload, id: fields.get("id") },
    );
    if (result) {
      form.reset();
      done();
    }
  }
  return (
    <form className="fields" onSubmit={save}>
      {!source && (
        <label>
          订阅 ID
          <input
            name="id"
            required
            pattern="[a-z][a-z0-9_\-]{1,47}"
            placeholder="provider-a"
          />
        </label>
      )}
      <label>
        名称
        <input
          name="name"
          required
          maxLength={120}
          defaultValue={source?.name}
        />
      </label>
      <label>
        订阅 URL
        <input
          name="url"
          type="password"
          autoComplete="off"
          required={!source}
          maxLength={2048}
          placeholder={source ? "留空保留原链接" : "https://…"}
        />
      </label>
      <button disabled={busy}>{source ? "保存修改" : "添加订阅"}</button>
      {source && (
        <button type="button" className="secondary" onClick={done}>
          取消
        </button>
      )}
    </form>
  );
}

function Manage({
  sites,
  sources,
  mutate,
  busy,
}: {
  sites: Site[];
  sources: Source[];
  mutate: Mutation;
  busy: boolean;
}) {
  const [editing, edit] = useState<string>();
  const [issued, setIssued] = useState<{ id: string; device_token: string }>();
  return (
    <div className="stack">
      <section className="site">
        <h2>订阅池</h2>
        <SubscriptionForm mutate={mutate} done={() => {}} busy={busy} />
        {sources.map((source) => (
          <div className="row" key={source.id}>
            <div>
              <strong>{source.name}</strong>{" "}
              <code>
                {source.id} · {source.fingerprint}
              </code>
            </div>
            {editing === source.id ? (
              <SubscriptionForm
                source={source}
                mutate={mutate}
                done={() => edit(undefined)}
                busy={busy}
              />
            ) : (
              <div className="actions">
                <button className="secondary" onClick={() => edit(source.id)}>
                  编辑
                </button>
                <button
                  className="secondary"
                  disabled={busy}
                  onClick={() => {
                    if (confirm(`删除「${source.name}」并移除全部站点授权？`))
                      void mutate(`/subscriptions/${source.id}`, "DELETE");
                  }}
                >
                  删除
                </button>
              </div>
            )}
          </div>
        ))}
      </section>
      <section className="site">
        <h2>站点授权矩阵</h2>
        <form
          className="fields"
          onSubmit={async (event) => {
            event.preventDefault();
            const form = event.currentTarget;
            const data = new FormData(form);
            if (await mutate("/sites", "POST", Object.fromEntries(data)))
              form.reset();
          }}
        >
          <label>
            站点 ID
            <input
              name="id"
              required
              pattern="[a-z][a-z0-9\-]{1,47}"
              placeholder="site-a"
            />
          </label>
          <label>
            名称
            <input name="name" required maxLength={120} />
          </label>
          <button disabled={busy}>创建站点</button>
        </form>
        {issued && (
          <aside className="secret" role="status">
            <p>{issued.id} 的 Device Token，仅显示本次</p>
            <code>{issued.device_token}</code>
            <div className="actions">
              <button
                onClick={() => {
                  void navigator.clipboard
                    .writeText(issued.device_token)
                    .catch(() => {});
                }}
              >
                复制
              </button>
              <button
                className="secondary"
                onClick={() => setIssued(undefined)}
              >
                关闭
              </button>
            </div>
          </aside>
        )}
        {sites.map((site) => (
          <div className="row" key={site.id}>
            <div>
              <strong>{site.name}</strong>{" "}
              <code>
                {site.id} · rev {site.revision}
              </code>
            </div>
            <fieldset disabled={busy}>
              <legend>允许分发</legend>
              {sources.map((source) => (
                <label key={source.id} className="check">
                  <input
                    type="checkbox"
                    checked={site.grants.includes(source.id)}
                    onChange={(event) => {
                      const subscription_ids = event.target.checked
                        ? [...site.grants, source.id]
                        : site.grants.filter((id) => id !== source.id);
                      void mutate(`/sites/${site.id}/grants`, "PUT", {
                        subscription_ids,
                      });
                    }}
                  />
                  {source.name}
                </label>
              ))}
              {!sources.length && <span>暂无可分发订阅</span>}
            </fieldset>
            <div className="actions">
              <button
                className="secondary"
                disabled={busy}
                onClick={async () => {
                  if (
                    site.token_active &&
                    !confirm("轮转后旧 Token 立即失效，继续？")
                  )
                    return;
                  setIssued(
                    await mutate<{ id: string; device_token: string }>(
                      `/sites/${site.id}/token`,
                      "POST",
                    ),
                  );
                }}
              >
                {site.token_active ? "轮转 Token" : "签发 Token"}
              </button>
              {site.token_active && (
                <button
                  className="secondary"
                  disabled={busy}
                  onClick={async () => {
                    if (
                      confirm("吊销本站点 Token？") &&
                      (await mutate(`/sites/${site.id}/token`, "DELETE"))
                    )
                      setIssued(undefined);
                  }}
                >
                  吊销
                </button>
              )}
              <button
                className="secondary"
                disabled={busy}
                onClick={async () => {
                  if (
                    confirm(`删除站点「${site.name}」及其时序记录？`) &&
                    (await mutate(`/sites/${site.id}`, "DELETE"))
                  )
                    setIssued(undefined);
                }}
              >
                删除站点
              </button>
            </div>
          </div>
        ))}
      </section>
    </div>
  );
}

function App() {
  const [auth, setAuth] = useState<"loading" | "signed-out" | "signed-in">(
    "loading",
  );
  const [sites, setSites] = useState<Site[]>([]);
  const [sources, setSources] = useState<Source[]>([]);
  const [page, setPage] = useState<"overview" | "manage">("overview");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  function signedOut() {
    setAuth("signed-out");
    setSites([]);
    setSources([]);
  }
  async function load() {
    const [current, pool] = await Promise.all([
      api<{ sites: Site[] }>("/sites"),
      api<{ subscriptions: Source[] }>("/subscriptions"),
    ]);
    setSites(current.sites);
    setSources(pool.subscriptions);
    setAuth("signed-in");
  }
  function report(cause: unknown) {
    if (cause instanceof ApiError && cause.status === 401) {
      signedOut();
      setError("请使用获准的 Gateway Access Token 登录");
    } else {
      setError(cause instanceof Error ? cause.message : "请求失败");
      setAuth((value) => (value === "loading" ? "signed-out" : value));
    }
  }
  useEffect(() => {
    void load().catch((cause) => {
      if (cause instanceof ApiError && cause.status === 401) signedOut();
      else report(cause);
    });
  }, []);
  useEffect(() => {
    if (auth !== "signed-in" || busy) return;
    const timer = window.setInterval(() => {
      if (!document.hidden) void load().catch(report);
    }, 30000);
    return () => window.clearInterval(timer);
  }, [auth, busy]);

  const mutate: Mutation = async (path, method, body) => {
    setBusy(true);
    setError("");
    try {
      const result = await api(path, method, body);
      await load().catch(report);
      return result as never;
    } catch (cause) {
      report(cause);
    } finally {
      setBusy(false);
    }
  };
  if (auth === "loading")
    return (
      <main>
        <p role="status">正在检查会话…</p>
      </main>
    );
  if (auth === "signed-out")
    return (
      <main className="login">
        <section>
          <p className="eyebrow">OPL NETFLEET CLOUD</p>
          <h1>站点管理登录</h1>
          <form
            onSubmit={async (event) => {
              event.preventDefault();
              const form = event.currentTarget;
              const token = new FormData(form).get("token");
              form.reset();
              setBusy(true);
              setError("");
              try {
                await api("/auth/login", "POST", { token });
                await load();
              } catch (cause) {
                report(cause);
              } finally {
                setBusy(false);
              }
            }}
          >
            <label htmlFor="token">Gateway Access Token</label>
            <input
              id="token"
              name="token"
              type="password"
              autoComplete="off"
              required
            />
            <button disabled={busy}>登录</button>
          </form>
          {error && (
            <p className="error" role="alert">
              {error}
            </p>
          )}
        </section>
      </main>
    );

  return (
    <main>
      <header>
        <div>
          <p className="eyebrow">OPL NETFLEET CLOUD</p>
          <h1>多站点监控</h1>
        </div>
        <button
          className="secondary"
          disabled={busy}
          onClick={async () => {
            setError("");
            try {
              await api("/auth/logout", "POST");
              signedOut();
            } catch (cause) {
              report(cause);
            }
          }}
        >
          退出
        </button>
      </header>
      <nav aria-label="页面">
        <button
          aria-pressed={page === "overview"}
          className={page === "overview" ? "selected" : ""}
          onClick={() => setPage("overview")}
        >
          站点总览
        </button>
        <button
          aria-pressed={page === "manage"}
          className={page === "manage" ? "selected" : ""}
          onClick={() => setPage("manage")}
        >
          订阅与站点
        </button>
      </nav>
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      {page === "manage" ? (
        <Manage sites={sites} sources={sources} mutate={mutate} busy={busy} />
      ) : sites.length ? (
        <section className="grid">
          {sites.map((site) => (
            <SiteCard key={site.id} site={site} />
          ))}
        </section>
      ) : (
        <section className="site">
          <h2>暂无站点</h2>
          <button onClick={() => setPage("manage")}>添加站点</button>
        </section>
      )}
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
