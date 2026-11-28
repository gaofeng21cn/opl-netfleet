import { createHmac, timingSafeEqual } from "node:crypto";
import type { Identity, Site, Store, Subscription } from "./contracts.js";
import {
  createIdentityProviderFromEnv,
  type AuthOutcome,
  type IdentityProvider,
} from "./identity.js";
import { open, randomToken, readKey, seal, sha256 } from "./crypto.js";
import {
  only,
  record,
  siteId,
  sourceId,
  snapshot,
  validHeartbeat,
} from "./heartbeat.js";

const bearerToken = (value: string | null) =>
  value?.match(/^Bearer ([^\s,]+)$/i)?.[1];
const validName = (value: unknown): value is string =>
  typeof value === "string" &&
  !!value.trim() &&
  value.length <= 120 &&
  !/[\x00-\x1f\x7f]/.test(value);
const validDeviceId = (value: unknown): value is string =>
  typeof value === "string" && /^[A-Za-z0-9_-]{8,64}$/.test(value);
const timeout = Number(
  process.env.OPL_NETFLEET_CLOUD_HEARTBEAT_TIMEOUT_MS ?? 180000,
);
const DEFAULT_MAX_SITES = 64;

function deriveSiteId(
  name: string,
  deviceId: string | undefined,
  sites: Record<string, { id: string }>,
): string {
  let base = name
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 36)
    .replace(/-+$/, "");
  if (!/^[a-z][a-z0-9-]{1,35}$/.test(base)) {
    const seed = deviceId
      ? sha256(deviceId).slice(0, 8)
      : sha256(randomToken()).slice(0, 8);
    base = `site-${seed}`;
  }
  if (!Object.hasOwn(sites, base)) return base;
  for (let i = 1; i <= 64; i += 1) {
    const candidate = `${base.slice(0, 40)}-${i}`;
    if (!Object.hasOwn(sites, candidate)) return candidate;
  }
  return `site-${sha256(randomToken()).slice(0, 10)}`;
}

function validSourceUrl(value: string) {
  if (
    value.length > 2048 ||
    /[\s\x00-\x1f]/.test(value) ||
    !value.startsWith("https://")
  )
    return false;
  try {
    const url = new URL(value);
    return !!url.hostname && !url.username && !url.password && !url.hash;
  } catch {
    return false;
  }
}

const unauthorized = { status: 401, body: { error: "unauthorized" } };

const asObject = (value: unknown): Record<string, unknown> | null =>
  record(value) ? value : null;

export class CloudApp {
  constructor(
    private readonly store: Store,
    private readonly identity: IdentityProvider = createIdentityProviderFromEnv(),
  ) {}

  private owner(identity: Identity) {
    if (!/^[A-Za-z0-9_-]{1,100}$/.test(identity.subject)) {
      throw new Error("invalid_identity_subject");
    }
    return identity.subject;
  }

  private maxSitesFor(identity: Identity) {
    const raw = identity.limits?.max_sites;
    if (typeof raw !== "number" || !Number.isFinite(raw)) {
      return DEFAULT_MAX_SITES;
    }
    return Math.min(DEFAULT_MAX_SITES, Math.max(1, Math.trunc(raw)));
  }

  private subscriptionAad(ownerId: string, id: string) {
    return `tenant:${ownerId}:subscription:${id}`;
  }

  private sessionKey() {
    return readKey(process.env.OPL_NETFLEET_CLOUD_SESSION_KEY_FILE);
  }

  session(identity: Identity) {
    const payload = Buffer.from(
      JSON.stringify({ identity, exp: Date.now() + 3600000 }),
    ).toString("base64url");
    const mac = createHmac("sha256", this.sessionKey())
      .update(payload)
      .digest("base64url");
    return `${payload}.${mac}`;
  }

  async human(headers: Headers) {
    const authorization = headers.get("authorization");
    const bearer = bearerToken(authorization);
    if (authorization && !bearer) return null;
    if (bearer) {
      const identity = await this.identity.authenticate(bearer);
      return identity ? { identity, owner: this.owner(identity) } : null;
    }
    const cookie = headers
      .get("cookie")
      ?.split(";")
      .map((value) => value.trim())
      .find((value) => value.startsWith("opl_netfleet_session="))
      ?.split("=")[1];
    if (!cookie) return null;
    try {
      const [payload, mac] = cookie.split(".");
      const expected = createHmac("sha256", this.sessionKey())
        .update(payload)
        .digest();
      const actual = Buffer.from(mac, "base64url");
      if (
        actual.length !== expected.length ||
        !timingSafeEqual(actual, expected)
      )
        return null;
      const session = JSON.parse(
        Buffer.from(payload, "base64url").toString(),
      ) as { identity: Identity; exp: number };
      return session.exp > Date.now()
        ? { identity: session.identity, owner: this.owner(session.identity) }
        : null;
    } catch {
      return null;
    }
  }

