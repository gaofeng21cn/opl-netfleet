import type { Identity } from "./contracts.js";

export interface IdentityProvider {
  authenticate(bearer: string): Promise<Identity | null>;
  authenticatePassword?(
    email: string,
    password: string,
  ): Promise<Identity | null>;
}

export class OplGatewayIdentityProvider implements IdentityProvider {
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
