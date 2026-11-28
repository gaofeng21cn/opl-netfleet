import { DatabaseSync } from "node:sqlite";
import { Firestore } from "@google-cloud/firestore";
import type { Catalog, Change, Snapshot, Store } from "./contracts.js";

const empty = (): Catalog => ({ sites: {}, subscriptions: {} });
type Row = { data: string };

export class SqliteStore implements Store {
  private readonly db: DatabaseSync;

  constructor(path: string) {
    this.db = new DatabaseSync(path);
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA busy_timeout = 5000;
      CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, data TEXT NOT NULL);
    `);
  }

  close() {
    this.db.close();
  }

  private read<T>(id: string): T | null {
    const row = this.db
      .prepare("SELECT data FROM records WHERE id = ?")
      .get(id) as Row | undefined;
    return row ? (JSON.parse(row.data) as T) : null;
  }

  private write<T>(id: string, value: T) {
    this.db
      .prepare("INSERT OR REPLACE INTO records VALUES (?, ?)")
      .run(id, JSON.stringify(value));
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

  async catalog() {
    return this.read<Catalog>("catalog") ?? empty();
  }
  async snapshots(ids: string[]) {
    return ids.map((id) => this.read<Snapshot>(`site:${id}`));
  }

  async change<T>(fn: (catalog: Catalog) => Change<T>) {
    return this.transaction(() => {
      const catalog = this.read<Catalog>("catalog") ?? empty();
      const change = fn(catalog);
      if (change.write) this.write("catalog", catalog);
      if (change.removeSnapshot)
        this.db
          .prepare("DELETE FROM records WHERE id = ?")
          .run(`site:${change.removeSnapshot}`);
      return change.result;
    });
  }

  async heartbeat<T>(
    id: string,
    fn: (
      catalog: Catalog,
      old: Snapshot | null,
    ) => { result: T; snapshot?: Snapshot },
  ) {
    return this.transaction(() => {
      const result = fn(
        this.read<Catalog>("catalog") ?? empty(),
        this.read<Snapshot>(`site:${id}`),
      );
      if (result.snapshot) this.write(`site:${id}`, result.snapshot);
      return result.result;
    });
  }
}

export class FirestoreStore implements Store {
  constructor(private readonly db = new Firestore()) {}

  private get control() {
    return this.db.doc("netfleet/control");
  }
  private site(id: string) {
    return this.db.doc(`netfleet-sites/${id}`);
  }

  async catalog() {
    return (
      ((await this.control.get()).data() as Catalog | undefined) ?? empty()
    );
  }

  async snapshots(ids: string[]) {
    if (!ids.length) return [];
    const rows = await this.db.getAll(...ids.map((id) => this.site(id)));
    return rows.map((row) => (row.data() as Snapshot | undefined) ?? null);
  }

  async change<T>(fn: (catalog: Catalog) => Change<T>) {
    return this.db.runTransaction(async (tx) => {
      const catalog =
        ((await tx.get(this.control)).data() as Catalog | undefined) ?? empty();
      const change = fn(catalog);
      if (change.write) {
        if (
          Object.keys(catalog.sites).length ||
          Object.keys(catalog.subscriptions).length
        )
          tx.set(this.control, catalog);
        else tx.delete(this.control);
      }
      if (change.removeSnapshot) tx.delete(this.site(change.removeSnapshot));
      return change.result;
    });
  }

  async heartbeat<T>(
    id: string,
    fn: (
      catalog: Catalog,
      old: Snapshot | null,
    ) => { result: T; snapshot?: Snapshot },
  ) {
    return this.db.runTransaction(async (tx) => {
      const ref = this.site(id);
      const [control, row] = await tx.getAll(this.control, ref);
      const result = fn(
        (control.data() as Catalog | undefined) ?? empty(),
        (row.data() as Snapshot | undefined) ?? null,
      );
      if (result.snapshot) tx.set(ref, result.snapshot);
      return result.result;
    });
  }
}
