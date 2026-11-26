/**
 * Build 7, track `server`: the per-view heart-rate cost.
 *
 *  1. listScoringHr keeps computed minute averages in memory, so a repeated
 *     /api/view does not expand every stored sample with json_each again.
 *  2. GET /api/meetings/:id/hr answers with at most 600 series points.
 *  3. A pure `downsampleSeries(points, max)` does the thinning.
 *
 * What these tests assume (and nothing more):
 *  - The costly work is any SQL whose json_each() reads the samples column.
 *    Anything else (a metadata query, json_each over the ids list) is cheap.
 *  - The cache lives at module level, so a new D1 wrapper object for the same
 *    database stays warm. Two different databases never see each other's
 *    entries; the tests only check that each database gets its own correct
 *    results. They do not say how the cache is keyed.
 *  - No test calls a cache reset. Every test uses its own event ids.
 *  - `downsampleSeries` is imported from ../src/lib/downsample.ts, as
 *        import { downsampleSeries } from "../src/lib/downsample.ts"
 *    It is loaded with a dynamic import so the cache tests still run (and
 *    fail on their own assertions) before that file exists. Points are the
 *    shape the API serves: { t: ISO string, bpm: number, source?: string, ... }.
 */
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { DatabaseSync } from "node:sqlite";
import { api } from "../src/routes/api.ts";
import { WINDOW_PAD_MIN } from "../src/sources/whoop-web/constants.ts";
import { meetingHrDetail } from "../src/sources/whoop-web/fill.ts";
import { listScoringHr, putCachedHr } from "../src/sources/whoop-web/store.ts";
import { fakeKv, sqliteD1 } from "./sqlite-d1.ts";

const MIN = 60_000;
const PAD = WINDOW_PAD_MIN * MIN;
const START = Date.parse("2026-11-16T15:00:00Z");
const F0 = "2026-11-16T16:00:00.000Z";
const F1 = "2026-11-16T16:05:00.000Z";
const iso = (ms: number) => new Date(ms).toISOString();

let seq = 0;
const uid = (prefix: string) => `${prefix}-${process.pid}-${++seq}`;

// ---------------------------------------------------------------------------
// A D1 stand-in that records every statement and can fail on demand.
// ---------------------------------------------------------------------------

type Call = { sql: string; binds: unknown[]; costly: boolean };
type Ctl = {
  calls: Call[];
  failCostly: boolean;
  failAll: boolean;
  afterCostly: (() => void) | null;
};

/** json_each over the samples column: the expensive expansion. */
const isCostly = (sql: string) => /json_each\s*\([^)]*samples_json/i.test(sql);

function wrap(db: D1Database, ctl: Ctl): D1Database {
  const prepare = (sql: string) => {
    const inner = db.prepare(sql);
    const costly = isCostly(sql);
    let binds: unknown[] = [];
    const run = async <T>(fn: () => Promise<T>): Promise<T> => {
      ctl.calls.push({ sql, binds, costly });
      if (ctl.failAll || (ctl.failCostly && costly)) throw new Error("D1 DB is overloaded");
      const out = await fn();
      if (costly && ctl.afterCostly) {
        const hook = ctl.afterCostly;
        ctl.afterCostly = null;
        hook();
      }
      return out;
    };
    const w = {
      bind: (...a: unknown[]) => {
        binds = a;
        inner.bind(...a);
        return w;
      },
      first: (...a: unknown[]) => run(() => (inner.first as (...x: unknown[]) => Promise<unknown>)(...a)),
      all: (...a: unknown[]) => run(() => (inner.all as (...x: unknown[]) => Promise<unknown>)(...a)),
      run: (...a: unknown[]) => run(() => (inner.run as (...x: unknown[]) => Promise<unknown>)(...a)),
    };
    return w;
  };
  return { prepare, batch: (stmts: unknown[]) => (db.batch as (s: unknown[]) => Promise<unknown>)(stmts) } as unknown as D1Database;
}

type Harness = {
  raw: DatabaseSync;
  /** Unwrapped, for writes the test makes. */
  plain: D1Database;
  /** What the code under test reads through. */
  db: D1Database;
  ctl: Ctl;
};

function harness(): Harness {
  const d = sqliteD1();
  const ctl: Ctl = { calls: [], failCostly: false, failAll: false, afterCostly: null };
  return { raw: d.raw, plain: d.db, db: wrap(d.db, ctl), ctl };
}

/** A second D1 wrapper object over the same database, as a later request would have. */
const newWrapper = (h: Harness): D1Database => wrap(h.plain, h.ctl);

const costly = (h: Harness) => h.ctl.calls.filter((c) => c.costly);
const mark = (h: Harness) => void (h.ctl.calls.length = 0);

// ---------------------------------------------------------------------------
// Seeding and an independent oracle for what the averages must be.
// ---------------------------------------------------------------------------

type Pts = Array<[number, number]>;

function samples(from: number, to: number, stepMs: number, salt = 0, bump = 0): Pts {
  const out: Pts = [];
  for (let t = from, i = 0; t <= to; t += stepMs, i += 1) out.push([t, 60 + ((i * 7 + salt) % 23) + bump]);
  return out;
}

function insertEvent(raw: DatabaseSync, id: string, startMs: number, endMs: number) {
  raw
    .prepare(
      `INSERT INTO calendar_event (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, title, kind, attendee_count, after_hours, updated_at, start_local, end_local)
       VALUES (?, 'google', ?, ?, ?, -300, ?, 'Client review', 'client', 2, 0, 't', ?, ?)`,
    )
    .run(id, iso(startMs).slice(0, 10), iso(startMs), iso(endMs), (endMs - startMs) / 1000, iso(startMs), iso(endMs));
}

