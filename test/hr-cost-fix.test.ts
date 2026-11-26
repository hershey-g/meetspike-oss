/**
 * Build 7 fix pass, track `server`: projectRawHr must move fetched_at forward
 * whenever it changes a stored row, so the scoring cache (validator in
 * store.ts) never serves old minute averages after a late ingest.
 *
 * The bug: the ON CONFLICT update used MAX(existing, excluded) for fetched_at.
 * A late ingest with an equal or older fetchedAt rewrote samples_json (same
 * length, same tail, same count when a bpm changes from 60 to 95) and left
 * fetched_at alone, so listScoringHr kept answering from memory.
 *
 * Required: when excluded.fetched_at is newer use it, otherwise the existing
 * value plus 1 ms, in the shape YYYY-MM-DDTHH:MM:SS.mmmZ. Rows whose content
 * did not change are not written at all.
 *
 * Every test uses its own event id. The cache is module level, so the tests
 * call resetScoringHrCache() only to compute the true answer for comparison.
 *
 * Which tests are guards that pass on the old code: "a newer fetchedAt is
 * used as is", "an identical re-projection changes nothing", and the warm
 * read assertions before the rewrite. The rest fail today.
 */
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { DatabaseSync } from "node:sqlite";
import { WINDOW_PAD_MIN } from "../src/sources/whoop-web/constants.ts";
import { projectRawHr, storeRawHr } from "../src/sources/whoop-web/raw.ts";
import { listScoringHr, resetScoringHrCache } from "../src/sources/whoop-web/store.ts";
import { sqliteD1 } from "./sqlite-d1.ts";

const MIN = 60_000;
const S = Date.parse("2026-11-16T15:00:00Z");
const END = S + 10 * MIN;
const iso = (ms: number) => new Date(ms).toISOString();
const ISO_MS = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

let seq = 0;
const uid = (prefix: string) => `${prefix}-${process.pid}-${++seq}`;

type Pts = Array<[number, number]>;
type Source = "codebox" | "ble";

/** 101 readings, 6 s apart, across the 10 minute meeting. */
const stamps = Array.from({ length: 101 }, (_, i) => S + i * 6_000);
const flat = (bpm: number): Pts => stamps.map((t) => [t, bpm]);
/** Only the first 50 readings: minutes 0 to 4. */
const first50 = (bpm: number): Pts => stamps.slice(0, 50).map((t) => [t, bpm]);

function setup(id: string) {
  const d = sqliteD1();
  d.raw
    .prepare(
      `INSERT INTO calendar_event (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, title, kind, attendee_count, after_hours, updated_at, start_local, end_local)
       VALUES (?, 'google', ?, ?, ?, -300, ?, 'Client review', 'client', 2, 0, 't', ?, ?)`,
    )
    .run(id, iso(S).slice(0, 10), iso(S), iso(END), (END - S) / 1000, iso(S), iso(END));
  const meeting = { id, startUtc: iso(S), endUtc: iso(END), day: iso(S).slice(0, 10) };
  const project = (fetchedAt: string) => projectRawHr(d.db, [{ meeting, allowEmpty: false }], fetchedAt);
  const store = (source: Source, pts: Pts, now = S + 20 * MIN) => storeRawHr(d.db, source, pts, now);
  return { ...d, meeting, project, store };
}

const row = (raw: DatabaseSync, id: string) =>
  raw.prepare(`SELECT fetched_at, sample_count, samples_json FROM whoop_web_hr WHERE event_id = ?`).get(id) as {
    fetched_at: string;
    sample_count: number;
    samples_json: string;
  };

type Window = { minutePoints: Array<[number, number]>; fetchedAt: string; sampleCount: number };
const warm = async (db: D1Database, id: string): Promise<Window[]> =>
  (await listScoringHr(db, [id])) as unknown as Window[];

/** The true answer: forget the cache, read from the stored row. */
async function truth(db: D1Database, id: string): Promise<Window[]> {
  resetScoringHrCache();
  return warm(db, id);
}

const bpmAt = (w: Window, minute: number) => w.minutePoints[minute]?.[1];

// ---------------------------------------------------------------------------
// 1. The scoring cache never serves minute averages older than the stored row
// ---------------------------------------------------------------------------

type Case = { name: string; first: Source; second: Source; firstFetched: number; lateFetched: number };

