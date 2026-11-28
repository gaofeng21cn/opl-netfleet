import type { Identity } from "./contracts.js";
import { OplCloudGrantVerifier, type GrantScope } from "./grant.js";

export type AuthOutcome =
  | { status: "ok"; identity: Identity }
  | { status: "requires_2fa" }
  | { status: "not_entitled" }
  | { status: "rate_limited" }
  | { status: "unavailable" }
  | { status: "unauthorized" };

export interface IdentityProvider {
  readonly mode?: "cloud" | "self-hosted";
  authenticate(bearer: string): Promise<Identity | null>;
  authenticatePassword?(
    email: string,
    password: string,
    totpCode?: string,
  ): Promise<Identity | null>;
  authenticatePasswordDetailed?(
    email: string,
    password: string,
    totpCode?: string,
  ): Promise<AuthOutcome>;
  authenticateBearerDetailed?(bearer: string): Promise<AuthOutcome>;
  verifyGrant?(
    grantToken: string,
    scope: GrantScope,
  ): Promise<Identity | null>;
}

function normalizeOrigin(origin: string | undefined, errCode: string): string | undefined {
  if (!origin) return undefined;
  const trimmed = origin.trim().replace(/\/+$/, "");
  const parsed = new URL(trimmed);
  const localHttp =
    parsed.protocol === "http:" &&
    (parsed.hostname === "127.0.0.1" || parsed.hostname === "localhost");
  if ((parsed.protocol !== "https:" && !localHttp) || parsed.origin !== trimmed) {
    throw new Error(errCode);
  }
  return trimmed;
}

export class OplCloudIdentityProvider implements IdentityProvider {
  readonly mode = "cloud" as const;
  private readonly cloudOrigin?: string;
  private readonly verifier: OplCloudGrantVerifier;
  private readonly service: string;
  private readonly request: typeof fetch;

  constructor(options: {
    cloudOrigin?: string;
    verifier: OplCloudGrantVerifier;
    service?: string;
    request?: typeof fetch;
  }) {
    this.cloudOrigin = normalizeOrigin(
      options.cloudOrigin,
      "cloud_requires_https_origin",
    );
    this.verifier = options.verifier;
    this.service = options.service?.trim() || "netfleet_cloud";
    this.request = options.request ?? fetch;
  }

  async verifyGrant(
    grantToken: string,
    scope: GrantScope,
  ): Promise<Identity | null> {
    return this.verifier.verify(grantToken, scope);
  }

  private async mapGrantResponse(response: Response): Promise<AuthOutcome> {
    let payload: Record<string, unknown> | null = null;
    try {
      const parsed = await response.json();
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        payload = parsed as Record<string, unknown>;
      }
    } catch {}

    if (response.status === 429) return { status: "rate_limited" };
    if (response.status === 403) return { status: "not_entitled" };
    if (response.status === 401 || response.status === 400) {
      return { status: "unauthorized" };
    }
    if (!response.ok) return { status: "unavailable" };
    if (payload?.requires_2fa === true) return { status: "requires_2fa" };
    if (
      payload?.enabled !== true ||
      typeof payload.grant_token !== "string" ||
      !payload.grant_token
    ) {
      return { status: "unauthorized" };
    }
    const verified = await this.verifier.verify(
      payload.grant_token,
      "console:login",
    );
    return verified
      ? { status: "ok", identity: verified }
      : { status: "unauthorized" };
  }

  async authenticatePasswordDetailed(
    email: string,
    password: string,
    totpCode?: string,
  ): Promise<AuthOutcome> {
    const normalized = email.trim().toLowerCase();
    const trimmedTotp = totpCode?.trim() ?? "";
    if (
      !this.cloudOrigin ||
      !normalized ||
      !password ||
      normalized.length > 254 ||
      password.length > 512 ||
      trimmedTotp.length > 16
    ) {
      return { status: "unauthorized" };
    }
    try {
      const response = await this.request(
        `${this.cloudOrigin}/api/v2/client/service-grant`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Accept: "application/json",
          },
          body: JSON.stringify({
            email: normalized,
            password,
            ...(trimmedTotp ? { totp_code: trimmedTotp } : {}),
            service: this.service,
            scope: "console:login",
          }),
          signal: AbortSignal.timeout(8000),
          redirect: "error",
        },
      );
      return this.mapGrantResponse(response);
    } catch {
      return { status: "unavailable" };
    }
  }

  async authenticateBearerDetailed(bearer: string): Promise<AuthOutcome> {
    const token = bearer.trim();
    if (!token || token.length > 4096) return { status: "unauthorized" };
    if (token.split(".").length === 3) {
      const direct = await this.verifier.verify(token, "console:login");
      if (direct) return { status: "ok", identity: direct };
    }
    if (!this.cloudOrigin) return { status: "unauthorized" };
    try {
      const response = await this.request(
        `${this.cloudOrigin}/api/v2/client/service-grant`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
            Accept: "application/json",
          },
          body: JSON.stringify({
            service: this.service,
            scope: "console:login",
          }),
          signal: AbortSignal.timeout(8000),
          redirect: "error",
        },
      );
      return this.mapGrantResponse(response);
    } catch {
      return { status: "unavailable" };
    }
  }

  async authenticate(bearer: string): Promise<Identity | null> {
    const outcome = await this.authenticateBearerDetailed(bearer);
    return outcome.status === "ok" ? outcome.identity : null;
  }

  async authenticatePassword(
    email: string,
    password: string,
    totpCode?: string,
  ): Promise<Identity | null> {
    const outcome = await this.authenticatePasswordDetailed(
      email,
      password,
      totpCode,
    );
    return outcome.status === "ok" ? outcome.identity : null;
  }
}