function putHr(h: Harness, id: string, pts: Pts, fetchedAt = F0, start = START, minutes = 10) {
  return putCachedHr(h.plain, {
    eventId: id,
    status: "ok",
    errorText: null,
    fetchedAt,
    points: pts,
    windowStartUtc: iso(start - PAD),
    windowEndUtc: iso(start + minutes * MIN + PAD),
  });
}

/**
 * A 10 minute meeting with a stored row. The calendar event starts 20 s after
 * the window's padded start, so the event and the window give different anchors.
 */
async function seed(h: Harness, id: string, o: { salt?: number; fetchedAt?: string; event?: boolean; shift?: number } = {}) {
  const shift = o.shift ?? 20_000;
  const end = START + 10 * MIN;
  if (o.event !== false) insertEvent(h.raw, id, START + shift, end + shift);
  await putHr(h, id, samples(START - PAD, end + PAD, 20_000, o.salt ?? 0), o.fetchedAt ?? F0);
}

type Shape = {
  eventId: string;
  windowStartUtc: string;
  windowEndUtc: string;
  status: string;
  sampleCount: number;
  errorText: string | null;
  fetchedAt: string;
  minutePoints: Array<[number, number]>;
};

function shape(r: Record<string, unknown>): Shape {
  return {
    eventId: r.eventId as string,
    windowStartUtc: r.windowStartUtc as string,
    windowEndUtc: r.windowEndUtc as string,
    status: r.status as string,
    sampleCount: r.sampleCount as number,
    errorText: (r.errorText as string | null) ?? null,
    fetchedAt: r.fetchedAt as string,
    minutePoints: (r.minutePoints as Array<[number, number]>).map(([t, b]) => [t, b]),
  };
}

const byId = (a: Shape, b: Shape) => (a.eventId < b.eventId ? -1 : a.eventId > b.eventId ? 1 : 0);

/**
 * Minute averages worked out from the raw stored row, the way the scoring
 * contract describes them: buckets anchored at the meeting start (or the
 * padded window start when the event is gone), restarted at the end, each
 * bucket stamped with its earliest reading, only for status ok. Points kept
 * outside the row's own window (window_start_utc..window_end_utc, both ends
 * inclusive) are stored but never scored.
 */
function oracle(raw: DatabaseSync, id: string): Shape | null {
  const h = raw.prepare(`SELECT * FROM whoop_web_hr WHERE event_id = ?`).get(id) as Record<string, any> | undefined;
  if (!h) return null;
  const e = raw.prepare(`SELECT start_utc, end_utc FROM calendar_event WHERE id = ?`).get(id) as Record<string, string> | undefined;
  const start = e ? Date.parse(e.start_utc) : Date.parse(h.window_start_utc) + PAD;
  const end = e ? Date.parse(e.end_utc) : Date.parse(h.window_end_utc) - PAD;
  const status = h.status === "ok" || h.status === "empty" ? h.status : "error";
  const from = Date.parse(h.window_start_utc);
  const to = Date.parse(h.window_end_utc);
  let pairs: Pts = [];
  if (h.status === "ok") {
    try {
      const v = JSON.parse(h.samples_json);
      if (Array.isArray(v)) pairs = v.filter((p) => Array.isArray(p) && Number.isFinite(p[0]) && Number.isFinite(p[1]) && p[0] >= from && p[0] <= to);
    } catch {
      pairs = [];
    }
  }
  const groups = new Map<string, { t: number; sum: number; n: number }>();
  for (const [t, bpm] of pairs) {
    const after = t >= end;
    const key = `${after}:${Math.floor((t - (after ? end : start)) / MIN)}`;
    const g = groups.get(key);
    if (g) {
      g.t = Math.min(g.t, t);
      g.sum += bpm;
      g.n += 1;
    } else groups.set(key, { t, sum: bpm, n: 1 });
  }
  return {
    eventId: id,
    windowStartUtc: h.window_start_utc,
    windowEndUtc: h.window_end_utc,
    status,
    sampleCount: h.sample_count,
    errorText: h.error_text ?? null,
    fetchedAt: h.fetched_at,
    minutePoints: [...groups.values()].sort((a, b) => a.t - b.t).map((g) => [g.t, g.sum / g.n]),
  };
}

const oracleAll = (raw: DatabaseSync, ids: string[]) => ids.map((id) => oracle(raw, id)).filter((x): x is Shape => x !== null).sort(byId);

async function read(db: D1Database, ids: string[]): Promise<Shape[]> {
  return (await listScoringHr(db, ids) as unknown as Array<Record<string, unknown>>).map(shape).sort(byId);
}

// ---------------------------------------------------------------------------
// 1. listScoringHr cache
// ---------------------------------------------------------------------------

