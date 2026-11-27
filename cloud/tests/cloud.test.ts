import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { CloudApp } from "../src/app.js";
import type { Catalog, Change, Identity, Snapshot, Store } from "../src/contracts.js";
import { open, seal, sha256 } from "../src/crypto.js";
import { OplGatewayIdentityProvider } from "../src/identity.js";
import { FirestoreStore, SqliteStore } from "../src/store.js";

class MemoryStore implements Store {
  catalogValue: Catalog = { sites: {}, subscriptions: {} };
  snapshotsValue = new Map<string, Snapshot>();

  async catalog() { return structuredClone(this.catalogValue); }
  async change<T>(fn: (catalog: Catalog) => Change<T>) {
    const catalog = structuredClone(this.catalogValue);
    const change = fn(catalog);
    if (change.write) this.catalogValue = catalog;
    if (change.removeSnapshot) this.snapshotsValue.delete(change.removeSnapshot);
    return change.result;
  }
  async snapshots(ids: string[]) { return ids.map(id => structuredClone(this.snapshotsValue.get(id) ?? null)); }
  async heartbeat<T>(id: string, fn: (catalog: Catalog, old: Snapshot | null) => { result: T; snapshot?: Snapshot }) {
    const result = fn(structuredClone(this.catalogValue), structuredClone(this.snapshotsValue.get(id) ?? null));
    if (result.snapshot) this.snapshotsValue.set(id, result.snapshot);
    return result.result;
  }
}

class FakeFirestore {
  documents = new Map<string, unknown>();
  doc(path: string) { return { path, get: async () => this.row({ path }) }; }
  async getAll(...refs: { path: string }[]) { return refs.map(ref => this.row(ref)); }
  row(ref: { path: string }) { return { data: () => structuredClone(this.documents.get(ref.path)) }; }
  async runTransaction<T>(callback: (transaction: {
    get: (ref: { path: string }) => Promise<{ data: () => unknown }>;
    getAll: (...refs: { path: string }[]) => Promise<{ data: () => unknown }[]>;
    set: (ref: { path: string }, value: unknown) => void;
    delete: (ref: { path: string }) => void;
  }) => Promise<T>) {
    const writes: (() => void)[] = [];
    const tx = {
      get: async (ref: { path: string }) => this.row(ref),
      getAll: async (...refs: { path: string }[]) => refs.map(ref => this.row(ref)),
      set: (ref: { path: string }, value: unknown) => writes.push(() => this.documents.set(ref.path, structuredClone(value))),
      delete: (ref: { path: string }) => writes.push(() => this.documents.delete(ref.path)),
    };
    const result = await callback(tx);
    writes.forEach(write => write());
    return result;
  }
}

const identity: Identity = { subject: "operator-1", email: "operator@example.invalid", role: "admin" };
const admin = { authenticate: async (value: string) => value === "approved" ? identity : null };
const heartbeat = { site_id: "site-a", applied_revision: 0, mode: "mihomo", capabilities: [{ id: "proxy-main", provider: "provider-a", node: "node-0123456789ab", rtt_ms: 28 }], traffic: { upload_bps: 100, download_bytes: 250 } };

test("AES-256-GCM envelopes bind ciphertext to their object", () => {
  const key = Buffer.alloc(32, 3);
  const envelope = seal("https://provider.example.invalid/sub", key, "subscription:provider-a");
  assert.equal(open(envelope, key, "subscription:provider-a"), "https://provider.example.invalid/sub");
  assert.throws(() => open(envelope, key, "subscription:provider-b"));
  assert.equal(sha256("token").length, 64);
});

test("Gateway identity checks active status and the normalized allow-list", async () => {
  const request = async () => new Response(JSON.stringify({ code: 0, data: { id: 9, email: " OPERATOR@example.invalid ", status: "active" } }));
  const allowed = new OplGatewayIdentityProvider("https://gateway.example.invalid", ["operator@example.invalid"], request);
  const denied = new OplGatewayIdentityProvider("https://gateway.example.invalid", ["other@example.invalid"], request);
  assert.deepEqual(await allowed.authenticate("opaque"), { subject: "9", email: "operator@example.invalid", role: "admin" });
  assert.equal(await denied.authenticate("opaque"), null);
  const inactive = new OplGatewayIdentityProvider("https://gateway.example.invalid", ["operator@example.invalid"], async () => new Response(JSON.stringify({ code: 0, data: { id: 9, email: "operator@example.invalid", status: "disabled" } })));
  assert.equal(await inactive.authenticate("opaque"), null);
});

test("SQLite store preserves catalog and bounded site snapshots", async () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), "netfleet-cloud-test-"));
  const store = new SqliteStore(path.join(directory, "store.sqlite"));
  try {
    await store.change(catalog => { catalog.sites["site-a"] = { id: "site-a", name: "A", owner: "owner", revision: 1, grants: [] }; return { result: true, write: true }; });
    await store.heartbeat("site-a", (catalog, old) => { assert.equal(catalog.sites["site-a"].revision, 1); return { result: true, snapshot: { last_seen_at: new Date().toISOString(), latest: heartbeat, trend: [{ at: new Date().toISOString(), download_bytes: 250 }] } }; });
    assert.equal((await store.snapshots(["site-a"]))[0]?.latest.site_id, "site-a");
    await store.change(catalog => { delete catalog.sites["site-a"]; return { result: true, write: true, removeSnapshot: "site-a" }; });
    assert.equal((await store.snapshots(["site-a"]))[0], null);
  } finally { store.close(); rmSync(directory, { recursive: true, force: true }); }
});

