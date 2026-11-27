import type { Identity } from "./contracts.js";

export interface IdentityProvider {
  authenticate(bearer: string): Promise<Identity | null>;
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
}