describe("listScoringHr: repeated reads do not expand the samples again", () => {
  it("serves a repeat read from memory with the same answer as the first read", async () => {
    const h = harness();
    const ids = ["a", "b", "c"].map((s) => uid(`rep-${s}`));
    for (const [i, id] of ids.entries()) await seed(h, id, { salt: i * 3 });

    const first = await read(h.db, ids);
    assert.ok(costly(h).length > 0, "the cold read has to expand the samples (this also proves the spy sees it)");
    assert.deepEqual(first, oracleAll(h.raw, ids), "cold answer matches the stored data");
    assert.ok(first.every((r) => r.minutePoints.length > 0));

    mark(h);
    for (let i = 0; i < 3; i += 1) {
      assert.deepEqual(await read(h.db, ids), first, `repeat ${i + 1} is identical to the first read`);
    }
    assert.equal(costly(h).length, 0, "no json_each over samples on repeat reads");
  });

  it("a subset of warm ids is also served from memory", async () => {
    const h = harness();
    const ids = ["a", "b", "c"].map((s) => uid(`sub-${s}`));
    for (const id of ids) await seed(h, id);
    await read(h.db, ids);
    mark(h);
    assert.deepEqual(await read(h.db, [ids[2], ids[0]]), oracleAll(h.raw, [ids[2], ids[0]]));
    assert.equal(costly(h).length, 0);
  });

  it("runs no query at all for no ids", async () => {
    const h = harness();
    assert.deepEqual(await listScoringHr(h.db, []), []);
    assert.equal(h.ctl.calls.length, 0);
  });

  it("ids with no stored row are absent, and show up once they are stored (absence is not cached)", async () => {
    const h = harness();
    const a = uid("known");
    const later = uid("later");
    await seed(h, a);
    assert.deepEqual(await read(h.db, [a, later]), oracleAll(h.raw, [a]));
    assert.deepEqual(await read(h.db, [a, later]), oracleAll(h.raw, [a]));
    await seed(h, later, { salt: 4 });
    const after = await read(h.db, [a, later]);
    assert.equal(after.length, 2);
    assert.deepEqual(after, oracleAll(h.raw, [a, later]));
  });

  it("stays warm for a new D1 wrapper object over the same database (a later request)", async () => {
    const h = harness();
    const ids = ["a", "b"].map((s) => uid(`wrap-${s}`));
    for (const id of ids) await seed(h, id);
    const first = await read(h.db, ids);
    mark(h);
    for (let i = 0; i < 3; i += 1) {
      assert.deepEqual(await read(newWrapper(h), ids), first);
    }
    assert.equal(costly(h).length, 0, "a new wrapper object must not throw the cache away");
  });

  it("callers can change what they get back without changing what the next caller gets", async () => {
    const h = harness();
    const id = uid("alias");
    await seed(h, id);
    const warm = await listScoringHr(h.db, [id]);
    const before = oracleAll(h.raw, [id]);
    mark(h);
    const [row] = await listScoringHr(h.db, [id]);
    assert.equal(costly(h).length, 0, "precondition: the second read comes from memory");
    (row.minutePoints as Pts).push([1, 1]);
    (row.minutePoints as Pts).reverse();
    (row as { status: string }).status = "error";
    (warm[0].minutePoints as Pts).length = 0;
    assert.deepEqual(await read(h.db, [id]), before);
  });

  it("two readers at once on a cold cache both get the right answer", async () => {
    const h = harness();
    const ids = ["a", "b", "c"].map((s) => uid(`conc-${s}`));
    for (const id of ids) await seed(h, id);
    const [x, y] = await Promise.all([read(h.db, ids), read(newWrapper(h), ids)]);
    const want = oracleAll(h.raw, ids);
    assert.deepEqual(x, want);
    assert.deepEqual(y, want);
  });
});