const FIRST = S + 700_000;
const cases: Case[] = [];
for (const [first, second] of [["codebox", "ble"], ["ble", "ble"], ["codebox", "codebox"]] as Array<[Source, Source]>) {
  cases.push({ name: `${first} then ${second}, late ingest with an older fetchedAt`, first, second, firstFetched: FIRST, lateFetched: S + 400_000 });
  cases.push({ name: `${first} then ${second}, late ingest with an equal fetchedAt`, first, second, firstFetched: FIRST, lateFetched: FIRST });
}

describe("projectRawHr: a rewritten row is never served from a stale scoring cache", () => {
  for (const c of cases) {
    it(c.name, async () => {
      const id = uid("stale");
      const t = setup(id);
      await t.store(c.first, flat(60));
      const p1 = await t.project(iso(c.firstFetched));
      assert.deepEqual(p1, { written: 1, empty: 0, unchanged: 0 }, "setup: the first projection writes the row");

      const before = await warm(t.db, id);
      assert.equal(before.length, 1, "setup: the row is readable");
      assert.equal(bpmAt(before[0], 0), 60, "setup: the warm cache holds the 60 bpm answer");
      assert.equal(before[0].fetchedAt, iso(c.firstFetched));

      // Same timestamps, new values: 95 and 60 have the same text length, the
      // sample count and the tail of samples_json do not change either.
      await t.store(c.second, first50(95));
      const p2 = await t.project(iso(c.lateFetched));
      assert.equal(p2.written, 1, "the late ingest rewrites the row");
      assert.equal(p2.unchanged, 0);

      const stored = JSON.parse(row(t.raw, id).samples_json) as Pts;
      assert.equal(stored[0][1], 95, "setup: the stored row now holds 95 bpm");
      assert.equal(stored[60][1], 60, "setup: the untouched tail is still 60 bpm");

      const after = await warm(t.db, id);
      const want = await truth(t.db, id);
      assert.equal(bpmAt(want[0], 0), 95, "setup: the true answer for minute 0 is 95 bpm (not the old 60)");
      assert.equal(bpmAt(want[0], 4), 95);
      assert.equal(bpmAt(want[0], 5), 60);
      assert.deepEqual(after, want, "the answer served after the rewrite equals the answer recomputed from the row");
    });
  }

  it("a second late rewrite is also seen (two stale ingests in a row)", async () => {
    const id = uid("twice");
    const t = setup(id);
    await t.store("ble", flat(60));
    await t.project(iso(FIRST));
    await warm(t.db, id);

    await t.store("ble", first50(95));
    assert.equal((await t.project(iso(S + 400_000))).written, 1);
    const mid = await warm(t.db, id);
    assert.equal(bpmAt(mid[0], 0), 95);

    await t.store("ble", first50(80));
    assert.equal((await t.project(iso(S + 100_000))).written, 1);
    const after = await warm(t.db, id);
    const want = await truth(t.db, id);
    assert.equal(bpmAt(want[0], 0), 80, "setup: the true answer is now 80 bpm");
    assert.deepEqual(after, want);
  });
});

// ---------------------------------------------------------------------------
// 2. fetched_at itself
// ---------------------------------------------------------------------------