  async device(
    headers: Headers,
  ): Promise<{ owner: string; site: Site } | null> {
    const token = bearerToken(headers.get("authorization"));
    if (!token || !/^[A-Za-z0-9_-]{43}$/.test(token)) return null;
    const tokenHash = sha256(token);
    const binding = await this.store.resolveDeviceToken(tokenHash);
    if (!binding) return null;
    const catalog = await this.store.catalog(binding.owner);
    const site = catalog.sites[binding.site_id];
    if (!site || site.owner !== binding.owner || site.token_hash !== tokenHash) {
      return null;
    }
    return { owner: binding.owner, site };
  }

  private loginResponse(outcome: AuthOutcome): {
    status: number;
    body: Record<string, unknown>;
    session?: string;
  } {
    switch (outcome.status) {
      case "ok":
        return {
          status: 200,
          body: {
            ok: true,
            user: {
              email: outcome.identity.email,
              role: outcome.identity.role,
            },
          },
          session: this.session(outcome.identity),
        };
      case "requires_2fa":
        return {
          status: 200,
          body: { ok: false, requires_2fa: true },
        };
      case "not_entitled":
        return { status: 403, body: { error: "service_not_entitled" } };
      case "rate_limited":
        return { status: 429, body: { error: "rate_limited" } };
      case "unavailable":
        return { status: 503, body: { error: "service_unavailable" } };
      default:
        return unauthorized;
    }
  }

  async login(body: unknown): Promise<{
    status: number;
    body: Record<string, unknown>;
    session?: string;
  }> {
    const input = asObject(body);
    if (!input) return unauthorized;

    if ("email" in input || "password" in input || "totp_code" in input) {
      if (
        !only(input, ["email", "password", "totp_code"]) ||
        typeof input.email !== "string" ||
        typeof input.password !== "string" ||
        !input.email.trim() ||
        input.email.length > 254 ||
        !input.password ||
        input.password.length > 512 ||
        (input.totp_code !== undefined &&
          (typeof input.totp_code !== "string" ||
            input.totp_code.trim().length > 16))
      ) {
        return unauthorized;
      }
      const totp =
        typeof input.totp_code === "string" && input.totp_code.trim()
          ? input.totp_code.trim()
          : undefined;
      if (this.identity.authenticatePasswordDetailed) {
        return this.loginResponse(
          await this.identity.authenticatePasswordDetailed(
            input.email,
            input.password,
            totp,
          ),
        );
      }
      if (this.identity.authenticatePassword) {
        const identity = await this.identity.authenticatePassword(
          input.email,
          input.password,
          totp,
        );
        return this.loginResponse(
          identity ? { status: "ok", identity } : { status: "unauthorized" },
        );
      }
      return unauthorized;
    }

    if (only(input, ["grant_token"]) && typeof input.grant_token === "string") {
      const identity = this.identity.verifyGrant
        ? await this.identity.verifyGrant(input.grant_token, "console:login")
        : null;
      return this.loginResponse(
        identity ? { status: "ok", identity } : { status: "unauthorized" },
      );
    }

    if (
      only(input, ["token"]) &&
      typeof input.token === "string" &&
      input.token.length > 0 &&
      input.token.length <= 4096
    ) {
      if (this.identity.authenticateBearerDetailed) {
        return this.loginResponse(
          await this.identity.authenticateBearerDetailed(input.token),
        );
      }
      const identity = await this.identity.authenticate(input.token);
      return this.loginResponse(
        identity ? { status: "ok", identity } : { status: "unauthorized" },
      );
    }

    return unauthorized;
  }

  async me(headers: Headers) {
    const auth = await this.human(headers);
    return auth
      ? {
          status: 200,
          body: { email: auth.identity.email, role: auth.identity.role },
        }
      : unauthorized;
  }