describe("listScoringHr: anything that changes the stored row or its meeting is a miss", () => {
  type Change = {
    name: string;
    seedOpts?: { event?: boolean };
    /** The answer must be different afterwards (guards the test data, not the code). */
    differs: boolean;
    apply: (h: Harness, id: string) => void | Promise<void>;
  };
  const sql = (h: Harness, q: string, ...args: Array<string | number>) => void h.raw.prepare(q).run(...args);
  const end = START + 10 * MIN;
  const changes: Change[] = [
    {
      name: "a new projection with more points",
      differs: true,
      // The window grows with the points: points outside a row's window are never scored.
      apply: (h, id) => putHr(h, id, samples(START - PAD, end + PAD + 10 * MIN, 20_000), F1, START, 20),
    },
    {
      name: "a new projection with the same number of points but other values",
      differs: true,
      apply: (h, id) => putHr(h, id, samples(START - PAD, end + PAD, 20_000, 5), F1),
    },
    {
      name: "values that change in the same millisecond with the same count (fetched_at and count unchanged)",
      differs: true,
      apply: (h, id) =>
        sql(
          h,
          `UPDATE whoop_web_hr SET samples_json = ? WHERE event_id = ?`,
          JSON.stringify(samples(START - PAD, end + PAD, 20_000, 0, 50)),
          id,
        ),
    },
    {
      name: "only fetched_at",
      differs: true,
      apply: (h, id) => sql(h, `UPDATE whoop_web_hr SET fetched_at = ? WHERE event_id = ?`, F1, id),
    },
    {
      name: "only sample_count",
      differs: true,
      apply: (h, id) => sql(h, `UPDATE whoop_web_hr SET sample_count = sample_count + 1 WHERE event_id = ?`, id),
    },
    {
      name: "a moved meeting: the calendar start changed",
      differs: true,
      apply: (h, id) => sql(h, `UPDATE calendar_event SET start_utc = ? WHERE id = ?`, iso(START + 50_000), id),
    },
    {
      name: "a moved meeting: the calendar end changed",
      differs: true,
      apply: (h, id) => sql(h, `UPDATE calendar_event SET end_utc = ? WHERE id = ?`, iso(end + 20_000 + 3 * MIN + 25_000), id),
    },
    {
      name: "the calendar event removed (anchors fall back to the window)",
      differs: true,
      apply: (h, id) => sql(h, `DELETE FROM calendar_event WHERE id = ?`, id),
    },
    {
      name: "a status change",
      differs: true,
      apply: (h, id) => sql(h, `UPDATE whoop_web_hr SET status = 'error' WHERE event_id = ?`, id),
    },
    {
      name: "a window end change",
      differs: true,
      apply: (h, id) => sql(h, `UPDATE whoop_web_hr SET window_end_utc = ? WHERE event_id = ?`, iso(end + PAD + MIN), id),
    },
    {
      name: "a window start change when there is no calendar event to anchor on",
      seedOpts: { event: false },
      differs: true,
      apply: (h, id) => sql(h, `UPDATE whoop_web_hr SET window_start_utc = ? WHERE event_id = ?`, iso(START - PAD + 20_000), id),
    },
  ];

  for (const change of changes) {
    it(`${change.name}: warm before, correct and recomputed after, and only for that meeting`, async () => {
      const h = harness();
      const [a, b, c] = ["a", "b", "c"].map((s) => uid(`chg-${s}`));
      for (const [i, id] of [a, b, c].entries()) await seed(h, id, { salt: i * 2, ...change.seedOpts });

      const warm = await read(h.db, [a, b, c]);
      mark(h);
      assert.deepEqual(await read(h.db, [a, b, c]), warm);
      assert.equal(costly(h).length, 0, "precondition: the cache is warm before the change");

      await change.apply(h, b);
      mark(h);
      const after = await read(h.db, [a, b, c]);
      assert.deepEqual(after, oracleAll(h.raw, [a, b, c]), "the answer reflects the change");
      if (change.differs) {
        assert.notDeepEqual(after.find((r) => r.eventId === b), warm.find((r) => r.eventId === b), "test data: the change must be visible");
      }
      assert.deepEqual(after.find((r) => r.eventId === a), warm.find((r) => r.eventId === a));
      assert.deepEqual(after.find((r) => r.eventId === c), warm.find((r) => r.eventId === c));

      const runs = costly(h);
      assert.ok(runs.length > 0, "the changed meeting is recomputed");
      const bound = JSON.stringify(runs.map((r) => r.binds));
      assert.ok(!bound.includes(a) && !bound.includes(c), "unchanged meetings are not recomputed");

      mark(h);
      assert.deepEqual(await read(h.db, [a, b, c]), after);
      assert.equal(costly(h).length, 0, "and the recomputed answer is cached in turn");
    });
  }

  it("a live meeting: every new projection shows up at once, and an unchanged poll costs nothing", async () => {
    const h = harness();
    const id = uid("live");
    insertEvent(h.raw, id, START, START + 30 * MIN);
    const all = samples(START - PAD, START + 30 * MIN, 5_000);
    for (let n = 40; n <= all.length; n += 60) {
      // Same fetched_at on every write: two projections in one millisecond.
      await putHr(h, id, all.slice(0, n), F0, START, 30);
      assert.deepEqual(await read(h.db, [id]), oracleAll(h.raw, [id]), `after ${n} points`);
      mark(h);
      assert.deepEqual(await read(h.db, [id]), oracleAll(h.raw, [id]));
      assert.equal(costly(h).length, 0, `unchanged poll at ${n} points`);
    }
  });

  it("a row that is rewritten right after its averages were computed is never served stale", async () => {
    for (const variant of ["same count, new values", "more points"] as const) {
      const h = harness();
      const id = uid("race");
      await seed(h, id);
      h.ctl.afterCostly = () => {
        const end = START + 10 * MIN;
        void putHr(
          h,
          id,
          // "More points" adds readings between the old ones, inside the same window,
          // so only the points change (an added point outside the window would not be scored).
          variant === "more points"
            ? [...samples(START - PAD, end + PAD, 20_000), ...samples(START - PAD + 10_000, end + PAD, 20_000, 3)].sort((a, b) => a[0] - b[0])
            : samples(START - PAD, end + PAD, 20_000, 9),
          F1,
        );
      };
      await listScoringHr(h.db, [id]).catch(() => null);
      assert.equal(h.ctl.afterCostly, null, `precondition (${variant}): the rewrite happened during the read`);
      assert.deepEqual(await read(h.db, [id]), oracleAll(h.raw, [id]), variant);
      mark(h);
      assert.deepEqual(await read(h.db, [id]), oracleAll(h.raw, [id]), `${variant}, again`);
      assert.deepEqual(await read(h.db, [id]), oracleAll(h.raw, [id]), `${variant}, a third time`);
      assert.ok(costly(h).length <= 1, `${variant}: at most one recompute, then served from memory`);
    }
  });
});

