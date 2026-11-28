import { DatabaseSync } from "node:sqlite";
import { Firestore } from "@google-cloud/firestore";
import type {
  Catalog,
  Change,
  DeviceTokenBinding,
  Site,
  Snapshot,
  Store,
  Subscription,
} from "./contracts.js";

const empty = (): Catalog => ({ sites: {}, subscriptions: {} });
type DataRow = { id?: string; data: string };
type OwnerRow = { owner_id: string };
type TokenRow = { owner_id: string; site_id: string };
type TenantIndex = {
  site_ids?: string[];
  subscription_ids?: string[];
  updated_at?: string;
};
type TenantRegistryDoc = {
  ids?: string[];
};

export class SqliteStore implements Store {
  private readonly db: DatabaseSync;

  constructor(path: string) {
    this.db = new DatabaseSync(path);
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA busy_timeout = 5000;
      CREATE TABLE IF NOT EXISTS tenants (
        owner_id TEXT PRIMARY KEY,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sites (
        owner_id TEXT NOT NULL,
        site_id TEXT NOT NULL,
        data TEXT NOT NULL,
        PRIMARY KEY (owner_id, site_id)
      );
      CREATE TABLE IF NOT EXISTS subscriptions (
        owner_id TEXT NOT NULL,
        subscription_id TEXT NOT NULL,
        data TEXT NOT NULL,
        PRIMARY KEY (owner_id, subscription_id)
      );
      CREATE TABLE IF NOT EXISTS snapshots (
        owner_id TEXT NOT NULL,
        site_id TEXT NOT NULL,
        data TEXT NOT NULL,
        PRIMARY KEY (owner_id, site_id)
      );
      CREATE TABLE IF NOT EXISTS device_tokens (
        token_hash TEXT PRIMARY KEY,
        owner_id TEXT NOT NULL,
        site_id TEXT NOT NULL
      );
    `);
  }

  close() {
    this.db.close();
  }

  private readCatalog(ownerId: string): Catalog {
    const out = empty();
    const siteRows = this.db
      .prepare("SELECT site_id AS id, data FROM sites WHERE owner_id = ?")
      .all(ownerId) as DataRow[];
    for (const row of siteRows) {
      if (row.id) out.sites[row.id] = JSON.parse(row.data) as Site;
    }
    const subRows = this.db
      .prepare(
        "SELECT subscription_id AS id, data FROM subscriptions WHERE owner_id = ?",
      )
      .all(ownerId) as DataRow[];
    for (const row of subRows) {
      if (row.id)
        out.subscriptions[row.id] = JSON.parse(row.data) as Subscription;
    }
    return out;
  }

  private transaction<T>(fn: () => T): T {
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const result = fn();
      this.db.exec("COMMIT");
      return result;
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  async catalog(ownerId: string): Promise<Catalog> {
    return this.readCatalog(ownerId);
  }

  async snapshots(ownerId: string, ids: string[]): Promise<(Snapshot | null)[]> {
    const stmt = this.db.prepare(
      "SELECT data FROM snapshots WHERE owner_id = ? AND site_id = ?",
    );
    return ids.map((id) => {
      const row = stmt.get(ownerId, id) as DataRow | undefined;
      return row ? (JSON.parse(row.data) as Snapshot) : null;
    });
  }

  async change<T>(ownerId: string, fn: (catalog: Catalog) => Change<T>) {
    return this.transaction(() => {
      const catalog = this.readCatalog(ownerId);
      const change = fn(catalog);
      if (change.write) {
        this.db.prepare("DELETE FROM sites WHERE owner_id = ?").run(ownerId);
        this.db
          .prepare("DELETE FROM subscriptions WHERE owner_id = ?")
          .run(ownerId);
        this.db
          .prepare("DELETE FROM device_tokens WHERE owner_id = ?")
          .run(ownerId);

        const insertSite = this.db.prepare(
          "INSERT INTO sites (owner_id, site_id, data) VALUES (?, ?, ?)",
        );
        const insertToken = this.db.prepare(
          "INSERT INTO device_tokens (token_hash, owner_id, site_id) VALUES (?, ?, ?)",
        );
        for (const site of Object.values(catalog.sites)) {
          insertSite.run(ownerId, site.id, JSON.stringify(site));
          if (site.token_hash) {
            insertToken.run(site.token_hash, ownerId, site.id);
          }
        }

        const insertSub = this.db.prepare(
          "INSERT INTO subscriptions (owner_id, subscription_id, data) VALUES (?, ?, ?)",
        );
        for (const sub of Object.values(catalog.subscriptions)) {
          insertSub.run(ownerId, sub.id, JSON.stringify(sub));
        }

        if (
          Object.keys(catalog.sites).length ||
          Object.keys(catalog.subscriptions).length
        ) {
          this.db
            .prepare(
              "INSERT OR REPLACE INTO tenants (owner_id, updated_at) VALUES (?, ?)",
            )
            .run(ownerId, new Date().toISOString());
        } else {
          this.db
            .prepare("DELETE FROM tenants WHERE owner_id = ?")
            .run(ownerId);
        }
      }
      if (change.removeSnapshot) {
        this.db
          .prepare("DELETE FROM snapshots WHERE owner_id = ? AND site_id = ?")
          .run(ownerId, change.removeSnapshot);
      }
      return change.result;
    });
  }

  async heartbeat<T>(
    ownerId: string,
    siteId: string,
    fn: (
      catalog: Catalog,
      old: Snapshot | null,
    ) => { result: T; snapshot?: Snapshot },
  ) {
    return this.transaction(() => {
      const siteRow = this.db
        .prepare("SELECT data FROM sites WHERE owner_id = ? AND site_id = ?")
        .get(ownerId, siteId) as DataRow | undefined;
      const snapRow = this.db
        .prepare(
          "SELECT data FROM snapshots WHERE owner_id = ? AND site_id = ?",
        )
        .get(ownerId, siteId) as DataRow | undefined;
      const catalog = empty();
      if (siteRow) {
        catalog.sites[siteId] = JSON.parse(siteRow.data) as Site;
      }
      const old = snapRow ? (JSON.parse(snapRow.data) as Snapshot) : null;
      const result = fn(catalog, old);
      if (result.snapshot) {
        this.db
          .prepare(
            "INSERT OR REPLACE INTO snapshots (owner_id, site_id, data) VALUES (?, ?, ?)",
          )
          .run(ownerId, siteId, JSON.stringify(result.snapshot));
      }
      return result.result;
    });
  }

  async resolveDeviceToken(
    tokenHash: string,
  ): Promise<DeviceTokenBinding | null> {
    const row = this.db
      .prepare("SELECT owner_id, site_id FROM device_tokens WHERE token_hash = ?")
      .get(tokenHash) as TokenRow | undefined;
    return row ? { owner: row.owner_id, site_id: row.site_id } : null;
  }

  async listTenantIds(): Promise<string[]> {
    const rows = this.db
      .prepare("SELECT owner_id FROM tenants ORDER BY owner_id ASC")
      .all() as OwnerRow[];
    return rows.map((row) => row.owner_id);
  }
}

export class FirestoreStore implements Store {
  constructor(private readonly db = new Firestore()) {}

  private tenantDoc(ownerId: string) {
    return this.db.doc(`tenants/${ownerId}`);
  }
  private siteDoc(ownerId: string, siteId: string) {
    return this.db.doc(`tenants/${ownerId}/sites/${siteId}`);
  }
  private subscriptionDoc(ownerId: string, subId: string) {
    return this.db.doc(`tenants/${ownerId}/subscriptions/${subId}`);
  }
  private snapshotDoc(ownerId: string, siteId: string) {
    return this.db.doc(`tenants/${ownerId}/snapshots/${siteId}`);
  }
  private deviceTokenDoc(tokenHash: string) {
    return this.db.doc(`device_tokens/${tokenHash}`);
  }
  private get metaTenantsDoc() {
    return this.db.doc("meta/tenants");
  }

  async catalog(ownerId: string): Promise<Catalog> {
    const index = (await this.tenantDoc(ownerId).get()).data() as
      | TenantIndex
      | undefined;
    const siteIds = index?.site_ids ?? [];
    const subIds = index?.subscription_ids ?? [];
    if (!siteIds.length && !subIds.length) return empty();
    const siteRefs = siteIds.map((id) => this.siteDoc(ownerId, id));
    const subRefs = subIds.map((id) => this.subscriptionDoc(ownerId, id));
    const docs = await this.db.getAll(...siteRefs, ...subRefs);
    const out = empty();
    siteIds.forEach((id, i) => {
      const data = docs[i]?.data() as Site | undefined;
      if (data) out.sites[id] = data;
    });
    subIds.forEach((id, i) => {
      const data = docs[siteIds.length + i]?.data() as Subscription | undefined;
      if (data) out.subscriptions[id] = data;
    });
    return out;
  }

  async snapshots(ownerId: string, ids: string[]) {
    if (!ids.length) return [];
    const rows = await this.db.getAll(
      ...ids.map((id) => this.snapshotDoc(ownerId, id)),
    );
    return rows.map((row) => (row.data() as Snapshot | undefined) ?? null);
  }

  async change<T>(ownerId: string, fn: (catalog: Catalog) => Change<T>) {
    return this.db.runTransaction(async (tx) => {
      // Execute ALL reads before ANY write to satisfy Firestore transactions.
      const [tenantSnap, metaSnap] = await tx.getAll(
        this.tenantDoc(ownerId),
        this.metaTenantsDoc,
      );
      const index = (tenantSnap.data() as TenantIndex | undefined) ?? {};
      const oldSiteIds = [...(index.site_ids ?? [])];
      const oldSubIds = [...(index.subscription_ids ?? [])];
      const refs = [
        ...oldSiteIds.map((id) => this.siteDoc(ownerId, id)),
        ...oldSubIds.map((id) => this.subscriptionDoc(ownerId, id)),
      ];
      const catalog = empty();
      const oldTokenHashes = new Set<string>();
      if (refs.length > 0) {
        const docs = await tx.getAll(...refs);
        oldSiteIds.forEach((id, i) => {
          const data = docs[i]?.data() as Site | undefined;
          if (data) {
            catalog.sites[id] = data;
            if (data.token_hash) oldTokenHashes.add(data.token_hash);
          }
        });
        oldSubIds.forEach((id, i) => {
          const data = docs[oldSiteIds.length + i]?.data() as
            | Subscription
            | undefined;
          if (data) catalog.subscriptions[id] = data;
        });
      }

      const change = fn(catalog);
      if (change.write) {
        const newSiteIds = Object.keys(catalog.sites).sort();
        const newSubIds = Object.keys(catalog.subscriptions).sort();
        const newSiteSet = new Set(newSiteIds);
        const newSubSet = new Set(newSubIds);

        for (const id of oldSiteIds) {
          if (!newSiteSet.has(id)) tx.delete(this.siteDoc(ownerId, id));
        }
        for (const id of newSiteIds) {
          tx.set(this.siteDoc(ownerId, id), catalog.sites[id]);
        }

        for (const id of oldSubIds) {
          if (!newSubSet.has(id)) tx.delete(this.subscriptionDoc(ownerId, id));
        }
        for (const id of newSubIds) {
          tx.set(
            this.subscriptionDoc(ownerId, id),
            catalog.subscriptions[id],
          );
        }

        const newTokenMap = new Map<string, string>();
        for (const site of Object.values(catalog.sites)) {
          if (site.token_hash) newTokenMap.set(site.token_hash, site.id);
        }
        for (const hash of oldTokenHashes) {
          if (!newTokenMap.has(hash)) tx.delete(this.deviceTokenDoc(hash));
        }
        for (const [hash, siteId] of newTokenMap) {
          tx.set(this.deviceTokenDoc(hash), { owner: ownerId, site_id: siteId });
        }

        const existingTenantIds =
          ((metaSnap.data() as TenantRegistryDoc | undefined)?.ids ?? []);
        const tenantSet = new Set(existingTenantIds);
        if (newSiteIds.length || newSubIds.length) {
          tx.set(this.tenantDoc(ownerId), {
            site_ids: newSiteIds,
            subscription_ids: newSubIds,
            updated_at: new Date().toISOString(),
          });
          if (!tenantSet.has(ownerId)) {
            tenantSet.add(ownerId);
            tx.set(this.metaTenantsDoc, { ids: [...tenantSet].sort() });
          }
        } else {
          tx.delete(this.tenantDoc(ownerId));
          if (tenantSet.delete(ownerId)) {
            const remaining = [...tenantSet].sort();
            if (remaining.length) {
              tx.set(this.metaTenantsDoc, { ids: remaining });
            } else {
              tx.delete(this.metaTenantsDoc);
            }
          }
        }
      }
      if (change.removeSnapshot) {
        tx.delete(this.snapshotDoc(ownerId, change.removeSnapshot));
      }
      return change.result;
    });
  }

  async heartbeat<T>(
    ownerId: string,
    siteId: string,
    fn: (
      catalog: Catalog,
      old: Snapshot | null,
    ) => { result: T; snapshot?: Snapshot },
  ) {
    return this.db.runTransaction(async (tx) => {
      const siteRef = this.siteDoc(ownerId, siteId);
      const snapRef = this.snapshotDoc(ownerId, siteId);
      const [siteRow, snapRow] = await tx.getAll(siteRef, snapRef);
      const catalog = empty();
      const site = siteRow.data() as Site | undefined;
      if (site) catalog.sites[siteId] = site;
      const result = fn(
        catalog,
        (snapRow.data() as Snapshot | undefined) ?? null,
      );
      if (result.snapshot) tx.set(snapRef, result.snapshot);
      return result.result;
    });
  }

  async resolveDeviceToken(
    tokenHash: string,
  ): Promise<DeviceTokenBinding | null> {
    const data = (await this.deviceTokenDoc(tokenHash).get()).data() as
      | DeviceTokenBinding
      | undefined;
    return data?.owner && data?.site_id ? data : null;
  }

  async listTenantIds(): Promise<string[]> {
    const data = (await this.metaTenantsDoc.get()).data() as
      | TenantRegistryDoc
      | undefined;
    return data?.ids ?? [];
  }
}
