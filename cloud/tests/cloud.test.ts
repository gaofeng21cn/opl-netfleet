import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { CloudApp } from "../src/app.js";
import type {
  Catalog,
  Change,
  DeviceTokenBinding,
  Identity,
  Snapshot,
  Store,
} from "../src/contracts.js";
import { open, seal, sha256 } from "../src/crypto.js";
import { OplCloudGrantVerifier, type GrantScope } from "../src/grant.js";
import {
  OplCloudIdentityProvider,
  OplGatewayIdentityProvider,
} from "../src/identity.js";
import { FirestoreStore, SqliteStore } from "../src/store.js";

class MemoryStore implements Store {
  tenants = new Map<string, Catalog>();
  snapshotsValue = new Map<string, Snapshot>();
  deviceTokens = new Map<string, DeviceTokenBinding>();

  private catalogFor(ownerId: string): Catalog {
    return this.tenants.get(ownerId) ?? { sites: {}, subscriptions: {} };
  }

  async catalog(ownerId: string) {
    return structuredClone(this.catalogFor(ownerId));
  }

  async change<T>(ownerId: string, fn: (catalog: Catalog) => Change<T>) {
    const catalog = structuredClone(this.catalogFor(ownerId));
    const change = fn(catalog);
    if (change.write) {
      for (const [hash, binding] of this.deviceTokens.entries()) {
        if (binding.owner === ownerId) this.deviceTokens.delete(hash);
      }
      for (const site of Object.values(catalog.sites)) {
        if (site.token_hash) {
          this.deviceTokens.set(site.token_hash, {
            owner: ownerId,
            site_id: site.id,
          });
        }
      }
      if (
        Object.keys(catalog.sites).length ||
        Object.keys(catalog.subscriptions).length
      ) {
        this.tenants.set(ownerId, catalog);
      } else {
        this.tenants.delete(ownerId);
      }
    }
    if (change.removeSnapshot) {
      this.snapshotsValue.delete(`${ownerId}:${change.removeSnapshot}`);
    }
    return change.result;
  }

  async snapshots(ownerId: string, ids: string[]) {
    return ids.map((id) =>
      structuredClone(this.snapshotsValue.get(`${ownerId}:${id}`) ?? null),
    );
  }

  async heartbeat<T>(
    ownerId: string,
    siteId: string,
    fn: (
      catalog: Catalog,
      old: Snapshot | null,
    ) => { result: T; snapshot?: Snapshot },
  ) {
    const key = `${ownerId}:${siteId}`;
    const result = fn(
      structuredClone(this.catalogFor(ownerId)),
      structuredClone(this.snapshotsValue.get(key) ?? null),
    );
    if (result.snapshot) this.snapshotsValue.set(key, result.snapshot);
    return result.result;
  }

  async resolveDeviceToken(tokenHash: string) {
    return structuredClone(this.deviceTokens.get(tokenHash) ?? null);
  }

  async listTenantIds() {
    return [...this.tenants.keys()].sort();
  }
}

class FakeFirestore {
  documents = new Map<string, unknown>();
  doc(path: string) {
    return { path, get: async () => this.row({ path }) };
  }
  async getAll(...refs: { path: string }[]) {
    return refs.map((ref) => this.row(ref));
  }
  row(ref: { path: string }) {
    return { data: () => structuredClone(this.documents.get(ref.path)) };
  }
  async runTransaction<T>(
    callback: (transaction: {
      get: (ref: { path: string }) => Promise<{ data: () => unknown }>;
      getAll: (...refs: { path: string }[]) => Promise<{ data: () => unknown }[]>;
      set: (ref: { path: string }, value: unknown) => void;
      delete: (ref: { path: string }) => void;
    }) => Promise<T>,
  ) {
    let wrote = false;
    const writes: (() => void)[] = [];
    const assertNoWrite = () => {
      if (wrote) throw new Error("firestore_read_after_write");
    };
    const tx = {
      get: async (ref: { path: string }) => {
        assertNoWrite();
        return this.row(ref);
      },
      getAll: async (...refs: { path: string }[]) => {
        assertNoWrite();
        return refs.map((ref) => this.row(ref));
      },
      set: (ref: { path: string }, value: unknown) => {
        wrote = true;
        writes.push(() => this.documents.set(ref.path, structuredClone(value)));
      },
      delete: (ref: { path: string }) => {
        wrote = true;
        writes.push(() => this.documents.delete(ref.path));
      },
    };
    const result = await callback(tx);
    writes.forEach((write) => write());
    return result;
  }
}