export class OplGatewayIdentityProvider implements IdentityProvider {
  readonly mode = "self-hosted" as const;

  constructor(
    private readonly origin: string | undefined,
    private readonly allow: string[],
    private readonly request = fetch,
  ) {
    if (
      origin &&
      (new URL(origin).protocol !== "https:" ||
        new URL(origin).origin !== origin)
    ) {
      throw new Error("gateway_requires_https_origin");
    }
  }

  async authenticate(bearer: string): Promise<Identity | null> {
    if (!this.origin || !this.allow.length || !bearer) return null;
    try {
      const response = await this.request(`${this.origin}/api/v1/auth/me`, {
        headers: {
          Authorization: `Bearer ${bearer}`,
          Accept: "application/json",
        },
        signal: AbortSignal.timeout(5000),
        redirect: "error",
      });
      if (!response.ok) return null;
      const body = await response.json();
      const user = body?.data;
      const subject = user?.id ?? user?.subject;
      if (
        body?.code !== 0 ||
        user?.status !== "active" ||
        !(
          (Number.isSafeInteger(subject) && subject > 0) ||
          (typeof subject === "string" &&
            /^[a-zA-Z0-9_-]{1,100}$/.test(subject))
        )
      )
        return null;
      const email =
        typeof user.email === "string" ? user.email.trim().toLowerCase() : "";
      if (!this.allow.includes(email)) return null;
      return {
        subject: String(subject),
        email,
        role: user.role === "owner" ? "owner" : "admin",
      };
    } catch {
      return null;
    }
  }

  async authenticatePassword(
    email: string,
    password: string,
  ): Promise<Identity | null> {
    const normalized = email.trim().toLowerCase();
    if (
      !this.origin ||
      !this.allow.length ||
      !normalized ||
      !password ||
      normalized.length > 254 ||
      password.length > 512 ||
      !this.allow.includes(normalized)
    ) {
      return null;
    }
    let accessToken = "";
    let refreshToken = "";
    try {
      const response = await this.request(`${this.origin}/api/v1/auth/login`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        body: JSON.stringify({
          email: normalized,
          password,
          turnstile_token: "",
        }),
        signal: AbortSignal.timeout(8000),
        redirect: "error",
      });
      if (!response.ok) return null;
      const body = await response.json();
      const token = body?.data?.access_token;
      if (body?.code !== 0 || typeof token !== "string" || !token) {
        return null;
      }
      accessToken = token;
      if (typeof body?.data?.refresh_token === "string") {
        refreshToken = body.data.refresh_token;
      }
      const identity = await this.authenticate(accessToken);
      return identity && identity.email === normalized ? identity : null;
    } catch {
      return null;
    } finally {
      if (accessToken && refreshToken) {
        try {
          await this.request(`${this.origin}/api/v1/auth/logout`, {
            method: "POST",
            headers: {
              Authorization: `Bearer ${accessToken}`,
              "Content-Type": "application/json",
              Accept: "application/json",
            },
            body: JSON.stringify({ refresh_token: refreshToken }),
            signal: AbortSignal.timeout(3000),
            redirect: "error",
          });
        } catch {}
      }
    }
  }
}

export function createIdentityProviderFromEnv(
  env: Record<string, string | undefined> = process.env,
  request: typeof fetch = fetch,
): IdentityProvider {
  const cloudOrigin = env.OPL_CLOUD_ORIGIN?.trim().replace(/\/+$/, "");
  const publicKeyRaw = env.OPL_CLOUD_GRANT_PUBLIC_KEY?.trim();
  const publicKeyFile = env.OPL_CLOUD_GRANT_PUBLIC_KEY_FILE?.trim();
  const jwksUrl =
    env.OPL_CLOUD_JWKS_URL?.trim() ||
    (cloudOrigin ? `${cloudOrigin}/.well-known/opl-grant-jwks.json` : undefined);
  const issuer = env.OPL_CLOUD_ISSUER?.trim() || cloudOrigin;

  if (cloudOrigin || publicKeyRaw || publicKeyFile || jwksUrl) {
    const service = env.OPL_CLOUD_SERVICE_ID?.trim() || "netfleet_cloud";
    const verifier = new OplCloudGrantVerifier({
      issuer,
      audience: env.OPL_CLOUD_AUDIENCE?.trim() || "opl-netfleet-cloud",
      service,
      publicKeyRaw,
      publicKeyFile,
      jwksUrl,
      request,
    });
    return new OplCloudIdentityProvider({
      cloudOrigin,
      verifier,
      service,
      request,
    });
  }

  return new OplGatewayIdentityProvider(
    env.OPL_NETFLEET_CLOUD_GATEWAY_ORIGIN,
    (env.OPL_NETFLEET_CLOUD_ADMIN_EMAILS ?? "")
      .split(",")
      .map((value) => value.trim().toLowerCase())
      .filter(Boolean),
    request,
  );
}