describe("listScoringHr: points kept outside the row's own window", () => {
  const minutePoints = async (h: Harness, id: string) => (await read(h.db, [id]))[0]?.minutePoints;

  it("a row with points outside its window scores exactly like the same row without them, and a changed window brings them in", async () => {
    const h = harness();
    const [plain, extra] = [uid("out-plain"), uid("out-extra")];
    const end = START + 10 * MIN;
    const inside = samples(START - PAD, end + PAD, 20_000, 4);
    // Before the window, after it, and the two readings one ms outside the edges.
    const outside: Pts = [
      [START - PAD - 10 * MIN, 140],
      [START - PAD - 1, 150],
      [end + PAD + 1, 151],
      [end + PAD + 8 * MIN, 145],
      [end + PAD + 9 * MIN, 99],
    ];
    for (const id of [plain, extra]) insertEvent(h.raw, id, START + 20_000, end + 20_000);
    await putHr(h, plain, inside);
    await putHr(h, extra, [...outside.slice(0, 2), ...inside, ...outside.slice(2)]);

    const stored = JSON.parse((h.raw.prepare(`SELECT samples_json FROM whoop_web_hr WHERE event_id = ?`).get(extra) as { samples_json: string }).samples_json);
    assert.equal(stored.length, inside.length + outside.length, "precondition: the outside points are stored");

    const want = await minutePoints(h, plain);
    assert.ok(want && want.length > 5, "precondition: there is something to score");
    assert.deepEqual(await minutePoints(h, extra), want, "outside points are not scored");
    assert.deepEqual(await minutePoints(h, extra), want, "and again, from memory");
    assert.deepEqual(await read(h.db, [extra]), oracleAll(h.raw, [extra]));

    // Both edges are inclusive.
    const edges = harness();
    const edgeId = uid("out-edge");
    insertEvent(edges.raw, edgeId, START, end);
    await putHr(edges, edgeId, [[START - PAD, 70], [START + MIN, 80], [end + PAD, 90], [START - PAD - 1, 200], [end + PAD + 1, 201]]);
    const flat = (await minutePoints(edges, edgeId))!.flat();
    assert.ok(flat.includes(START - PAD) && flat.includes(end + PAD), "points exactly on the window edges are scored");
    assert.ok(!flat.includes(START - PAD - 1) && !flat.includes(end + PAD + 1), "points one ms outside are not");

    // Widen the window: the kept points count at once, with no other change to the row.
    h.raw
      .prepare(`UPDATE whoop_web_hr SET window_start_utc = ?, window_end_utc = ? WHERE event_id = ?`)
      .run(iso(START - PAD - 10 * MIN), iso(end + PAD + 9 * MIN), extra);
    const widened = await minutePoints(h, extra);
    assert.notDeepEqual(widened, want, "a changed window is a cache miss and brings the kept points in");
    assert.ok(widened!.flat().includes(end + PAD + 8 * MIN), "a later kept point is scored now");
    assert.deepEqual(await read(h.db, [extra]), oracleAll(h.raw, [extra]));

    // The same points all stored inside one window score the same as the widened row.
    const whole = uid("out-whole");
    insertEvent(h.raw, whole, START + 20_000, end + 20_000);
    await putHr(h, whole, [...outside.slice(0, 2), ...inside, ...outside.slice(2)], F0, START - 10 * MIN, 30);
    h.raw
      .prepare(`UPDATE whoop_web_hr SET window_start_utc = ?, window_end_utc = ? WHERE event_id = ?`)
      .run(iso(START - PAD - 10 * MIN), iso(end + PAD + 9 * MIN), whole);
    assert.deepEqual(await minutePoints(h, whole), widened);
  });
});

describe("listScoringHr: failures and isolation", () => {
  it("a failed aggregate is not cached: the next read recomputes and is right", async () => {
    const h = harness();
    const ids = ["a", "b"].map((s) => uid(`fail-${s}`));
    for (const id of ids) await seed(h, id);
    h.ctl.failCostly = true;
    await listScoringHr(h.db, ids).catch(() => null);
    h.ctl.failCostly = false;
    mark(h);
    assert.deepEqual(await read(h.db, ids), oracleAll(h.raw, ids));
    assert.ok(costly(h).length > 0, "nothing was stored by the failed run");
    mark(h);
    assert.deepEqual(await read(h.db, ids), oracleAll(h.raw, ids));
    assert.equal(costly(h).length, 0);
  });

  it("any failed query leaves nothing behind, cold or warm", async () => {
    const h = harness();
    const [a, b] = ["a", "b"].map((s) => uid(`fail2-${s}`));
    await seed(h, a);
    await seed(h, b);
    await read(h.db, [a]);
    h.ctl.failAll = true;
    await listScoringHr(h.db, [a, b]).catch(() => null);
    h.ctl.failAll = false;
    assert.deepEqual(await read(h.db, [a, b]), oracleAll(h.raw, [a, b]));
    mark(h);
    assert.deepEqual(await read(h.db, [a, b]), oracleAll(h.raw, [a, b]));
    assert.equal(costly(h).length, 0);
  });

  it("missing tables still read as nothing stored", async () => {
    const h = harness();
    const id = uid("notable");
    await seed(h, id);
    await read(h.db, [id]);
    h.raw.exec("DROP TABLE whoop_web_hr");
    assert.deepEqual(await listScoringHr(h.db, [id]), []);
  });

  it("two databases with the same event id each get their own correct answer, in any order", async () => {
    const id = uid("shared");
    const dbs = [harness(), harness(), harness()];
    // 0 and 1: same event id, different data and different fetch time. 2: the event exists but has no stored heart rate.
    await seed(dbs[0], id, { salt: 0, fetchedAt: F0 });
    await seed(dbs[1], id, { salt: 11, fetchedAt: F1 });
    insertEvent(dbs[2].raw, id, START, START + 10 * MIN);
    assert.notDeepEqual(oracle(dbs[0].raw, id)?.minutePoints, oracle(dbs[1].raw, id)?.minutePoints, "test data differs");
    for (const order of [[0, 1, 2], [2, 1, 0], [1, 0, 2, 0, 1, 2]]) {
      for (const i of order) {
        assert.deepEqual(await read(dbs[i].db, [id]), oracleAll(dbs[i].raw, [id]), `database ${i}`);
      }
    }
    // Each database is served from memory on its own repeat, too.
    await read(dbs[0].db, [id]);
    mark(dbs[0]);
    await read(dbs[0].db, [id]);
    assert.equal(costly(dbs[0]).length, 0, "precondition: a repeat read of one database is warm");
  });

  it("is bounded: a very large number of distinct meetings cannot all stay in memory, and the newest do", async () => {
    const h = harness();
    const N = 2500;
    const ids = Array.from({ length: N }, (_, i) => uid(`bound${i}`));
    h.raw.exec("BEGIN");
    const ins = h.raw.prepare(
      `INSERT INTO whoop_web_hr (event_id, window_start_utc, window_end_utc, status, sample_count, samples_json, error_text, fetched_at)
       VALUES (?, ?, ?, 'ok', 3, ?, NULL, ?)`,
    );
    for (const [i, id] of ids.entries()) {
      const s = START + i * MIN;
      ins.run(id, iso(s - PAD), iso(s + 10 * MIN + PAD), JSON.stringify([[s, 60 + (i % 20)], [s + 20_000, 61], [s + 70_000, 62]]), F0);
    }
    h.raw.exec("COMMIT");

    const pass = async () => {
      const out: Shape[] = [];
      for (let i = 0; i < N; i += 250) out.push(...(await read(h.db, ids.slice(i, i + 250))));
      return out;
    };
    assert.deepEqual((await pass()).sort(byId), oracleAll(h.raw, ids));

    mark(h);
    const newest = ids.slice(-10);
    assert.deepEqual(await read(h.db, newest), oracleAll(h.raw, newest));
    assert.equal(costly(h).length, 0, "the most recently computed entries are still there");

    mark(h);
    assert.deepEqual((await pass()).sort(byId), oracleAll(h.raw, ids));
    assert.ok(costly(h).length > 0, "a cache that never drops anything would answer every one of these from memory");
  });
});