function makeEd25519Keypair() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const jwk = publicKey.export({ format: "jwk" }) as {
    kty: string;
    crv: string;
    x: string;
  };
  const pem = publicKey.export({ format: "pem", type: "spki" }).toString();
  return { publicKey, privateKey, jwk, pem };
}

function signGrant(
  privateKey: ReturnType<typeof generateKeyPairSync>["privateKey"],
  claims: Record<string, unknown>,
  header: Record<string, unknown> = {
    alg: "EdDSA",
    typ: "JWT",
    kid: "kid-1",
  },
) {
  const h = Buffer.from(JSON.stringify(header)).toString("base64url");
  const p = Buffer.from(JSON.stringify(claims)).toString("base64url");
  const input = Buffer.from(`${h}.${p}`, "ascii");
  const sig = sign(null, input, privateKey).toString("base64url");
  return `${h}.${p}.${sig}`;
}

const identity: Identity = {
  subject: "43",
  email: "operator@example.invalid",
  role: "admin",
};
const admin = {
  authenticate: async (value: string) =>
    value === "approved" ? identity : null,
};
const heartbeat = {
  site_id: "site-a",
  applied_revision: 0,
  mode: "mihomo",
  capabilities: [
    {
      id: "proxy-main",
      provider: "provider-a",
      node: "node-0123456789ab",
      rtt_ms: 28,
    },
  ],
  traffic: { upload_bps: 100, download_bytes: 250 },
};

test("AES-256-GCM envelopes bind ciphertext to both tenant and object", () => {
  const key = Buffer.alloc(32, 3);
  const envelope = seal(
    "https://provider.example.invalid/sub",
    key,
    "tenant:101:subscription:provider-a",
  );
  assert.equal(
    open(envelope, key, "tenant:101:subscription:provider-a"),
    "https://provider.example.invalid/sub",
  );
  assert.throws(() =>
    open(envelope, key, "tenant:202:subscription:provider-a"),
  );
  assert.throws(() =>
    open(envelope, key, "tenant:101:subscription:provider-b"),
  );
  assert.equal(sha256("token").length, 64);
});

test("Gateway identity checks active status and the normalized allow-list", async () => {
  const request = async () =>
    new Response(
      JSON.stringify({
        code: 0,
        data: { id: 9, email: " OPERATOR@example.invalid ", status: "active" },
      }),
    );
  const allowed = new OplGatewayIdentityProvider(
    "https://gateway.example.invalid",
    ["operator@example.invalid"],
    request,
  );
  const denied = new OplGatewayIdentityProvider(
    "https://gateway.example.invalid",
    ["other@example.invalid"],
    request,
  );
  assert.deepEqual(await allowed.authenticate("opaque"), {
    subject: "9",
    email: "operator@example.invalid",
    role: "admin",
  });
  assert.equal(await denied.authenticate("opaque"), null);
  const inactive = new OplGatewayIdentityProvider(
    "https://gateway.example.invalid",
    ["operator@example.invalid"],
    async () =>
      new Response(
        JSON.stringify({
          code: 0,
          data: { id: 9, email: "operator@example.invalid", status: "disabled" },
        }),
      ),
  );
  assert.equal(await inactive.authenticate("opaque"), null);
});

test("Gateway password login verifies allow-list before login, fetches identity, and logs out upstream refresh session", async () => {
  const calls: string[] = [];
  const provider = new OplGatewayIdentityProvider(
    "https://gateway.example.invalid",
    ["operator@example.invalid"],
    async (input, init) => {
      const url = typeof input === "string" ? input : input.url;
      calls.push(`${init?.method ?? "GET"}:${new URL(url).pathname}`);
      if (url.endsWith("/api/v1/auth/login")) {
        const parsed = JSON.parse(String(init?.body ?? "{}")) as Record<
          string,
          unknown
        >;
        if (
          parsed.email === "operator@example.invalid" &&
          parsed.password === "secret-pass"
        ) {
          return new Response(
            JSON.stringify({
              code: 0,
              data: { access_token: "gw-access", refresh_token: "gw-refresh" },
            }),
          );
        }
        return new Response(JSON.stringify({ code: 401 }), { status: 401 });
      }
      if (url.endsWith("/api/v1/auth/me")) {
        return new Response(
          JSON.stringify({
            code: 0,
            data: {
              id: 9,
              email: "operator@example.invalid",
              status: "active",
              role: "owner",
            },
          }),
        );
      }
      if (url.endsWith("/api/v1/auth/logout")) {
        return new Response(JSON.stringify({ code: 0 }));
      }
      return new Response("not found", { status: 404 });
    },
  );

  assert.equal(
    await provider.authenticatePassword("blocked@example.invalid", "secret-pass"),
    null,
  );
  assert.deepEqual(calls, []);

  assert.equal(
    await provider.authenticatePassword("operator@example.invalid", "wrong"),
    null,
  );
  assert.deepEqual(calls, ["POST:/api/v1/auth/login"]);
  calls.length = 0;

  assert.deepEqual(
    await provider.authenticatePassword(" OPERATOR@example.invalid ", "secret-pass"),
    {
      subject: "9",
      email: "operator@example.invalid",
      role: "owner",
    },
  );
  assert.deepEqual(calls, [
    "POST:/api/v1/auth/login",
    "GET:/api/v1/auth/me",
    "POST:/api/v1/auth/logout",
  ]);
});