test("Firestore adapter uses one control document and site-scoped snapshots", async () => {
  const db = new FakeFirestore();
  const store = new FirestoreStore(db as never);
  await store.change(catalog => { catalog.sites["site-a"] = { id: "site-a", name: "A", owner: "owner", revision: 2, grants: [] }; return { result: true, write: true }; });
  await store.heartbeat("site-a", (catalog, old) => ({ result: catalog.sites["site-a"].revision, snapshot: { last_seen_at: "2026-01-01T00:00:00.000Z", latest: heartbeat, trend: [] } }));
  assert.equal((await store.snapshots(["site-a", "site-b"]))[0]?.last_seen_at, "2026-01-01T00:00:00.000Z");
  assert.equal((await store.snapshots(["site-a", "site-b"]))[1], null);
  await store.change(catalog => { delete catalog.sites["site-a"]; return { result: true, write: true, removeSnapshot: "site-a" }; });
  assert.deepEqual(await store.catalog(), { sites: {}, subscriptions: {} });
  assert.equal((await store.snapshots(["site-a"]))[0], null);
});

test("heartbeat rejects unlisted and private network fields", async () => {
  const { validHeartbeat } = await import("../src/heartbeat.js");
  assert.equal(validHeartbeat(heartbeat), true);
  for (const payload of [
    { ...heartbeat, client_ip: "192.168.1.2" },
    { ...heartbeat, access_url: "https://router.example.invalid" },
    { ...heartbeat, logs: ["raw"] },
    { ...heartbeat, credentials: { token: "secret" } },
    { ...heartbeat, traffic: { ...heartbeat.traffic, local_ip: "10.0.0.1" } },
  ]) assert.equal(validHeartbeat(payload), false);
});

test("site tokens and grants isolate subscription distribution", async () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), "netfleet-cloud-secrets-"));
  const keyPath = path.join(directory, "master-key");
  const sessionPath = path.join(directory, "session-key");
  const watchdogPath = path.join(directory, "watchdog-key");
  writeFileSync(keyPath, Buffer.alloc(32, 1));
  writeFileSync(sessionPath, Buffer.alloc(32, 2));
  writeFileSync(watchdogPath, Buffer.alloc(32, 3));
  process.env.OPL_NETFLEET_CLOUD_MASTER_KEY_FILE = keyPath;
  process.env.OPL_NETFLEET_CLOUD_SESSION_KEY_FILE = sessionPath;
  process.env.OPL_NETFLEET_CLOUD_WATCHDOG_SECRET_FILE = watchdogPath;
  const store = new MemoryStore();
  const app = new CloudApp(store, admin);
  const auth = new Headers({ authorization: "Bearer approved" });
  try {
    assert.equal((await app.overview(new Headers())).status, 401);
    assert.equal((await app.createSite(auth, { id: "site-a", name: "Site A" })).status, 201);
    assert.equal((await app.createSite(auth, { id: "site-b", name: "Site B" })).status, 201);
    const tokenA = (await app.rotateToken(auth, "site-a")).body.device_token as string;
    const tokenB = (await app.rotateToken(auth, "site-b")).body.device_token as string;
    assert.equal((await app.createSubscription(auth, { id: "provider-a", name: "Provider A", url: "https://provider.example.invalid/a" })).status, 201);
    assert.equal((await app.createSubscription(auth, { id: "provider-b", name: "Provider B", url: "https://provider.example.invalid/b" })).status, 201);
    await app.grants(auth, "site-a", { subscription_ids: ["provider-a"] });
    await app.grants(auth, "site-b", { subscription_ids: ["provider-b"] });
    const deviceA = new Headers({ authorization: `Bearer ${tokenA}` });
    const deviceB = new Headers({ authorization: `Bearer ${tokenB}` });
    assert.equal((await app.heartbeat(deviceA, { ...heartbeat, applied_revision: 1 })).status, 200);
    assert.equal((await app.heartbeat(new Headers({ authorization: "Bearer invalid" }), heartbeat)).status, 401);
    const subscriptionsA = (await app.subscriptions(deviceA)).body as { subscriptions: { id: string; url: string }[] };
    assert.deepEqual(subscriptionsA.subscriptions.map(item => item.id), ["provider-a"]);
    assert.equal(subscriptionsA.subscriptions[0].url, "https://provider.example.invalid/a");
    const subscriptionsB = (await app.subscriptions(deviceB)).body as { subscriptions: { id: string }[] };
    assert.deepEqual(subscriptionsB.subscriptions.map(item => item.id), ["provider-b"]);
    const listed = (await app.listSubscriptions(auth)).body as { subscriptions: Record<string, unknown>[] };
    assert.equal(JSON.stringify(listed).includes("envelope"), false);
    assert.equal(JSON.stringify(listed).includes("https://"), false);
    const watchdog = await app.watchdog(new Headers({ authorization: `Bearer ${Buffer.alloc(32, 3).toString("base64url")}` }));
    assert.equal(watchdog.status, 200);
    assert.deepEqual((watchdog.body as { sites: { site_id: string }[] }).sites.map(site => site.site_id), ["site-b"]);
    assert.equal((await app.watchdog(new Headers({ authorization: "Bearer invalid" }))).status, 401);
    assert.equal((await app.deleteSite(auth, "site-a")).status, 200);
    assert.equal(store.snapshotsValue.has("site-a"), false);
  } finally {
    delete process.env.OPL_NETFLEET_CLOUD_MASTER_KEY_FILE;
    delete process.env.OPL_NETFLEET_CLOUD_SESSION_KEY_FILE;
    delete process.env.OPL_NETFLEET_CLOUD_WATCHDOG_SECRET_FILE;
    rmSync(directory, { recursive: true, force: true });
  }
});