describe("projectRawHr: fetched_at after a rewrite", () => {
  for (const [label, late] of [["older", S + 400_000], ["equal", FIRST]] as const) {
    it(`a rewrite with an ${label} fetchedAt moves fetched_at forward by exactly 1 ms`, async () => {
      const id = uid(`fwd-${label}`);
      const t = setup(id);
      await t.store("codebox", flat(60));
      await t.project(iso(FIRST));
      const before = row(t.raw, id);
      assert.equal(before.fetched_at, iso(FIRST));

      await t.store("ble", first50(95));
      assert.equal((await t.project(iso(late))).written, 1);
      const after = row(t.raw, id);

      assert.match(after.fetched_at, ISO_MS, "ISO text with milliseconds and Z, so it sorts and parses like the rest");
      assert.ok(Number.isFinite(Date.parse(after.fetched_at)));
      assert.ok(after.fetched_at > before.fetched_at, `strictly greater: ${after.fetched_at} > ${before.fetched_at}`);
      assert.equal(after.fetched_at, iso(FIRST + 1));
      assert.notEqual(after.samples_json, before.samples_json, "setup: the content really changed");
    });
  }

  it("repeated stale rewrites keep moving fetched_at forward, one ms each", async () => {
    const id = uid("fwd-many");
    const t = setup(id);
    await t.store("ble", flat(60));
    await t.project(iso(FIRST));
    let last = row(t.raw, id).fetched_at;
    for (const [i, bpm] of [95, 80, 70].entries()) {
      await t.store("ble", first50(bpm));
      assert.equal((await t.project(iso(S + 100_000))).written, 1, `rewrite ${i + 1} writes`);
      const now = row(t.raw, id).fetched_at;
      assert.ok(now > last, `rewrite ${i + 1}: ${now} > ${last}`);
      assert.equal(now, iso(Date.parse(last) + 1));
      assert.match(now, ISO_MS);
      last = now;
    }
  });

  it("a newer fetchedAt is used as is", async () => {
    const id = uid("fwd-newer");
    const t = setup(id);
    await t.store("codebox", flat(60));
    await t.project(iso(FIRST));
    await warm(t.db, id);

    await t.store("ble", first50(95));
    const newer = iso(FIRST + 5 * MIN);
    assert.equal((await t.project(newer)).written, 1);
    assert.equal(row(t.raw, id).fetched_at, newer, "equals the given value, not +1 ms of the old one");
    assert.deepEqual(await warm(t.db, id), await truth(t.db, id));
  });

  it("an identical re-projection changes nothing", async () => {
    const id = uid("same");
    const t = setup(id);
    await t.store("codebox", flat(60));
    await t.project(iso(FIRST));
    const before = row(t.raw, id);

    for (const fetchedAt of [iso(FIRST), iso(S + 400_000), iso(FIRST + 10 * MIN)]) {
      const counts = await t.project(fetchedAt);
      assert.deepEqual(counts, { written: 0, empty: 0, unchanged: 1 }, `unchanged for fetchedAt ${fetchedAt}`);
      assert.deepEqual(row(t.raw, id), before, "fetched_at, count and samples are all untouched");
    }

    // Storing the very same readings again does not change the projection either.
    await t.store("codebox", flat(60), S + 30 * MIN);
    assert.deepEqual(await t.project(iso(FIRST + 20 * MIN)), { written: 0, empty: 0, unchanged: 1 });
    assert.deepEqual(row(t.raw, id), before);
  });

  it("a rewrite that does not change the visible result (same bpm from another source) writes nothing", async () => {
    const id = uid("same-other-source");
    const t = setup(id);
    await t.store("codebox", flat(60));
    await t.project(iso(FIRST));
    const before = row(t.raw, id);

    await t.store("ble", flat(60));
    assert.deepEqual(await t.project(iso(S + 400_000)), { written: 0, empty: 0, unchanged: 1 });
    assert.deepEqual(row(t.raw, id), before);
  });
});

// ---------------------------------------------------------------------------
// 3. Carrying the +1 ms across calendar boundaries
// ---------------------------------------------------------------------------

describe("projectRawHr: the next millisecond is valid across boundaries", () => {
  const edges: Array<[string, string, string]> = [
    ["a second", "2026-11-16T15:11:59.999Z", "2026-11-16T15:12:00.000Z"],
    ["a minute", "2026-11-16T15:59:59.999Z", "2026-11-16T16:00:00.000Z"],
    ["a day", "2026-11-16T23:59:59.999Z", "2026-11-17T00:00:00.000Z"],
    ["a year", "2026-12-31T23:59:59.999Z", "2027-01-01T00:00:00.000Z"],
    ["no boundary", "2026-11-16T15:11:59.123Z", "2026-11-16T15:11:59.124Z"],
  ];
  for (const [label, existing, expected] of edges) {
    it(`crossing ${label}: ${existing} gives ${expected}`, async () => {
      const id = uid("edge");
      const t = setup(id);
      await t.store("codebox", flat(60));
      await t.project(existing);
      assert.equal(row(t.raw, id).fetched_at, existing);

      await t.store("ble", first50(95));
      // Older than the stored value, so the row has to step forward by itself.
      assert.equal((await t.project("2026-11-16T15:00:00.000Z")).written, 1);
      const got = row(t.raw, id).fetched_at;
      assert.match(got, ISO_MS);
      assert.equal(got, expected);
    });
  }
});
