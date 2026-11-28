import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const image = process.argv[2];
if (!image) throw new Error("Pass a built container image");
const fixtures = mkdtempSync(join(tmpdir(), "netfleet-container-"));
let container;

function docker(...args) { return execFileSync("docker", args, { encoding: "utf8" }).trim(); }
try {
  for (const name of ["master", "session", "watchdog"]) writeFileSync(join(fixtures, name), Buffer.alloc(32, 7));
  writeFileSync(join(fixtures, "identity.mjs"), `
    const real = globalThis.fetch;
    globalThis.fetch = (url, options) => url === "https://gateway.example.invalid/api/v1/auth/me"
      ? Promise.resolve(new Response(JSON.stringify({code:0,data:{id:1,status:"active",email:"operator@example.invalid"}}),
            {status:options.headers.Authorization==="Bearer fixture-access" ? 200 : 401}))
      : real(url, options);
  `);
  assert.equal(docker("image", "inspect", image, "--format", "{{.Os}}/{{.Architecture}} {{.Config.User}}"), "linux/amd64 node");
  container = docker("run", "-d", "--platform", "linux/amd64", "-p", "127.0.0.1::8788", "-v", fixtures + ":/fixtures:ro",
    "-e", "OPL_NETFLEET_CLOUD_GATEWAY_ORIGIN=https://gateway.example.invalid", "-e", "OPL_NETFLEET_CLOUD_ADMIN_EMAILS=operator@example.invalid",
    "-e", "OPL_NETFLEET_CLOUD_MASTER_KEY_FILE=/fixtures/master", "-e", "OPL_NETFLEET_CLOUD_SESSION_KEY_FILE=/fixtures/session",
    "-e", "OPL_NETFLEET_CLOUD_WATCHDOG_SECRET_FILE=/fixtures/watchdog", "-e", "OPL_NETFLEET_CLOUD_SQLITE_FILE=/data/store.sqlite",
    image, "node", "--import", "/fixtures/identity.mjs", "dist/server.js");
  const origin = "http://" + docker("port", container, "8788/tcp");
  let healthy = false;
  for (let attempt = 0; attempt < 25; attempt++) {
    try { healthy = (await fetch(origin + "/readyz")).ok; } catch {}
    if (healthy) break;
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  assert.equal(healthy, true);
  let cookie;
  async function request(path, status, { method = "GET", data, credential, manage } = {}) {
    const headers = {};
    if (data !== undefined) headers["content-type"] = "application/json";
    if (credential) headers.authorization = "Bearer " + credential;
    if (manage) headers.cookie = cookie;
    const response = await fetch(origin + path, { method, headers, body: JSON.stringify(data) });
    assert.equal(response.status, status, path);
    return response;
  }
  for (const probe of ["/readyz", "/healthz"]) assert.deepEqual(await (await request(probe, 200)).json(), { status: "ok" });
  assert.match(await (await request("/", 200)).text(), /<div id="root"/);
  await request("/api/v1/sites", 401);
  await request("/api/v1/agent/subscriptions", 401, { credential: "invalid" });
  const login = await request("/api/v1/auth/login", 200, { method: "POST", data: { token: "fixture-access" } });
  const header = login.headers.get("set-cookie");
  assert.match(header, /HttpOnly; SameSite=Lax; Max-Age=3600; Secure/);
  cookie = header.split(";")[0];
  const tokens = {};
  for (const id of ["site-a", "restricted-site"]) {
    await request("/api/v1/sites", 201, { method: "POST", manage: true, data: { id, name: id } });
    const reply = await request("/api/v1/sites/" + id + "/token", 200, { method: "POST", manage: true });
    tokens[id] = (await reply.json()).device_token;
  }
  for (const id of ["provider-a", "provider-b"]) await request("/api/v1/subscriptions", 201, {
    method: "POST", manage: true, data: { id, name: id, url: "https://provider.example.invalid/" + id }
  });
  for (const [id, grants] of [["site-a", ["provider-a", "provider-b"]], ["restricted-site", ["provider-a"]]]) {
    await request("/api/v1/sites/" + id + "/grants", 200, { method: "PUT", manage: true, data: { subscription_ids: grants } });
    const reply = await request("/api/v1/agent/subscriptions", 200, { credential: tokens[id] });
    assert.deepEqual((await reply.json()).subscriptions.map(item => item.id), grants);
  }
  const heartbeat = { site_id: "site-a", applied_revision: 1, mode: "netfleet", capabilities: [], traffic: { upload_bytes: 12 } };
  await request("/api/v1/agent/heartbeat", 400, { method: "POST", credential: tokens["site-a"], data: { ...heartbeat, client_ip: "192.0.2.1" } });
  const receipt = await request("/api/v1/agent/heartbeat", 200, { method: "POST", credential: tokens["site-a"], data: heartbeat });
  assert.equal((await receipt.json()).desired_revision, 1);
  const sites = await (await request("/api/v1/sites", 200, { manage: true })).json();
  assert.equal(sites.sites.find(site => site.id === "site-a").online, true);
  assert.ok(!JSON.stringify(sites).includes(tokens["site-a"]));
  const watchdog = await request("/api/v1/internal/watchdog", 200, { method: "POST", credential: Buffer.alloc(32, 7).toString("base64url") });
  assert.deepEqual((await watchdog.json()).sites.map(site => site.site_id), ["restricted-site"]);
  await request("/api/v1/sites/restricted-site/token", 200, { method: "DELETE", manage: true });
  await request("/api/v1/agent/subscriptions", 401, { credential: tokens["restricted-site"] });
  console.log("linux/amd64 UID node, readiness/health 200, both 401 guards, login cookie, grants, heartbeat, watchdog and token revoke passed");
} finally {
  if (container) docker("rm", "-f", container);
  rmSync(fixtures, { recursive: true, force: true });
}