  async enroll(headers: Headers, body: unknown) {
    const input = asObject(body);
    if (!input) {
      return { status: 400, body: { error: "invalid_enroll_request" } };
    }

    const authorization = headers.get("authorization");
    let identity: Identity | null = null;
    if (authorization !== null) {
      const grantToken = bearerToken(authorization);
      if (!grantToken) return unauthorized;
      if (!only(input, ["name", "site_id", "device_id"])) {
        return { status: 400, body: { error: "invalid_enroll_request" } };
      }
      identity = this.identity.verifyGrant
        ? await this.identity.verifyGrant(grantToken, "device:enroll")
        : null;
      if (!identity) return unauthorized;
    } else {
      if (
        !only(input, ["email", "password", "name", "site_id", "device_id"]) ||
        typeof input.email !== "string" ||
        !input.email.trim() ||
        input.email.length > 254 ||
        typeof input.password !== "string" ||
        !input.password ||
        input.password.length > 512
      ) {
        return { status: 400, body: { error: "invalid_enroll_request" } };
      }
      if (
        this.identity.mode === "cloud" ||
        !this.identity.authenticatePassword
      ) {
        return unauthorized;
      }
      identity = await this.identity.authenticatePassword(
        input.email,
        input.password,
      );
      if (!identity) return unauthorized;
    }

    const hasName = input.name !== undefined && input.name !== "";
    if (hasName && !validName(input.name)) {
      return { status: 400, body: { error: "invalid_site" } };
    }
    const requestedSiteId =
      input.site_id === undefined || input.site_id === ""
        ? undefined
        : input.site_id;
    if (requestedSiteId !== undefined && !siteId(requestedSiteId)) {
      return { status: 400, body: { error: "invalid_site" } };
    }
    const deviceId =
      input.device_id === undefined || input.device_id === ""
        ? undefined
        : input.device_id;
    if (deviceId !== undefined && !validDeviceId(deviceId)) {
      return { status: 400, body: { error: "invalid_device_id" } };
    }

    const owner = this.owner(identity);
    const maxSites = this.maxSitesFor(identity);
    const plain = randomToken();
    const tokenHash = sha256(plain);
    const customName = hasName ? (input.name as string).trim() : undefined;
    try {
      const enrolled = await this.store.change(owner, (catalog) => {
        const byDevice = deviceId
          ? Object.values(catalog.sites).find(
              (site) => site.owner === owner && site.device_id === deviceId,
            )
          : undefined;
        let existing = byDevice;
        if (!existing && requestedSiteId) {
          if (Object.hasOwn(catalog.sites, requestedSiteId)) {
            const candidate = catalog.sites[requestedSiteId];
            if (candidate.owner !== owner) throw new Error("site_exists");
            existing = candidate;
          }
        }
        if (existing) {
          existing.token_hash = tokenHash;
          if (customName) existing.name = customName;
          if (deviceId) existing.device_id = deviceId;
          return {
            result: {
              ok: true,
              site_id: existing.id,
              name: existing.name,
              revision: existing.revision,
              device_token: plain,
              enrolled: "repaired",
            },
            write: true,
          };
        }
        if (Object.keys(catalog.sites).length >= maxSites) {
          throw new Error("site_limit");
        }
        const displayName = customName || requestedSiteId || "Managed Gateway";
        const id =
          requestedSiteId ?? deriveSiteId(displayName, deviceId, catalog.sites);
        catalog.sites[id] = {
          id,
          name: displayName,
          owner,
          revision: 0,
          grants: [],
          token_hash: tokenHash,
          ...(deviceId ? { device_id: deviceId } : {}),
        };
        return {
          result: {
            ok: true,
            site_id: id,
            name: displayName,
            revision: 0,
            device_token: plain,
            enrolled: "created",
          },
          write: true,
        };
      });
      return { status: 200, body: enrolled };
    } catch (error) {
      if (
        !(error instanceof Error) ||
        !["site_exists", "site_limit"].includes(error.message)
      )
        throw error;
      return { status: 409, body: { error: error.message } };
    }
  }

  async unenroll(headers: Headers) {
    const auth = await this.device(headers);
    if (!auth) return unauthorized;
    const removed = await this.store.change(auth.owner, (catalog) => {
      const current = catalog.sites[auth.site.id];
      if (!current || current.token_hash !== auth.site.token_hash) {
        return { result: false };
      }
      delete current.token_hash;
      return { result: true, write: true };
    });
    return removed
      ? { status: 200, body: { ok: true, site_id: auth.site.id } }
      : unauthorized;
  }

