import { createPublicKey, verify, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import type { Identity } from "./contracts.js";

export type GrantScope = "device:enroll" | "console:login";

export type GrantVerifyOptions = {
  issuer?: string;
  audience?: string;
  service?: string;
  publicKeyRaw?: string;
  publicKeyFile?: string;
  jwksUrl?: string;
  request?: typeof fetch;
  cacheTtlMs?: number;
  refreshCooldownMs?: number;
};

type JwkEntry = {
  kty?: unknown;
  crv?: unknown;
  alg?: unknown;
  use?: unknown;
  kid?: unknown;
  x?: unknown;
};

const B64URL = /^[A-Za-z0-9_-]+$/;
const NUMERIC_ACTOR = /^[1-9][0-9]{0,19}$/;

function normalizeIssuer(raw: string | undefined): string {
  const trimmed = (raw ?? "").trim().replace(/\/+$/, "");
  if (!trimmed) throw new Error("grant_issuer_required");
  const parsed = new URL(trimmed);
  const localHttp =
    parsed.protocol === "http:" &&
    (parsed.hostname === "127.0.0.1" || parsed.hostname === "localhost");
  if (
    (parsed.protocol !== "https:" && !localHttp) ||
    parsed.origin !== trimmed
  ) {
    throw new Error("grant_issuer_invalid");
  }
  return trimmed;
}

function normalizeJwksUrl(raw: string | undefined): string | undefined {
  const trimmed = (raw ?? "").trim();
  if (!trimmed) return undefined;
  const parsed = new URL(trimmed);
  const localHttp =
    parsed.protocol === "http:" &&
    (parsed.hostname === "127.0.0.1" || parsed.hostname === "localhost");
  if (
    (parsed.protocol !== "https:" && !localHttp) ||
    parsed.username ||
    parsed.password
  ) {
    throw new Error("grant_jwks_url_invalid");
  }
  return trimmed;
}

function decodeBase64UrlJson(segment: string): Record<string, unknown> | null {
  try {
    const parsed = JSON.parse(
      Buffer.from(segment, "base64url").toString("utf8"),
    );
    return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

function keyObjectFromJwk(entry: JwkEntry): { kid?: string; key: KeyObject } | null {
  if (
    entry.kty !== "OKP" ||
    entry.crv !== "Ed25519" ||
    (entry.alg !== undefined && entry.alg !== "EdDSA") ||
    (entry.use !== undefined && entry.use !== "sig") ||
    typeof entry.x !== "string" ||
    !entry.x
  ) {
    return null;
  }
  try {
    const key = createPublicKey({
      key: { kty: "OKP", crv: "Ed25519", x: entry.x },
      format: "jwk",
    });
    if (key.asymmetricKeyType !== "ed25519") return null;
    const kid =
      typeof entry.kid === "string" && entry.kid.trim()
        ? entry.kid.trim()
        : undefined;
    return { ...(kid ? { kid } : {}), key };
  } catch {
    return null;
  }
}

function parseStaticKeyMaterial(raw: string): {
  byKid: Map<string, KeyObject>;
  unkeyed: KeyObject[];
} {
  const byKid = new Map<string, KeyObject>();
  const unkeyed: KeyObject[] = [];
  const trimmed = raw.trim();
  if (!trimmed) return { byKid, unkeyed };

  if (trimmed.includes("-----BEGIN PUBLIC KEY-----")) {
    const key = createPublicKey(trimmed);
    if (key.asymmetricKeyType !== "ed25519") {
      throw new Error("grant_public_key_not_ed25519");
    }
    unkeyed.push(key);
    return { byKid, unkeyed };
  }

  if (trimmed.startsWith("{")) {
    const parsed = JSON.parse(trimmed) as { keys?: unknown } & JwkEntry;
    const items = Array.isArray(parsed.keys)
      ? (parsed.keys as JwkEntry[])
      : [parsed as JwkEntry];
    for (const item of items) {
      const converted = keyObjectFromJwk(item);
      if (!converted) throw new Error("grant_public_jwk_invalid");
      if (converted.kid) byKid.set(converted.kid, converted.key);
      else unkeyed.push(converted.key);
    }
    return { byKid, unkeyed };
  }

  for (const encoding of ["base64url", "base64"] as const) {
    try {
      const decoded = Buffer.from(trimmed, encoding);
      if (decoded.length === 32) {
        const key = createPublicKey({
          key: {
            kty: "OKP",
            crv: "Ed25519",
            x: decoded.toString("base64url"),
          },
          format: "jwk",
        });
        unkeyed.push(key);
        return { byKid, unkeyed };
      }
    } catch {}
  }

  throw new Error("grant_public_key_invalid");
}

export class OplCloudGrantVerifier {
  private readonly issuer: string;
  private readonly audience: string;
  private readonly service: string;
  private readonly jwksUrl?: string;
  private readonly request: typeof fetch;
  private readonly cacheTtlMs: number;
  private readonly refreshCooldownMs: number;
  private readonly staticByKid = new Map<string, KeyObject>();
  private readonly staticUnkeyed: KeyObject[] = [];
  private remoteByKid = new Map<string, KeyObject>();
  private lastFetchAt = 0;
  private lastAttemptAt = 0;
  private inflight: Promise<void> | null = null;

  constructor(options: GrantVerifyOptions) {
    this.issuer = normalizeIssuer(options.issuer);
    this.audience = options.audience?.trim() || "opl-netfleet-cloud";
    this.service = options.service?.trim() || "netfleet_cloud";
    this.jwksUrl = normalizeJwksUrl(options.jwksUrl);
    this.request = options.request ?? fetch;
    this.cacheTtlMs = options.cacheTtlMs ?? 300_000;
    this.refreshCooldownMs = options.refreshCooldownMs ?? 15_000;

    const material =
      options.publicKeyRaw?.trim() ||
      (options.publicKeyFile
        ? readFileSync(options.publicKeyFile, "utf8").trim()
        : "");
    if (material) {
      const parsed = parseStaticKeyMaterial(material);
      for (const [kid, key] of parsed.byKid) this.staticByKid.set(kid, key);
      this.staticUnkeyed.push(...parsed.unkeyed);
    }
    if (
      !this.staticByKid.size &&
      !this.staticUnkeyed.length &&
      !this.jwksUrl
    ) {
      throw new Error("grant_verifier_key_or_jwks_required");
    }
  }

  private async ensureRemoteKeys(forceOnUnknownKid: boolean): Promise<void> {
    if (!this.jwksUrl) return;
    const now = Date.now();
    const expired = now - this.lastFetchAt >= this.cacheTtlMs;
    const canForce =
      forceOnUnknownKid && now - this.lastAttemptAt >= this.refreshCooldownMs;
    if (!expired && !canForce) return;
    if (this.inflight) return this.inflight;

    this.lastAttemptAt = now;
    this.inflight = (async () => {
      try {
        const res = await this.request(this.jwksUrl!, {
          headers: { Accept: "application/json" },
          signal: AbortSignal.timeout(5000),
          redirect: "error",
        });
        if (!res.ok) return;
        const body = (await res.json()) as { keys?: unknown };
        if (!Array.isArray(body?.keys)) return;
        const next = new Map<string, KeyObject>();
        for (const item of body.keys) {
          if (!item || typeof item !== "object") continue;
          const converted = keyObjectFromJwk(item as JwkEntry);
          if (converted?.kid) next.set(converted.kid, converted.key);
        }
        if (next.size > 0) {
          this.remoteByKid = next;
          this.lastFetchAt = Date.now();
        }
      } catch {}
    })().finally(() => {
      this.inflight = null;
    });
    return this.inflight;
  }

  private async candidateKeys(kid: string | undefined): Promise<KeyObject[]> {
    const candidates: KeyObject[] = [];
    if (kid) {
      const staticHit = this.staticByKid.get(kid);
      if (staticHit) candidates.push(staticHit);
      let remoteHit = this.remoteByKid.get(kid);
      if (!remoteHit && !staticHit && this.jwksUrl) {
        await this.ensureRemoteKeys(true);
        remoteHit = this.remoteByKid.get(kid);
      }
      if (remoteHit) candidates.push(remoteHit);
    } else if (
      !this.staticUnkeyed.length &&
      this.jwksUrl &&
      Date.now() - this.lastFetchAt >= this.cacheTtlMs
    ) {
      await this.ensureRemoteKeys(false);
    }
    candidates.push(...this.staticUnkeyed);
    return candidates;
  }

  async verify(
    token: string,
    expectedScope: GrantScope,
    nowSec = Math.floor(Date.now() / 1000),
  ): Promise<Identity | null> {
    if (typeof token !== "string" || !token || token.length > 4096) return null;
    const parts = token.split(".");
    if (
      parts.length !== 3 ||
      !parts.every((part) => part.length > 0 && B64URL.test(part))
    ) {
      return null;
    }

    const header = decodeBase64UrlJson(parts[0]);
    if (
      !header ||
      header.alg !== "EdDSA" ||
      (header.typ !== undefined && header.typ !== "JWT") ||
      (header.kid !== undefined &&
        (typeof header.kid !== "string" ||
          !header.kid ||
          header.kid.length > 128))
    ) {
      return null;
    }

    const kid = typeof header.kid === "string" ? header.kid : undefined;
    const keys = await this.candidateKeys(kid);
    if (!keys.length) return null;

    const signingInput = Buffer.from(`${parts[0]}.${parts[1]}`, "ascii");
    const signature = Buffer.from(parts[2], "base64url");
    if (
      signature.length !== 64 ||
      !keys.some((key) => {
        try {
          return verify(null, signingInput, key, signature);
        } catch {
          return false;
        }
      })
    ) {
      return null;
    }

    const claims = decodeBase64UrlJson(parts[1]);
    if (!claims) return null;
    const iss =
      typeof claims.iss === "string"
        ? claims.iss.trim().replace(/\/+$/, "")
        : "";
    if (
      iss !== this.issuer ||
      claims.aud !== this.audience ||
      claims.service !== this.service ||
      claims.scope !== expectedScope ||
      typeof claims.sub !== "string" ||
      !NUMERIC_ACTOR.test(claims.sub) ||
      typeof claims.email !== "string" ||
      typeof claims.jti !== "string" ||
      !claims.jti ||
      claims.jti.length > 128 ||
      (claims.role !== "owner" &&
        claims.role !== "admin" &&
        claims.role !== "user") ||
      typeof claims.iat !== "number" ||
      !Number.isSafeInteger(claims.iat) ||
      typeof claims.exp !== "number" ||
      !Number.isSafeInteger(claims.exp)
    ) {
      return null;
    }
    const email = claims.email.trim().toLowerCase();
    if (!email || email.length > 254) return null;
    if (
      claims.exp <= claims.iat ||
      claims.exp - claims.iat > 600 ||
      nowSec > claims.exp + 30 ||
      claims.iat > nowSec + 30
    ) {
      return null;
    }

    let limits: Identity["limits"];
    if (claims.limits !== undefined) {
      if (
        claims.limits === null ||
        typeof claims.limits !== "object" ||
        Array.isArray(claims.limits)
      ) {
        return null;
      }
      const rawMaxSites = (claims.limits as Record<string, unknown>).max_sites;
      if (rawMaxSites !== undefined) {
        if (
          typeof rawMaxSites !== "number" ||
          !Number.isSafeInteger(rawMaxSites) ||
          rawMaxSites < 1 ||
          rawMaxSites > 64
        ) {
          return null;
        }
        limits = { max_sites: rawMaxSites };
      }
    }

    return {
      subject: claims.sub,
      email,
      role: claims.role,
      ...(limits ? { limits } : {}),
    };
  }
}
