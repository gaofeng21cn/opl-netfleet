export type Identity = {
  subject: string;
  email: string;
  role: "owner" | "admin";
};
export type Traffic = Partial<
  Record<
    "upload_bps" | "download_bps" | "upload_bytes" | "download_bytes",
    number
  >
>;
export type Heartbeat = {
  site_id: string;
  applied_revision: number;
  mode: string;
  capabilities: {
    id: string;
    region?: string;
    node?: string;
    rtt_ms?: number;
    provider?: string;
  }[];
  traffic: Traffic;
  quotas?: {
    provider: string;
    remaining_bytes?: number;
    total_bytes?: number;
  }[];
  recovery?: boolean;
  event?: string;
};
export type Trend = Traffic & { at: string; rtt_ms?: number };
export type Snapshot = {
  last_seen_at: string;
  latest: Heartbeat;
  trend: Trend[];
};
export type Site = {
  id: string;
  name: string;
  owner: string;
  revision: number;
  grants: string[];
  token_hash?: string;
};
export type Subscription = {
  id: string;
  name: string;
  fingerprint: string;
  envelope: string;
  owner: string;
};
export type Catalog = {
  sites: Record<string, Site>;
  subscriptions: Record<string, Subscription>;
};
export type Change<T> = { result: T; write?: true; removeSnapshot?: string };
export interface Store {
  catalog(): Promise<Catalog>;
  change<T>(fn: (catalog: Catalog) => Change<T>): Promise<T>;
  snapshots(ids: string[]): Promise<(Snapshot | null)[]>;
  heartbeat<T>(
    id: string,
    fn: (
      catalog: Catalog,
      old: Snapshot | null,
    ) => { result: T; snapshot?: Snapshot },
  ): Promise<T>;
}
