export type Identity = {
  subject: string;
  email: string;
  role: "owner" | "admin" | "user";
  limits?: {
    max_sites?: number;
  };
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
  device_id?: string;
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
export type DeviceTokenBinding = {
  owner: string;
  site_id: string;
};
export interface Store {
  catalog(ownerId: string): Promise<Catalog>;
  change<T>(ownerId: string, fn: (catalog: Catalog) => Change<T>): Promise<T>;
  snapshots(ownerId: string, ids: string[]): Promise<(Snapshot | null)[]>;
  heartbeat<T>(
    ownerId: string,
    siteId: string,
    fn: (
      catalog: Catalog,
      old: Snapshot | null,
    ) => { result: T; snapshot?: Snapshot },
  ): Promise<T>;
  resolveDeviceToken(tokenHash: string): Promise<DeviceTokenBinding | null>;
  listTenantIds(): Promise<string[]>;
}