// ---------------------------------------------------------------------------
// 2. GET /api/meetings/:id/hr
// ---------------------------------------------------------------------------

function workerEnv() {
  const d = sqliteD1();
  const env = { DB: d.db, TOKENS: fakeKv(), WEARABLE: "whoop", WHOOP_WEB_HR: "enabled", INGEST_ADMIN_SECRET: "admin-secret-xyz" };
  return { env, raw: d.raw };
}

async function storeMeeting(env: ReturnType<typeof workerEnv>["env"], raw: DatabaseSync, id: string, minutes: number, stepMs: number) {
  const start = START;
  const end = start + minutes * MIN;
  insertEvent(raw, id, start, end);
  const pts: Pts = [];
  const from = start - PAD;
  const to = end + PAD;
  const count = Math.floor((to - from) / stepMs) + 1;
  // Noise 70..78, one unique peak and one unique dip inside the meeting.
  for (let i = 0; i < count; i += 1) pts.push([from + i * stepMs, 70 + ((i * 7) % 9)]);
  const mid = Math.floor(count / 2);
  pts[mid] = [pts[mid][0], 151];
  pts[Math.floor(count / 3)] = [pts[Math.floor(count / 3)][0], 41];
  await putCachedHr(env.DB, {
    eventId: id,
    status: "ok",
    errorText: null,
    fetchedAt: iso(to + 60_000),
    points: pts,
    windowStartUtc: iso(from),
    windowEndUtc: iso(to),
  });
  return pts;
}

async function getHr(env: ReturnType<typeof workerEnv>["env"], id: string) {
  await env.TOKENS.put("settings:source_display:whoop", "true");
  const res = await api.request(`https://app.example/meetings/${id}/hr?fill=0`, {}, env as never);
  const text = await res.text();
  return { status: res.status, text, body: JSON.parse(text) as Record<string, any> };
}

describe("GET /api/meetings/:id/hr: at most 600 series points", () => {
  const withoutSeries = (v: Record<string, any>) => ({ ...v, series: undefined });

  for (const [label, minutes, stepMs] of [
    ["an hour at one reading per second", 60, 1000],
    ["a 4.5 hour meeting at two readings per second", 270, 500],
  ] as const) {
    it(`${label}: thinned to 600 or fewer, keeping first, last, min and max, scoring unchanged`, async () => {
      const { env, raw } = workerEnv();
      const pts = await storeMeeting(env, raw, "m1", minutes, stepMs);
      assert.ok(pts.length > 4000);

      const full = await meetingHrDetail(env, "m1", { fill: false });
      assert.ok(full);
      assert.equal(full.hrStress.coverage, "ok");

      const r = await getHr(env, "m1");
      assert.equal(r.status, 200);
      const series = r.body.series as Array<{ t: string; bpm: number }>;
      assert.ok(series.length <= 600, `got ${series.length} points`);
      assert.ok(series.length >= 4, "still a usable chart");

      const bpmAt = new Map(pts.map(([t, bpm]) => [iso(t), bpm]));
      for (const p of series) assert.equal(bpmAt.get(p.t), p.bpm, `${p.t} is a real stored reading`);
      for (let i = 1; i < series.length; i += 1) assert.ok(series[i - 1].t < series[i].t, "in time order");
      assert.equal(series[0].t, iso(pts[0][0]), "first reading kept");
      assert.equal(series.at(-1)!.t, iso(pts.at(-1)![0]), "last reading kept");
      assert.equal(Math.max(...series.map((p) => p.bpm)), 151, "the peak survives");
      assert.equal(Math.min(...series.map((p) => p.bpm)), 41, "the dip survives");

      assert.equal(r.body.hrStress.sampleCount, full.hrStress.sampleCount);
      assert.equal(r.body.hrStress.maxBpm, full.hrStress.maxBpm);
      assert.equal(r.body.hrStress.meanBpm, full.hrStress.meanBpm);
      assert.equal(r.body.hrStress.coverage, full.hrStress.coverage);
      assert.deepEqual(r.body.hrStress.partial, full.hrStress.partial);
      assert.deepEqual(withoutSeries(r.body.hrStress), withoutSeries(full.hrStress), "every scoring number comes from the full data");
      if (minutes === 60) assert.equal(r.body.hrStress.sampleCount, 60);

      assert.ok(r.text.length < 250_000, `answer is ${r.text.length} bytes`);
    });
  }

  it("a short series is returned as stored", async () => {
    const { env, raw } = workerEnv();
    const pts = await storeMeeting(env, raw, "m1", 60, 12_000);
    assert.ok(pts.length > 300 && pts.length <= 600);
    const r = await getHr(env, "m1");
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.series, pts.map(([t, bpm]) => ({ t: iso(t), bpm })));
  });
});