  async heartbeat(headers: Headers, body: unknown) {
    const auth = await this.device(headers);
    if (!auth) return unauthorized;
    if (!validHeartbeat(body) || body.site_id !== auth.site.id)
      return { status: 400, body: { error: "invalid_heartbeat" } };
    const result = await this.store.heartbeat(
      auth.owner,
      auth.site.id,
      (catalog, old) => {
        const current = catalog.sites[auth.site.id];
        if (!current || current.token_hash !== auth.site.token_hash)
          return { result: null };
        const now = Date.now();
        return {
          result: {
            ok: true,
            desired_revision: current.revision,
            server_time: new Date(now).toISOString(),
          },
          snapshot: snapshot(old, body, now),
        };
      },
    );
    return result ? { status: 200, body: result } : unauthorized;
  }

  async subscriptions(headers: Headers) {
    const auth = await this.device(headers);
    if (!auth) return unauthorized;
    const catalog = await this.store.catalog(auth.owner);
    const key = readKey(process.env.OPL_NETFLEET_CLOUD_MASTER_KEY_FILE);
    const current = catalog.sites[auth.site.id];
    if (
      !current ||
      current.owner !== auth.owner ||
      current.token_hash !== auth.site.token_hash
    ) {
      return unauthorized;
    }
    const rows = current.grants
      .map((id) => catalog.subscriptions[id])
      .filter((item) => item?.owner === auth.owner)
      .map((subscription) => ({
        id: subscription.id,
        name: subscription.name,
        url: open(
          subscription.envelope,
          key,
          this.subscriptionAad(auth.owner, subscription.id),
        ),
      }));
    return {
      status: 200,
      body: { revision: current.revision, subscriptions: rows },
    };
  }

  async watchdog(headers: Headers) {
    const provided = bearerToken(headers.get("authorization"));
    const path = process.env.OPL_NETFLEET_CLOUD_WATCHDOG_SECRET_FILE;
    if (
      !provided ||
      !path ||
      !timingSafeEqual(
        Buffer.from(sha256(provided), "hex"),
        Buffer.from(sha256(readKey(path).toString("base64url")), "hex"),
      )
    )
      return unauthorized;
    const cutoff = Date.now() - timeout;
    const tenantIds = await this.store.listTenantIds();
    const sites: Array<{
      owner_actor_id: string;
      site_id: string;
      last_seen_at: string | null;
      overdue: boolean;
      recovering: boolean;
    }> = [];
    for (const ownerId of tenantIds) {
      const catalog = await this.store.catalog(ownerId);
      const ids = Object.keys(catalog.sites);
      if (!ids.length) continue;
      const snapshots = await this.store.snapshots(ownerId, ids);
      ids.forEach((id, index) => {
        const seen = snapshots[index]?.last_seen_at ?? null;
        const overdue = !seen || Date.parse(seen) < cutoff;
        const recovering = snapshots[index]?.latest.recovery === true;
        if (overdue || recovering) {
          sites.push({
            owner_actor_id: ownerId,
            site_id: id,
            last_seen_at: seen,
            overdue,
            recovering,
          });
        }
      });
    }
    return {
      status: 200,
      body: {
        ok: true,
        overdue_count: sites.filter((site) => site.overdue).length,
        sites,
      },
    };
  }

  async overview(headers: Headers) {
    const auth = await this.human(headers);
    if (!auth) return unauthorized;
    const catalog = await this.store.catalog(auth.owner);
    const ids = Object.values(catalog.sites)
      .filter((site) => site.owner === auth.owner)
      .map((site) => site.id);
    const snapshots = await this.store.snapshots(auth.owner, ids);
    return {
      status: 200,
      body: {
        sites: ids.map((id, index) => {
          const site = catalog.sites[id];
          const snapshot = snapshots[index];
          return {
            id,
            name: site.name,
            ...(site.device_id ? { device_id: site.device_id } : {}),
            revision: site.revision,
            grants: site.grants,
            token_active: !!site.token_hash,
            online:
              !!snapshot &&
              Date.now() - Date.parse(snapshot.last_seen_at) < timeout,
            snapshot,
          };
        }),
      },
    };
  }

  async createSite(headers: Headers, body: unknown) {
    const auth = await this.human(headers);
    const input = asObject(body);
    if (!auth) return unauthorized;
    if (
      !input ||
      !only(input, ["id", "name"]) ||
      !siteId(input.id) ||
      !validName(input.name)
    )
      return { status: 400, body: { error: "invalid_site" } };
    const maxSites = this.maxSitesFor(auth.identity);
    try {
      await this.store.change(auth.owner, (catalog) => {
        if (Object.hasOwn(catalog.sites, input.id as string))
          throw new Error("site_exists");
        if (Object.keys(catalog.sites).length >= maxSites)
          throw new Error("site_limit");
        catalog.sites[input.id as string] = {
          id: input.id as string,
          name: input.name as string,
          owner: auth.owner,
          revision: 0,
          grants: [],
        };
        return { result: true, write: true };
      });
      return { status: 201, body: { id: input.id } };
    } catch (error) {
      if (
        !(error instanceof Error) ||
        !["site_exists", "site_limit"].includes(error.message)
      )
        throw error;
      return { status: 409, body: { error: error.message } };
    }
  }