test("OplCloudGrantVerifier validates Ed25519 grants, JWKS rotation, and enforces claims", async () => {
  const key1 = makeEd25519Keypair();
  const key2 = makeEd25519Keypair();
  const now = 1_800_000_000;
  const baseClaims = {
    iss: "https://cloud.example.invalid",
    sub: "43",
    email: "Alice@Example.Invalid",
    aud: "opl-netfleet-cloud",
    service: "netfleet_cloud",
    scope: "device:enroll",
    role: "user",
    limits: { max_sites: 5 },
    iat: now,
    exp: now + 120,
    jti: "grant-1",
  };

  let jwksFetchCount = 0;
  let serveSecondKey = false;
  const verifier = new OplCloudGrantVerifier({
    issuer: "https://cloud.example.invalid",
    jwksUrl: "https://cloud.example.invalid/.well-known/opl-grant-jwks.json",
    refreshCooldownMs: 0,
    request: async () => {
      jwksFetchCount += 1;
      const keys = serveSecondKey
        ? [
            { ...key1.jwk, alg: "EdDSA", use: "sig", kid: "kid-1" },
            { ...key2.jwk, alg: "EdDSA", use: "sig", kid: "kid-2" },
          ]
        : [{ ...key1.jwk, alg: "EdDSA", use: "sig", kid: "kid-1" }];
      return new Response(JSON.stringify({ keys }), { status: 200 });
    },
  });

  const validToken = signGrant(key1.privateKey, baseClaims);
  assert.deepEqual(
    await verifier.verify(validToken, "device:enroll", now + 10),
    {
      subject: "43",
      email: "alice@example.invalid",
      role: "user",
      limits: { max_sites: 5 },
    },
  );
  assert.equal(jwksFetchCount, 1);

  // Unknown kid triggers refresh after key rotation
  serveSecondKey = true;
  const rotatedToken = signGrant(key2.privateKey, baseClaims, {
    alg: "EdDSA",
    typ: "JWT",
    kid: "kid-2",
  });
  assert.equal(
    (await verifier.verify(rotatedToken, "device:enroll", now + 10))?.subject,
    "43",
  );
  assert.equal(jwksFetchCount, 2);

  // Reject wrong scope, wrong audience, wrong issuer, expired, oversized ttl, tampered signature, non-numeric sub
  assert.equal(await verifier.verify(validToken, "console:login", now + 10), null);
  assert.equal(
    await verifier.verify(
      signGrant(key1.privateKey, { ...baseClaims, aud: "other" }),
      "device:enroll",
      now + 10,
    ),
    null,
  );
  assert.equal(
    await verifier.verify(
      signGrant(key1.privateKey, { ...baseClaims, iss: "https://evil.invalid" }),
      "device:enroll",
      now + 10,
    ),
    null,
  );
  assert.equal(
    await verifier.verify(validToken, "device:enroll", now + 200),
    null,
  );
  assert.equal(
    await verifier.verify(
      signGrant(key1.privateKey, { ...baseClaims, exp: now + 3600 }),
      "device:enroll",
      now + 10,
    ),
    null,
  );
  assert.equal(
    await verifier.verify(
      signGrant(key1.privateKey, { ...baseClaims, sub: "abc" }),
      "device:enroll",
      now + 10,
    ),
    null,
  );
  const tampered = validToken.slice(0, -4) + "AAAA";
  assert.equal(await verifier.verify(tampered, "device:enroll", now + 10), null);

  // Also test static PEM verifier
  const pemVerifier = new OplCloudGrantVerifier({
    issuer: "https://cloud.example.invalid",
    publicKeyRaw: key1.pem,
  });
  assert.equal(
    (await pemVerifier.verify(validToken, "device:enroll", now + 10))?.subject,
    "43",
  );
});

