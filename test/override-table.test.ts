import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { sqliteD1 } from "./sqlite-d1.ts";
import { overrideMigration } from "./override-world.ts";

const DIR = join(import.meta.dirname, "..", "migrations");

function dbWithout(skip: (name: string) => boolean) {
  const raw = new DatabaseSync(":memory:");
  for (const f of readdirSync(DIR).filter((n) => n.endsWith(".sql")).sort()) {
    if (!skip(f)) raw.exec(readFileSync(join(DIR, f), "utf8"));
  }
  return raw;
}

describe("meeting_override migration", () => {
  it("ships as one numbered file ending in _meeting_override.sql, after the build 8 migrations", () => {
    const files = readdirSync(DIR).filter((n) => /meeting_override/.test(n));
    assert.equal(files.length, 1, "exactly one meeting_override migration");
    const m = overrideMigration();
    assert.ok(m, `${files[0]} must be NNNN_meeting_override.sql`);
    assert.ok(m.number >= 17, "0016 belongs to PR #49 (pair codes); this one is 0017 or later");
    const numbers = readdirSync(DIR).filter((n) => n.endsWith(".sql")).map((n) => n.split("_")[0]);
    assert.equal(new Set(numbers).size, numbers.length, "no two migrations share a number");
  });

  it("creates meeting_override with the agreed columns", () => {
    const { raw } = sqliteD1();
    try {
      const cols = raw.prepare("PRAGMA table_info(meeting_override)").all() as Array<{ name: string; type: string; notnull: number; pk: number; dflt_value: string | null }>;
      assert.deepEqual(cols.map((c) => c.name).sort(), [
        "end_utc", "key", "seen_end_utc", "seen_none", "seen_start_utc", "start_utc", "state", "updated_at",
      ]);
      const by = Object.fromEntries(cols.map((c) => [c.name, c]));
      assert.equal(by.key.pk, 1);
      assert.equal(by.state.notnull, 0, "state is NULL when only times or a sighting are stored");
      assert.equal(by.seen_none.notnull, 1);
      assert.equal(String(by.seen_none.dflt_value), "0");
      assert.equal(by.updated_at.notnull, 1);
      for (const c of ["start_utc", "end_utc", "seen_start_utc", "seen_end_utc"]) assert.equal(by[c].notnull, 0, c);
    } finally {
      raw.close();
    }
  });

  it("only takes the three states (or none), one row per key, and defaults seen_none to 0", () => {
    const { raw } = sqliteD1();
    try {
      const insert = (key: string, state: string | null) =>
        raw.prepare("INSERT INTO meeting_override (key, state, updated_at) VALUES (?, ?, 't')").run(key, state);
      for (const [i, s] of ["not_joined", "unlinked", "linked", null].entries()) insert(`event:ok${i}`, s);
      assert.throws(() => insert("event:bad", "excluded"), /CHECK|constraint/i);
      assert.throws(() => insert("event:bad2", ""), /CHECK|constraint/i);
      assert.throws(() => insert("event:ok0", "linked"), /UNIQUE|PRIMARY|constraint/i);
      assert.throws(() => raw.prepare("INSERT INTO meeting_override (key, state) VALUES ('event:x', NULL)").run(), /NOT NULL|constraint/i);
      assert.equal((raw.prepare("SELECT seen_none FROM meeting_override WHERE key = 'event:ok0'").get() as any).seen_none, 0);
    } finally {
      raw.close();
    }
  });

  it("changes nothing else: no new column or object on any existing table", () => {
    const without = dbWithout((f) => /meeting_override/.test(f));
    const { raw: withIt } = sqliteD1();
    try {
      const objects = (db: DatabaseSync) =>
        (db.prepare("SELECT type, name, tbl_name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").all() as Array<Record<string, string>>)
          .filter((o) => o.tbl_name !== "meeting_override" && !/meeting_override/.test(o.name));
      assert.deepEqual(objects(withIt), objects(without));
      for (const { name } of objects(without).filter((o) => o.type === "table")) {
        const cols = (db: DatabaseSync) => db.prepare(`PRAGMA table_info("${name}")`).all();
        assert.deepEqual(cols(withIt), cols(without), `table ${name} is unchanged`);
      }
    } finally {
      without.close();
      withIt.close();
    }
  });
});