  async rotateToken(headers: Headers, id: string) {
    const auth = await this.human(headers);
    if (!auth) return unauthorized;
    const plain = randomToken();
    try {
      await this.store.change(auth.owner, (catalog) => {
        const site = catalog.sites[id];
        if (!site || site.owner !== auth.owner)
          throw new Error("site_not_found");
        site.token_hash = sha256(plain);
        return { result: true, write: true };
      });
      return { status: 200, body: { id, device_token: plain } };
    } catch (error) {
      if (!(error instanceof Error) || error.message !== "site_not_found")
        throw error;
      return { status: 404, body: { error: "site_not_found" } };
    }
  }

  async revokeToken(headers: Headers, id: string) {
    const auth = await this.human(headers);
    if (!auth) return unauthorized;
    try {
      await this.store.change(auth.owner, (catalog) => {
        const site = catalog.sites[id];
        if (!site || site.owner !== auth.owner)
          throw new Error("site_not_found");
        delete site.token_hash;
        return { result: true, write: true };
      });
      return { status: 200, body: { ok: true } };
    } catch (error) {
      if (!(error instanceof Error) || error.message !== "site_not_found")
        throw error;
      return { status: 404, body: { error: "site_not_found" } };
    }
  }

  async renameSite(headers: Headers, id: string, body: unknown) {
    const auth = await this.human(headers);
    if (!auth) return unauthorized;
    const input = asObject(body);
    if (!input || !only(input, ["name"]) || !validName(input.name)) {
      return { status: 400, body: { error: "invalid_site" } };
    }
    const name = input.name.trim();
    const updated = await this.store.change(auth.owner, (catalog) => {
      const site = catalog.sites[id];
      if (!site || site.owner !== auth.owner) return { result: null };
      site.name = name;
      return { result: { ok: true, id, name }, write: true };
    });
    return updated
      ? { status: 200, body: updated }
      : { status: 404, body: { error: "site_not_found" } };
  }

  async deleteSite(headers: Headers, id: string) {
    const auth = await this.human(headers);
    if (!auth) return unauthorized;
    try {
      await this.store.change(auth.owner, (catalog) => {
        const site = catalog.sites[id];
        if (!site || site.owner !== auth.owner)
          throw new Error("site_not_found");
        delete catalog.sites[id];
        return { result: true, write: true, removeSnapshot: id };
      });
      return { status: 200, body: { ok: true } };
    } catch (error) {
      if (!(error instanceof Error) || error.message !== "site_not_found")
        throw error;
      return { status: 404, body: { error: "site_not_found" } };
    }
  }

  async listSubscriptions(headers: Headers) {
    const auth = await this.human(headers);
    if (!auth) return unauthorized;
    const catalog = await this.store.catalog(auth.owner);
    return {
      status: 200,
      body: {
        subscriptions: Object.values(catalog.subscriptions)
          .filter((item) => item.owner === auth.owner)
          .map(({ id, name, fingerprint }) => ({ id, name, fingerprint })),
      },
    };
  }

  async createSubscription(headers: Headers, body: unknown) {
    const auth = await this.human(headers);
    const input = asObject(body);
    if (!auth) return unauthorized;
    if (
      !input ||
      !only(input, ["id", "name", "url"]) ||
      typeof input.id !== "string" ||
      !sourceId(input.id) ||
      !validName(input.name) ||
      typeof input.url !== "string" ||
      !validSourceUrl(input.url)
    )
      return { status: 400, body: { error: "invalid_subscription" } };
    const key = readKey(process.env.OPL_NETFLEET_CLOUD_MASTER_KEY_FILE);
    const subscription: Subscription = {
      id: input.id,
      name: input.name.trim(),
      owner: auth.owner,
      fingerprint: sha256(input.url).slice(0, 12),
      envelope: seal(
        input.url,
        key,
        this.subscriptionAad(auth.owner, input.id),
      ),
    };
    try {
      await this.store.change(auth.owner, (catalog) => {
        if (Object.hasOwn(catalog.subscriptions, subscription.id))
          throw new Error("subscription_exists");
        if (Object.keys(catalog.subscriptions).length >= 64)
          throw new Error("subscription_limit");
        catalog.subscriptions[subscription.id] = subscription;
        return { result: true, write: true };
      });
      return {
        status: 201,
        body: {
          id: subscription.id,
          name: subscription.name,
          fingerprint: subscription.fingerprint,
        },
      };
    } catch (error) {
      if (
        !(error instanceof Error) ||
        !["subscription_exists", "subscription_limit"].includes(error.message)
      )
        throw error;
      return { status: 409, body: { error: error.message } };
    }
  }