test("OplCloudIdentityProvider handles requires_2fa, service_not_entitled, rate_limited, and verifies returned grants", async () => {
  const keypair = makeEd25519Keypair();
  const nowSec = Math.floor(Date.now() / 1000);
  const verifier = new OplCloudGrantVerifier({
    issuer: "https://cloud.example.invalid",
    publicKeyRaw: JSON.stringify({
      keys: [{ ...keypair.jwk, alg: "EdDSA", use: "sig", kid: "kid-1" }],
    }),
  });
  const provider = new OplCloudIdentityProvider({
    cloudOrigin: "https://cloud.example.invalid",
    verifier,
    request: async (_url, init) => {
      const body = JSON.parse(String(init?.body ?? "{}")) as Record<
        string,
        unknown
      >;
      assert.equal(body.service, "netfleet_cloud");
      assert.equal(body.scope, "console:login");
      if (body.email === "2fa@example.invalid" && !body.totp_code) {
        return new Response(JSON.stringify({ requires_2fa: true }), {
          status: 200,
        });
      }
      if (body.email === "denied@example.invalid") {
        return new Response(
          JSON.stringify({ code: "service_not_entitled" }),
          { status: 403 },
        );
      }
      if (body.email === "busy@example.invalid") {
        return new Response(JSON.stringify({ code: "rate_limited" }), {
          status: 429,
        });
      }
      if (body.email === "2fa@example.invalid" && body.totp_code === "123456") {
        const grant = signGrant(keypair.privateKey, {
          iss: "https://cloud.example.invalid",
          sub: "88",
          email: "2fa@example.invalid",
          aud: "opl-netfleet-cloud",
          service: "netfleet_cloud",
          scope: "console:login",
          role: "user",
          limits: { max_sites: 4 },
          iat: nowSec,
          exp: nowSec + 120,
          jti: "login-grant-1",
        });
        return new Response(
          JSON.stringify({
            enabled: true,
            origin: "https://netfleet.example.invalid",
            grant_token: grant,
          }),
          { status: 200 },
        );
      }
      return new Response(JSON.stringify({ code: "unauthorized" }), {
        status: 401,
      });
    },
  });

  assert.deepEqual(
    await provider.authenticatePasswordDetailed("2fa@example.invalid", "pw"),
    { status: "requires_2fa" },
  );
  assert.deepEqual(
    await provider.authenticatePasswordDetailed("denied@example.invalid", "pw"),
    { status: "not_entitled" },
  );
  assert.deepEqual(
    await provider.authenticatePasswordDetailed("busy@example.invalid", "pw"),
    { status: "rate_limited" },
  );
  assert.deepEqual(
    await provider.authenticatePasswordDetailed(
      "2fa@example.invalid",
      "pw",
      "123456",
    ),
    {
      status: "ok",
      identity: {
        subject: "88",
        email: "2fa@example.invalid",
        role: "user",
        limits: { max_sites: 4 },
      },
    },
  );
});