// ---------------------------------------------------------------------------
// 3. downsampleSeries
// ---------------------------------------------------------------------------

type Pt = { t: string; bpm: number; source?: string; [k: string]: unknown };
type Downsample = (points: Pt[], max: number) => Pt[];

async function loadDownsample(): Promise<Downsample> {
  const mod = (await import("../src/lib/downsample.ts")) as { downsampleSeries?: unknown };
  assert.equal(typeof mod.downsampleSeries, "function", "src/lib/downsample.ts exports downsampleSeries(points, max)");
  return mod.downsampleSeries as Downsample;
}

/** The output is a subset of the input, in the same order, with every kept point untouched. */
function assertSubsetInOrder(input: Pt[], output: Pt[]) {
  const index = new Map(input.map((p, i) => [p.t, i]));
  assert.equal(index.size, input.length, "test data: unique timestamps");
  let last = -1;
  for (const o of output) {
    const i = index.get(o.t);
    assert.notEqual(i, undefined, `${o.t} is not in the input`);
    assert.ok(i! > last, "strictly increasing positions in the input");
    assert.deepEqual(o, input[i!], "kept point is untouched");
    last = i!;
  }
}

const T0 = Date.parse("2026-11-16T15:00:00Z");

function plain(n: number, stepMs = 1000, bpm = (i: number) => 60 + ((i * 7) % 11)): Pt[] {
  return Array.from({ length: n }, (_, i) => ({ t: iso(T0 + i * stepMs), bpm: bpm(i), minutes: i }));
}

type Seg = { n: number; step: number; source?: string; level: number };

/**
 * Runs of points. Between runs the time difference is `joinMs`. Each run
 * (6 or more points) has a unique low at index 2 and a unique high at n-3,
 * both close to its edges, so merging a run's edge into a neighbour loses them.
 */
function runs(segs: Seg[], joinMs: number) {
  const points: Pt[] = [];
  const segments: Pt[][] = [];
  let t = T0;
  for (const [s, seg] of segs.entries()) {
    const mine: Pt[] = [];
    for (let i = 0; i < seg.n; i += 1) {
      if (i === 0 && s > 0) t += joinMs;
      else if (i > 0) t += seg.step;
      let bpm = seg.level + ((i * 37) % 6);
      if (seg.n >= 6 && i === 2) bpm = seg.level - 30;
      if (seg.n >= 6 && i === seg.n - 3) bpm = seg.level + 40;
      const p: Pt = { t: iso(t), bpm, ...(seg.source ? { source: seg.source } : {}), minutes: i };
      mine.push(p);
      points.push(p);
    }
    segments.push(mine);
  }
  return { points, segments };
}

const lowOf = (seg: Pt[]) => seg.reduce((m, p) => (p.bpm < m.bpm ? p : m));
const highOf = (seg: Pt[]) => seg.reduce((m, p) => (p.bpm > m.bpm ? p : m));

function assertSegmentExtremesKept(segments: Pt[][], out: Pt[]) {
  const kept = new Set(out.map((p) => p.t));
  for (const [i, seg] of segments.entries()) {
    if (seg.length < 2) continue;
    assert.ok(kept.has(lowOf(seg).t), `segment ${i}: its lowest reading was merged away`);
    assert.ok(kept.has(highOf(seg).t), `segment ${i}: its highest reading was merged away`);
  }
}