  async deleteSubscription(headers: Headers, id: string) {
    const auth = await this.human(headers);
    if (!auth) return unauthorized;
    try {
      await this.store.change(auth.owner, (catalog) => {
        const subscription = catalog.subscriptions[id];
        if (!subscription || subscription.owner !== auth.owner)
          throw new Error("subscription_not_found");
        delete catalog.subscriptions[id];
        Object.values(catalog.sites)
          .filter(
            (site) => site.owner === auth.owner && site.grants.includes(id),
          )
          .forEach((site) => {
            site.grants = site.grants.filter((grant) => grant !== id);
            site.revision += 1;
          });
        return { result: true, write: true };
      });
      return { status: 200, body: { ok: true } };
    } catch (error) {
      if (
        !(error instanceof Error) ||
        error.message !== "subscription_not_found"
      )
        throw error;
      return { status: 404, body: { error: "subscription_not_found" } };
    }
  }

  async updateSubscription(headers: Headers, id: string, body: unknown) {
    const auth = await this.human(headers);
    if (!auth) return unauthorized;
    if (
      !record(body) ||
      !only(body, ["name", "url"]) ||
      !validName(body.name) ||
      (body.url !== undefined &&
        body.url !== "" &&
        (typeof body.url !== "string" || !validSourceUrl(body.url)))
    ) {
      return { status: 400, body: { error: "invalid_subscription" } };
    }
    const name = body.name.trim();
    const url = typeof body.url === "string" ? body.url : "";
    const updated = await this.store.change(auth.owner, (catalog) => {
      const item = catalog.subscriptions[id];
      if (item?.owner !== auth.owner) return { result: null };
      item.name = name;
      if (url && item.fingerprint !== sha256(url).slice(0, 12)) {
        item.fingerprint = sha256(url).slice(0, 12);
        item.envelope = seal(
          url,
          readKey(process.env.OPL_NETFLEET_CLOUD_MASTER_KEY_FILE),
          this.subscriptionAad(auth.owner, id),
        );
        for (const site of Object.values(catalog.sites)) {
          if (site.owner === auth.owner && site.grants.includes(id))
            site.revision++;
        }
      }
      return {
        result: { id, name, fingerprint: item.fingerprint },
        write: true,
      };
    });
    return updated
      ? { status: 200, body: updated }
      : { status: 404, body: { error: "subscription_not_found" } };
  }

  async grants(headers: Headers, id: string, body: unknown) {
    const auth = await this.human(headers);
    const input = asObject(body);
    if (!auth) return unauthorized;
    if (
      !input ||
      !only(input, ["subscription_ids"]) ||
      !Array.isArray(input.subscription_ids) ||
      input.subscription_ids.length > 16 ||
      !input.subscription_ids.every(sourceId)
    )
      return { status: 400, body: { error: "invalid_grants" } };
    try {
      const revision = await this.store.change(auth.owner, (catalog) => {
        const site = catalog.sites[id];
        if (!site || site.owner !== auth.owner)
          throw new Error("site_not_found");
        const wanted = input.subscription_ids as string[];
        if (
          wanted.some(
            (item) => catalog.subscriptions[item]?.owner !== auth.owner,
          )
        )
          throw new Error("subscription_not_found");
        const grants = [...new Set(wanted)].sort();
        if (grants.join(",") === [...site.grants].sort().join(","))
          return { result: site.revision };
        site.grants = grants;
        site.revision += 1;
        return { result: site.revision, write: true };
      });
      return { status: 200, body: { ok: true, desired_revision: revision } };
    } catch (error) {
      if (
        !(error instanceof Error) ||
        !["site_not_found", "subscription_not_found"].includes(error.message)
      )
        throw error;
      return {
        status: error.message === "subscription_not_found" ? 400 : 404,
        body: { error: error.message },
      };
    }
  }
}