test("CloudApp password login issues session cookie and surfaces 2FA and service_not_entitled", async () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), "netfleet-cloud-auth-"));
  const sessionPath = path.join(directory, "session-key");
  writeFileSync(sessionPath, Buffer.alloc(32, 4));
  process.env.OPL_NETFLEET_CLOUD_SESSION_KEY_FILE = sessionPath;
  const app = new CloudApp(new MemoryStore(), {
    mode: "cloud",
    authenticate: async () => null,
    authenticatePasswordDetailed: async (email, password, totpCode) => {
      if (email === "denied@example.invalid") return { status: "not_entitled" };
      if (email === "operator@example.invalid" && password === "demo-pass") {
        if (!totpCode) return { status: "requires_2fa" };
        if (totpCode === "654321") {
          return {
            status: "ok",
            identity: { subject: "43", email, role: "user" },
          };
        }
      }
      return { status: "unauthorized" };
    },
  });
  try {
    const bad = await app.login({
      email: "operator@example.invalid",
      password: "bad",
    });
    assert.equal(bad.status, 401);
    assert.equal(bad.session, undefined);

    const notEntitled = await app.login({
      email: "denied@example.invalid",
      password: "demo-pass",
    });
    assert.equal(notEntitled.status, 403);
    assert.deepEqual(notEntitled.body, { error: "service_not_entitled" });

    const twoFa = await app.login({
      email: "operator@example.invalid",
      password: "demo-pass",
    });
    assert.equal(twoFa.status, 200);
    assert.deepEqual(twoFa.body, { ok: false, requires_2fa: true });
    assert.equal(twoFa.session, undefined);

    const login = await app.login({
      email: "operator@example.invalid",
      password: "demo-pass",
      totp_code: "654321",
    });
    assert.equal(login.status, 200);
    assert.deepEqual(login.body.user, {
      email: "operator@example.invalid",
      role: "user",
    });
    assert.ok(login.session);
    const cookieHeader = new Headers({
      cookie: `opl_netfleet_session=${login.session}`,
    });
    assert.deepEqual(await app.me(cookieHeader), {
      status: 200,
      body: { email: "operator@example.invalid", role: "user" },
    });
    assert.equal((await app.overview(cookieHeader)).status, 200);
  } finally {
    delete process.env.OPL_NETFLEET_CLOUD_SESSION_KEY_FILE;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("multi-tenant isolation isolates colliding site_id, subscriptions, device tokens, and enforces max_sites", async () => {
  const store = new MemoryStore();
  const keypair = makeEd25519Keypair();
  const verifier = new OplCloudGrantVerifier({
    issuer: "https://cloud.example.invalid",
    publicKeyRaw: keypair.pem,
  });
  const provider = new OplCloudIdentityProvider({
    cloudOrigin: "https://cloud.example.invalid",
    verifier,
  });
  const app = new CloudApp(store, provider);
  const directory = mkdtempSync(path.join(os.tmpdir(), "netfleet-mt-"));
  const masterPath = path.join(directory, "master");
  const sessionPath = path.join(directory, "session");
  writeFileSync(masterPath, Buffer.alloc(32, 5));
  writeFileSync(sessionPath, Buffer.alloc(32, 6));
  process.env.OPL_NETFLEET_CLOUD_MASTER_KEY_FILE = masterPath;
  process.env.OPL_NETFLEET_CLOUD_SESSION_KEY_FILE = sessionPath;

  const nowSec = Math.floor(Date.now() / 1000);
  const grantFor = (
    sub: string,
    email: string,
    scope: GrantScope,
    maxSites?: number,
  ) =>
    signGrant(keypair.privateKey, {
      iss: "https://cloud.example.invalid",
      sub,
      email,
      aud: "opl-netfleet-cloud",
      service: "netfleet_cloud",
      scope,
      role: "user",
      ...(maxSites ? { limits: { max_sites: maxSites } } : {}),
      iat: nowSec,
      exp: nowSec + 120,
      jti: `jti-${sub}-${scope}`,
    });

  try {
    const enroll101 = grantFor("101", "a@example.invalid", "device:enroll", 2);
    const login101 = grantFor("101", "a@example.invalid", "console:login", 2);
    const enroll202 = grantFor("202", "b@example.invalid", "device:enroll", 2);
    const login202 = grantFor("202", "b@example.invalid", "console:login", 2);

    // Wrong scope rejected
    assert.equal(
      (
        await app.enroll(
          new Headers({ authorization: `Bearer ${login101}` }),
          { name: "Home", device_id: "device-101-alpha" },
        )
      ).status,
      401,
    );
    assert.equal(
      (await app.login({ grant_token: enroll101 })).status,
      401,
    );

    // Cloud mode refuses password in /agent/enroll
    assert.equal(
      (
        await app.enroll(new Headers(), {
          email: "a@example.invalid",
          password: "secret",
        })
      ).status,
      401,
    );

    // Both tenant 101 and tenant 202 can enroll with identical colliding site_id="home"
    const res101 = await app.enroll(
      new Headers({ authorization: `Bearer ${enroll101}` }),
      { site_id: "home", name: "Alice Home", device_id: "device-101-alpha" },
    );
    assert.equal(res101.status, 200);
    const tok101 = (res101.body as { device_token: string }).device_token;

    const res202 = await app.enroll(
      new Headers({ authorization: `Bearer ${enroll202}` }),
      { site_id: "home", name: "Bob Home", device_id: "device-202-alpha" },
    );
    assert.equal(res202.status, 200);
    const tok202 = (res202.body as { device_token: string }).device_token;

    // Both tenants create subscription with colliding id="main-sub" & different secret URLs
    const auth101 = new Headers({ authorization: `Bearer ${login101}` });
    const auth202 = new Headers({ authorization: `Bearer ${login202}` });
    assert.equal(
      (
        await app.createSubscription(auth101, {
          id: "main-sub",
          name: "Alice Sub",
          url: "https://alice.example.invalid/sub",
        })
      ).status,
      201,
    );
    assert.equal(
      (
        await app.createSubscription(auth202, {
          id: "main-sub",
          name: "Bob Sub",
          url: "https://bob.example.invalid/sub",
        })
      ).status,
      201,
    );
    await app.grants(auth101, "home", { subscription_ids: ["main-sub"] });
    await app.grants(auth202, "home", { subscription_ids: ["main-sub"] });

    // Device pull isolates URLs per tenant
    const pull101 = (
      await app.subscriptions(
        new Headers({ authorization: `Bearer ${tok101}` }),
      )
    ).body as { subscriptions: { id: string; url: string }[] };
    assert.equal(pull101.subscriptions[0].url, "https://alice.example.invalid/sub");

    const pull202 = (
      await app.subscriptions(
        new Headers({ authorization: `Bearer ${tok202}` }),
      )
    ).body as { subscriptions: { id: string; url: string }[] };
    assert.equal(pull202.subscriptions[0].url, "https://bob.example.invalid/sub");

    // Cross-tenant overview isolation
    const overview101 = (await app.overview(auth101)).body as {
      sites: { name: string }[];
    };
    assert.deepEqual(
      overview101.sites.map((s) => s.name),
      ["Alice Home"],
    );

    // Tenant 101 has max_sites=2 -> second site succeeds, third hits 409 site_limit
    assert.equal(
      (await app.createSite(auth101, { id: "lab", name: "Alice Lab" })).status,
      201,
    );
    const thirdSite = await app.enroll(
      new Headers({ authorization: `Bearer ${enroll101}` }),
      { name: "Alice Third", device_id: "device-101-third" },
    );
    assert.equal(thirdSite.status, 409);
    assert.deepEqual(thirdSite.body, { error: "site_limit" });
  } finally {
    delete process.env.OPL_NETFLEET_CLOUD_MASTER_KEY_FILE;
    delete process.env.OPL_NETFLEET_CLOUD_SESSION_KEY_FILE;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("self-hosted auto-enrollment creates, idempotently re-pairs by device_id, renames, and unenrolls sites", async () => {
  const store = new MemoryStore();
  const provider = {
    mode: "self-hosted" as const,
    authenticate: async () => null,
    authenticatePassword: async (email: string, password: string) => {
      if (password !== "gw-pass") return null;
      const actor = email.startsWith("owner@") ? "1001" : "1002";
      return { subject: actor, email, role: "owner" as const };
    },
  };
  const app = new CloudApp(store, provider);
  const directory = mkdtempSync(path.join(os.tmpdir(), "netfleet-enroll-"));
  const masterPath = path.join(directory, "master");
  const sessionPath = path.join(directory, "session");
  writeFileSync(masterPath, Buffer.alloc(32, 5));
  writeFileSync(sessionPath, Buffer.alloc(32, 6));
  process.env.OPL_NETFLEET_CLOUD_MASTER_KEY_FILE = masterPath;
  process.env.OPL_NETFLEET_CLOUD_SESSION_KEY_FILE = sessionPath;

  try {
    assert.equal(
      (
        await app.enroll(new Headers(), {
          email: "owner@example.invalid",
          password: "wrong",
          name: "Home Router",
        })
      ).status,
      401,
    );

    const created = await app.enroll(new Headers(), {
      email: "owner@example.invalid",
      password: "gw-pass",
      name: "家用主路由",
      device_id: "router-device-00112233",
    });
    assert.equal(created.status, 200);
    const createdBody = created.body as {
      ok: boolean;
      site_id: string;
      name: string;
      revision: number;
      device_token: string;
      enrolled: string;
    };
    assert.equal(createdBody.ok, true);
    assert.equal(createdBody.enrolled, "created");
    assert.match(createdBody.site_id, /^site-[a-f0-9]{8}$/);
    assert.equal(createdBody.name, "家用主路由");
    assert.match(createdBody.device_token, /^[A-Za-z0-9_-]{43}$/);

    const login = await app.login({
      email: "owner@example.invalid",
      password: "gw-pass",
    });
    assert.equal(login.status, 200);
    const ownerCookie = new Headers({
      cookie: `opl_netfleet_session=${login.session}`,
    });

    assert.equal(
      (
        await app.createSubscription(ownerCookie, {
          id: "sub-alpha",
          name: "Sub Alpha",
          url: "https://sub.example.invalid/alpha",
        })
      ).status,
      201,
    );
    assert.equal(
      (
        await app.grants(ownerCookie, createdBody.site_id, {
          subscription_ids: ["sub-alpha"],
        })
      ).status,
      200,
    );

    const repaired = await app.enroll(new Headers(), {
      email: "owner@example.invalid",
      password: "gw-pass",
      name: "Home Router Pro",
      device_id: "router-device-00112233",
    });
    assert.equal(repaired.status, 200);
    const repairedBody = repaired.body as typeof createdBody;
    assert.equal(repairedBody.enrolled, "repaired");
    assert.equal(repairedBody.site_id, createdBody.site_id);
    assert.equal(repairedBody.revision, 1);
    assert.notEqual(repairedBody.device_token, createdBody.device_token);

    assert.equal(
      (
        await app.subscriptions(
          new Headers({ authorization: `Bearer ${createdBody.device_token}` }),
        )
      ).status,
      401,
    );
    const newDeviceAuth = new Headers({
      authorization: `Bearer ${repairedBody.device_token}`,
    });
    assert.equal((await app.subscriptions(newDeviceAuth)).status, 200);
    assert.equal(
      (
        await app.heartbeat(newDeviceAuth, {
          site_id: createdBody.site_id,
          applied_revision: 1,
          mode: "netfleet",
          capabilities: [],
          traffic: { upload_bytes: 100, download_bytes: 200 },
        })
      ).status,
      200,
    );

    assert.equal(
      (
        await app.renameSite(ownerCookie, createdBody.site_id, {
          name: "Gateway Alpha Edge",
        })
      ).status,
      200,
    );
    const overview = (await app.overview(ownerCookie)).body as {
      sites: { id: string; name: string }[];
    };
    assert.equal(
      overview.sites.find((s) => s.id === createdBody.site_id)?.name,
      "Gateway Alpha Edge",
    );

    // Unenroll revokes token immediately
    assert.equal((await app.unenroll(newDeviceAuth)).status, 200);
    assert.equal((await app.subscriptions(newDeviceAuth)).status, 401);
  } finally {
    delete process.env.OPL_NETFLEET_CLOUD_MASTER_KEY_FILE;
    delete process.env.OPL_NETFLEET_CLOUD_SESSION_KEY_FILE;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("SQLite store preserves multi-tenant catalogs, token index, and snapshots", async () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), "netfleet-cloud-test-"));
  const store = new SqliteStore(path.join(directory, "store.sqlite"));
  try {
    await store.change("101", (catalog) => {
      catalog.sites["home"] = {
        id: "home",
        name: "A",
        owner: "101",
        revision: 1,
        grants: [],
        token_hash: sha256("token-101"),
      };
      return { result: true, write: true };
    });
    await store.change("202", (catalog) => {
      catalog.sites["home"] = {
        id: "home",
        name: "B",
        owner: "202",
        revision: 3,
        grants: [],
        token_hash: sha256("token-202"),
      };
      return { result: true, write: true };
    });
    assert.deepEqual(await store.listTenantIds(), ["101", "202"]);
    assert.deepEqual(await store.resolveDeviceToken(sha256("token-101")), {
      owner: "101",
      site_id: "home",
    });
    assert.deepEqual(await store.resolveDeviceToken(sha256("token-202")), {
      owner: "202",
      site_id: "home",
    });

    await store.heartbeat("101", "home", (catalog) => {
      assert.equal(catalog.sites["home"].revision, 1);
      return {
        result: true,
        snapshot: {
          last_seen_at: new Date().toISOString(),
          latest: { ...heartbeat, site_id: "home" },
          trend: [{ at: new Date().toISOString(), download_bytes: 250 }],
        },
      };
    });
    assert.equal(
      (await store.snapshots("101", ["home"]))[0]?.latest.site_id,
      "home",
    );
    assert.equal((await store.snapshots("202", ["home"]))[0], null);

    await store.change("101", (catalog) => {
      delete catalog.sites["home"];
      return { result: true, write: true, removeSnapshot: "home" };
    });
    assert.equal((await store.snapshots("101", ["home"]))[0], null);
    assert.equal(await store.resolveDeviceToken(sha256("token-101")), null);
    assert.deepEqual(await store.listTenantIds(), ["202"]);
  } finally {
    store.close();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Firestore adapter uses tenant-prefixed documents, read-before-write transactions, and snapshots", async () => {
  const db = new FakeFirestore();
  const store = new FirestoreStore(db as never);
  await store.change("101", (catalog) => {
    catalog.sites["site-a"] = {
      id: "site-a",
      name: "A",
      owner: "101",
      revision: 2,
      grants: [],
      token_hash: sha256("tok-fs-101"),
    };
    return { result: true, write: true };
  });
  assert.ok(db.documents.has("tenants/101/sites/site-a"));
  assert.deepEqual(await store.resolveDeviceToken(sha256("tok-fs-101")), {
    owner: "101",
    site_id: "site-a",
  });
  assert.deepEqual(await store.listTenantIds(), ["101"]);

  await store.heartbeat("101", "site-a", (catalog) => ({
    result: catalog.sites["site-a"].revision,
    snapshot: {
      last_seen_at: "2026-01-01T00:00:00.000Z",
      latest: heartbeat,
      trend: [],
    },
  }));
  assert.equal(
    (await store.snapshots("101", ["site-a", "site-b"]))[0]?.last_seen_at,
    "2026-01-01T00:00:00.000Z",
  );
  assert.equal((await store.snapshots("101", ["site-a", "site-b"]))[1], null);

  await store.change("101", (catalog) => {
    delete catalog.sites["site-a"];
    return { result: true, write: true, removeSnapshot: "site-a" };
  });
  assert.deepEqual(await store.catalog("101"), {
    sites: {},
    subscriptions: {},
  });
  assert.equal((await store.snapshots("101", ["site-a"]))[0], null);
  assert.equal(await store.resolveDeviceToken(sha256("tok-fs-101")), null);
  assert.deepEqual(await store.listTenantIds(), []);
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
  ])
    assert.equal(validHeartbeat(payload), false);
});

test("site tokens, grants, and watchdog isolate subscription distribution and multi-tenant alerts", async () => {
  const directory = mkdtempSync(
    path.join(os.tmpdir(), "netfleet-cloud-secrets-"),
  );
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
    assert.equal(
      (await app.createSite(auth, { id: "site-a", name: "Site A" })).status,
      201,
    );
    assert.equal(
      (await app.createSite(auth, { id: "site-b", name: "Site B" })).status,
      201,
    );
    const tokenA = (await app.rotateToken(auth, "site-a")).body
      .device_token as string;
    const tokenB = (await app.rotateToken(auth, "site-b")).body
      .device_token as string;
    assert.equal(
      (
        await app.createSubscription(auth, {
          id: "provider-a",
          name: "Provider A",
          url: "https://provider.example.invalid/a",
        })
      ).status,
      201,
    );
    assert.equal(
      (
        await app.createSubscription(auth, {
          id: "provider-b",
          name: "Provider B",
          url: "https://provider.example.invalid/b",
        })
      ).status,
      201,
    );
    await app.grants(auth, "site-a", { subscription_ids: ["provider-a"] });
    await app.grants(auth, "site-b", { subscription_ids: ["provider-b"] });
    const deviceA = new Headers({ authorization: `Bearer ${tokenA}` });
    const deviceB = new Headers({ authorization: `Bearer ${tokenB}` });
    assert.equal(
      (await app.heartbeat(deviceA, { ...heartbeat, applied_revision: 1 }))
        .status,
      200,
    );
    assert.equal(
      (
        await app.heartbeat(
          new Headers({ authorization: "Bearer invalid" }),
          heartbeat,
        )
      ).status,
      401,
    );
    const subscriptionsA = (await app.subscriptions(deviceA)).body as {
      subscriptions: { id: string; url: string }[];
    };
    assert.deepEqual(
      subscriptionsA.subscriptions.map((item) => item.id),
      ["provider-a"],
    );
    assert.equal(
      subscriptionsA.subscriptions[0].url,
      "https://provider.example.invalid/a",
    );
    const subscriptionsB = (await app.subscriptions(deviceB)).body as {
      subscriptions: { id: string }[];
    };
    assert.deepEqual(
      subscriptionsB.subscriptions.map((item) => item.id),
      ["provider-b"],
    );
    const listed = (await app.listSubscriptions(auth)).body as {
      subscriptions: Record<string, unknown>[];
    };
    assert.equal(JSON.stringify(listed).includes("envelope"), false);
    assert.equal(JSON.stringify(listed).includes("https://"), false);
    const watchdog = await app.watchdog(
      new Headers({
        authorization: `Bearer ${Buffer.alloc(32, 3).toString("base64url")}`,
      }),
    );
    assert.equal(watchdog.status, 200);
    assert.deepEqual(
      (watchdog.body as {
        sites: { owner_actor_id: string; site_id: string }[];
      }).sites.map((site) => `${site.owner_actor_id}:${site.site_id}`),
      ["43:site-b"],
    );
    assert.equal(
      (
        await app.watchdog(new Headers({ authorization: "Bearer invalid" }))
      ).status,
      401,
    );
    assert.equal((await app.deleteSite(auth, "site-a")).status, 200);
    assert.equal(store.snapshotsValue.has("43:site-a"), false);
  } finally {
    delete process.env.OPL_NETFLEET_CLOUD_MASTER_KEY_FILE;
    delete process.env.OPL_NETFLEET_CLOUD_SESSION_KEY_FILE;
    delete process.env.OPL_NETFLEET_CLOUD_WATCHDOG_SECRET_FILE;
    rmSync(directory, { recursive: true, force: true });
  }
});