describe("downsampleSeries (src/lib/downsample.ts)", () => {
  it("returns the input unchanged when it already fits", async () => {
    const ds = await loadDownsample();
    for (const n of [0, 1, 2, 599, 600]) {
      const input = plain(n);
      const copy = structuredClone(input);
      assert.deepEqual(ds(input, 600), copy, `${n} points`);
    }
    const small = plain(50);
    assert.deepEqual(ds(small, 50), small);
  });

  it("brings anything longer down to the limit, as an untouched ordered subset, with first and last kept", async () => {
    const ds = await loadDownsample();
    for (const n of [601, 700, 1200, 4801, 33_135]) {
      const input = plain(n, 500);
      const out = ds(input, 600);
      assert.ok(out.length <= 600, `${n} in, ${out.length} out`);
      assert.ok(out.length >= 100, `${n} in, only ${out.length} out: still a chart`);
      assertSubsetInOrder(input, out);
      assert.deepEqual(out[0], input[0]);
      assert.deepEqual(out.at(-1), input.at(-1));
    }
  });

  it("honors a different limit", async () => {
    const ds = await loadDownsample();
    const input = plain(5000);
    input[1234].bpm = 200;
    input[3456].bpm = 20;
    const out = ds(input, 100);
    assert.ok(out.length <= 100);
    assertSubsetInOrder(input, out);
    assert.deepEqual(out[0], input[0]);
    assert.deepEqual(out.at(-1), input.at(-1));
    assert.equal(Math.max(...out.map((p) => p.bpm)), 200);
    assert.equal(Math.min(...out.map((p) => p.bpm)), 20);
  });

  it("keeps the overall highest and lowest bpm, and isolated spikes and dips", async () => {
    const ds = await loadDownsample();
    const input = plain(5000, 1000, (i) => 60 + ((i * 7) % 11));
    const spikes = [[700, 171], [1900, 172], [3100, 173], [4300, 190]];
    const dips = [[1300, 41], [2500, 42], [3700, 30]];
    for (const [i, v] of [...spikes, ...dips]) input[i].bpm = v;
    const out = ds(input, 600);
    assert.ok(out.length <= 600);
    assertSubsetInOrder(input, out);
    const kept = new Set(out.map((p) => p.t));
    for (const [i] of [...spikes, ...dips]) assert.ok(kept.has(input[i].t), `reading ${i} (${input[i].bpm} bpm) was dropped`);
    assert.equal(Math.max(...out.map((p) => p.bpm)), 190);
    assert.equal(Math.min(...out.map((p) => p.bpm)), 30);
  });

  it("copes with readings that are bunched in time", async () => {
    const ds = await loadDownsample();
    const input: Pt[] = [];
    let t = T0;
    for (let i = 0; i < 5000; i += 1, t += 1000) input.push({ t: iso(t), bpm: 70 + (i % 7) });
    for (let i = 0; i < 100; i += 1, t += 300_000) input.push({ t: iso(t), bpm: 90 + (i % 5) });
    input[2500].bpm = 33;
    input[5050].bpm = 144;
    const out = ds(input, 600);
    assert.ok(out.length <= 600);
    assertSubsetInOrder(input, out);
    assert.deepEqual(out[0], input[0]);
    assert.deepEqual(out.at(-1), input.at(-1));
    assert.equal(Math.min(...out.map((p) => p.bpm)), 33);
    assert.equal(Math.max(...out.map((p) => p.bpm)), 144);
  });

  it("does not change its input and gives the same answer twice", async () => {
    const ds = await loadDownsample();
    const input = plain(3000);
    const before = JSON.stringify(input);
    const a = ds(input, 600);
    const b = ds(input, 600);
    assert.equal(JSON.stringify(input), before);
    assert.deepEqual(a, b);
  });

  it("keeps each stretch's own lowest and highest across a gap of more than 180 s between WHOOP points", async () => {
    const ds = await loadDownsample();
    const { points, segments } = runs(
      [{ n: 3000, step: 30_000, source: "WHOOP", level: 60 }, { n: 3000, step: 30_000, source: "WHOOP", level: 120 }],
      200_000,
    );
    const out = ds(points, 600);
    assert.ok(out.length <= 600);
    assertSubsetInOrder(points, out);
    assertSegmentExtremesKept(segments, out);
  });

  it("keeps each stretch's own lowest and highest across a gap of more than 600 s (no provider named, and Oura)", async () => {
    const ds = await loadDownsample();
    for (const source of [undefined, "Oura"]) {
      const { points, segments } = runs(
        [{ n: 3000, step: 60_000, source, level: 60 }, { n: 3000, step: 60_000, source, level: 120 }, { n: 3000, step: 60_000, source, level: 80 }],
        700_000,
      );
      const out = ds(points, 600);
      assert.ok(out.length <= 600, String(source));
      assertSubsetInOrder(points, out);
      assertSegmentExtremesKept(segments, out);
    }
  });

  it("never merges across a provider change", async () => {
    const ds = await loadDownsample();
    const { points, segments } = runs(
      [
        { n: 1500, step: 30_000, source: "WHOOP", level: 60 },
        { n: 1500, step: 30_000, source: "Oura", level: 120 },
        { n: 1500, step: 30_000, source: "WHOOP", level: 80 },
      ],
      30_000,
    );
    const out = ds(points, 600);
    assert.ok(out.length <= 600);
    assertSubsetInOrder(points, out);
    assertSegmentExtremesKept(segments, out);
    const position = new Map(points.map((p, i) => [p.t, i]));
    for (let i = 1; i < out.length; i += 1) {
      const a = position.get(out[i - 1].t)!;
      const b = position.get(out[i].t)!;
      if (out[i - 1].source === out[i].source) {
        assert.ok(points.slice(a, b + 1).every((p) => p.source === out[i].source), "two kept readings from one provider with the other provider's readings between them");
      }
    }
  });

  it("keeps a lone reading that sits between two gaps or inside another provider's run", async () => {
    const ds = await loadDownsample();
    const gapped = runs(
      [{ n: 3000, step: 30_000, source: "WHOOP", level: 60 }, { n: 1, step: 30_000, source: "WHOOP", level: 100 }, { n: 3000, step: 30_000, source: "WHOOP", level: 70 }],
      200_000,
    );
    const lone = gapped.segments[1][0];
    assert.ok(ds(gapped.points, 600).some((p) => p.t === lone.t), "isolated by gaps");

    const mixed = runs(
      [{ n: 3000, step: 30_000, source: "WHOOP", level: 60 }, { n: 1, step: 30_000, source: "Oura", level: 100 }, { n: 3000, step: 30_000, source: "WHOOP", level: 70 }],
      30_000,
    );
    const oura = mixed.segments[1][0];
    assert.ok(ds(mixed.points, 600).some((p) => p.t === oura.t), "inside another provider's run");
  });

  it("stays within the limit even when every reading is its own gap or its own provider run", async () => {
    const ds = await loadDownsample();
    const gaps = plain(3000, 3_600_000);
    const alternating = plain(3000, 30_000).map((p, i) => ({ ...p, source: i % 2 ? "Oura" : "WHOOP" }));
    for (const input of [gaps, alternating]) {
      const out = ds(input, 600);
      assert.ok(out.length <= 600, `${out.length} points`);
      assert.ok(out.length >= 2);
      assertSubsetInOrder(input, out);
      assert.deepEqual(out[0], input[0]);
      assert.deepEqual(out.at(-1), input.at(-1));
    }
  });
});
