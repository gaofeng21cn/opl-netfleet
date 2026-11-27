import {
  createServer,
  type IncomingMessage,
  type ServerResponse,
} from "node:http";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { CloudApp } from "./app.js";
import { FirestoreStore, SqliteStore } from "./store.js";

const app = new CloudApp(
  process.env.OPL_NETFLEET_CLOUD_STORE === "firestore"
    ? new FirestoreStore()
    : new SqliteStore(process.env.OPL_NETFLEET_CLOUD_SQLITE_FILE ?? ":memory:"),
);
const files = { js: "text/javascript", css: "text/css", html: "text/html" };

async function body(request: IncomingMessage) {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 65536) return null;
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    return null;
  }
}

function json(
  response: ServerResponse,
  status: number,
  value: unknown,
  headers = {},
) {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    ...headers,
  });
  response.end(JSON.stringify(value));
}

async function route(request: IncomingMessage, response: ServerResponse) {
  response.setHeader("x-content-type-options", "nosniff");
  response.setHeader(
    "content-security-policy",
    "default-src 'self'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
  );
  const path = new URL(request.url ?? "/", "http://localhost").pathname;
  const method = request.method;
  const headers = new Headers();
  for (const [key, value] of Object.entries(request.headers))
    if (typeof value === "string") headers.set(key, value);
  const secure =
    !!process.env.K_SERVICE ||
    process.env.OPL_NETFLEET_CLOUD_SECURE_COOKIE !== "0";
  if (method === "GET" && ["/readyz", "/healthz"].includes(path))
    return json(response, 200, { status: "ok" });

  if (path.startsWith("/api/")) {
    if (
      ["POST", "PUT", "DELETE"].includes(method ?? "") &&
      headers.get("sec-fetch-site") === "cross-site"
    ) {
      return json(response, 403, { error: "origin_forbidden" });
    }
    const cookie = (value: string, age: number) => ({
      "set-cookie": `opl_netfleet_session=${value}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${age}${secure ? "; Secure" : ""}`,
    });
    if (method === "POST" && path === "/api/v1/auth/login") {
      const session = await app.login(await body(request));
      return session
        ? json(response, 200, { ok: true }, cookie(session, 3600))
        : json(response, 401, { error: "unauthorized" });
    }
    if (method === "POST" && path === "/api/v1/auth/logout")
      return json(response, 200, { ok: true }, cookie("", 0));

    const site = path.match(
      /^\/api\/v1\/sites\/([a-z][a-z0-9-]{1,47})(?:\/(token|grants))?$/,
    );
    const source = path.match(
      /^\/api\/v1\/subscriptions\/([a-z][a-z0-9_-]{1,47})$/,
    );
    let result;
    if (method === "POST" && path === "/api/v1/agent/heartbeat")
      result = await app.heartbeat(headers, await body(request));
    else if (method === "GET" && path === "/api/v1/agent/subscriptions")
      result = await app.subscriptions(headers);
    else if (method === "POST" && path === "/api/v1/internal/watchdog")
      result = await app.watchdog(headers);
    else if (method === "GET" && path === "/api/v1/sites")
      result = await app.overview(headers);
    else if (method === "POST" && path === "/api/v1/sites")
      result = await app.createSite(headers, await body(request));
    else if (site?.[2] === "token" && method === "POST")
      result = await app.rotateToken(headers, site[1]);
    else if (site?.[2] === "token" && method === "DELETE")
      result = await app.revokeToken(headers, site[1]);
    else if (site?.[2] === "grants" && method === "PUT")
      result = await app.grants(headers, site[1], await body(request));
    else if (site && !site[2] && method === "DELETE")
      result = await app.deleteSite(headers, site[1]);
    else if (method === "GET" && path === "/api/v1/subscriptions")
      result = await app.listSubscriptions(headers);
    else if (method === "POST" && path === "/api/v1/subscriptions")
      result = await app.createSubscription(headers, await body(request));
    else if (source && method === "PUT")
      result = await app.updateSubscription(
        headers,
        source[1],
        await body(request),
      );
    else if (source && method === "DELETE")
      result = await app.deleteSubscription(headers, source[1]);
    if (result) return json(response, result.status, result.body);
  }

  if (
    method === "GET" &&
    (path === "/" || /^\/assets\/[\w-]+\.(?:js|css)$/.test(path))
  ) {
    const asset = path === "/" ? "/index.html" : path;
    const full = fileURLToPath(new URL(`../web${asset}`, import.meta.url));
    if (existsSync(full)) {
      const type = asset.split(".").at(-1) as keyof typeof files;
      response.writeHead(200, {
        "content-type": `${files[type]}; charset=utf-8`,
        "cache-control":
          type === "html" ? "no-cache" : "public, max-age=31536000, immutable",
      });
      return response.end(readFileSync(full));
    }
  }
  return json(response, 404, { error: "not_found" });
}

const port = Number(process.env.PORT ?? 8788);
createServer((request, response) => {
  void route(request, response).catch(() => {
    if (!response.headersSent && !response.destroyed)
      json(response, 503, { error: "service_unavailable" });
  });
}).listen(port, "0.0.0.0");
