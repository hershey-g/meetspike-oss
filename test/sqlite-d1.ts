import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

/**
 * A real SQLite database behind the small slice of the D1 API the Worker
 * uses (prepare/bind/first/all/run/batch), with every migration applied.
 */
export function sqliteD1(
  opts: { before?: string; seed?: (raw: DatabaseSync) => void } = {},
): { db: D1Database; raw: DatabaseSync } {
  const raw = new DatabaseSync(":memory:");
  const dir = join(import.meta.dirname, "..", "migrations");
  let seeded = false;
  for (const f of readdirSync(dir).filter((n) => n.endsWith(".sql")).sort()) {
    // `before`/`seed`: write rows as an older release would have, then run the newer migrations.
    if (opts.before && opts.seed && !seeded && f >= opts.before) {
      opts.seed(raw);
      seeded = true;
    }
    raw.exec(readFileSync(join(dir, f), "utf8"));
  }
  const norm = (a: unknown) => (a === undefined ? null : typeof a === "boolean" ? (a ? 1 : 0) : a);
  const prepare = (sql: string) => {
    let args: unknown[] = [];
    const stmt = {
      bind: (...a: unknown[]) => ((args = a.map(norm)), stmt),
      first: async <T>() => ((raw.prepare(sql).get(...(args as never[])) as T) ?? null),
      all: async <T>() => ({ results: raw.prepare(sql).all(...(args as never[])) as T[], success: true }),
      run: async () => {
        const r = raw.prepare(sql).run(...(args as never[]));
        return { success: true, meta: { changes: Number(r.changes) } };
      },
    };
    return stmt;
  };
  const db = {
    prepare,
    batch: async (stmts: Array<{ all: () => Promise<unknown> }>) => {
      const out = [];
      for (const s of stmts) out.push(await s.all());
      return out;
    },
  };
  return { db: db as unknown as D1Database, raw };
}

export function fakeKv(initial: Record<string, string> = {}) {
  const store = new Map(Object.entries(initial));
  return {
    store,
    get: async (k: string) => store.get(k) ?? null,
    put: async (k: string, v: string) => void store.set(k, v),
    delete: async (k: string) => void store.delete(k),
  };
}
