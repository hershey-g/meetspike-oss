import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { storeMeetingHr } from "../src/sources/whoop-web/fill.ts";
import { fetchWindow, isStale } from "../src/sources/whoop-web/meeting-hr.ts";
import { getCachedHr, putCachedHr, resetScoringHrCache } from "../src/sources/whoop-web/store.ts";
import { ADMIN, MIN, world, type Ev, type World } from "./override-world.ts";

/**
 * Build 9 follow-up, the one fix pass (fix9c.md). Server halves.
 *   H1  a projection that changes a row's window over kept (non raw) points leaves the row fetchable
 *   H3  a "never saw it" report on a stale seen_none counts
 *   H4  an owner write never revives a stale seen_none
 *   H6  stored seen values that no longer fit are replaced by the new report, not widened with
 *   H7  storeMeetingHr returns the status that was stored
 * H2 (Swift parity fixture), H5 (Swift redirect verdict) are in
 * shared/MeetspikeHRCore/Tests/MeetspikeHRCoreTests/Build9FollowupFixTests.swift.
 *
 * H1 is tested through behaviour only: `isStale`, stored points, status, and what the scoring
 * route says. How the builder marks "not fetched for this window" is its own business.
 */

const ms = (s: string) => Date.parse(s);
const iso = (n: number) => new Date(n).toISOString();
const meeting = (id: string, start: string, end: string, extra: Partial<Ev> = {}): Ev =>
  ({ id, start, end, title: `Fix ${id}`, people: [], hr: null, ...extra });

const DAY = "2026-11-10";
const t = (hhmm: string) => ms(`${DAY}T${hhmm}:00.000Z`);
const at = (hhmm: string) => `${DAY}T${hhmm}:00Z`;
type Pts = Array<[number, number]>;
const minutes = (from: string, to: string, bpm: (ms: number) => number): Pts => {
  const out: Pts = [];
  for (let x = t(from); x <= t(to); x += MIN) out.push([x, bpm(x)]);
  return out;
};
/** Distinct two digit values, so a point from the wrong source or minute shows. */
const stored70 = (x: number) => 60 + ((x / MIN) % 23);
const CAL = { start: "15:00", end: "16:00" };
const winOf = (start: string, end: string) => fetchWindow(`${DAY}T${start}:00.000Z`, `${DAY}T${end}:00.000Z`);
const DAY_MS = 86_400_000;

async function view(w: World, id: string) {
  const e = (await w.get(`/view?date=${DAY}`)).day.calendar.events.find((x: any) => x.id === id);
  assert.ok(e, `${id} is listed on ${DAY}`);
  return e;
}

function putRaw(w: World, points: Pts) {
  const insert = w.raw.prepare("INSERT OR REPLACE INTO whoop_web_hr_raw (user_id, source, time_ms, bpm, received_at) VALUES ('owner', 'ble', ?, ?, 't')");
  w.raw.exec("BEGIN");
  for (const [x, b] of points) insert.run(x, b);
  w.raw.exec("COMMIT");
}

const rebuild = (w: World) => w.call("/whoop-web/rebuild", {
  method: "POST", headers: { authorization: `Bearer ${ADMIN}`, "content-type": "application/json" }, body: JSON.stringify({ day: DAY }),
});

type Stored = { status: string; fetchedAt: string; count: number; points: Map<number, number> };
function stored(w: World, id: string): Stored {
  const r = w.raw.prepare("SELECT status, fetched_at, sample_count, samples_json FROM whoop_web_hr WHERE event_id = ?").get(id) as any;
  assert.ok(r, `a stored heart rate row for ${id}`);
  return { status: r.status, fetchedAt: r.fetched_at, count: r.sample_count, points: new Map<number, number>(r.samples_json ? JSON.parse(r.samples_json) : []) };
}
function assertHas(row: Stored, expected: Pts, label: string) {
  const missing = expected.filter(([x, b]) => row.points.get(x) !== b);
  assert.equal(missing.length, 0, `${label}: ${missing.length} of ${expected.length} points are missing or changed, first at ${missing[0] ? iso(missing[0][0]) : "-"}`);
}

/** The stale answer for the row as it is now against a window, now and a month on. */
async function staleness(w: World, id: string, win: { startUtc: string; endUtc: string }, now = Date.now()) {
  const row = await getCachedHr(w.db, id);
  assert.ok(row, "the row is there");
  return { now: isStale(row, win, now), later: isStale(row, win, now + 30 * DAY_MS) };
}

/** What a warm scoring cache says about the meeting is what a cold one says. */
async function assertScoringFresh(w: World, id: string, label: string) {
  const warm = (await view(w, id)).hrStress;
  resetScoringHrCache();
  const cold = (await view(w, id)).hrStress;
  assert.deepEqual(warm, cold, `${label}: the scoring cache served something other than the stored points`);
  return cold;
}

const ok = (points: Pts) => ({ ok: true as const, value: { recognized: true, points } });
const failed = { ok: false as const, status: 500, reason: "HTTP 500" };

// ---------------------------------------------------------------------------
// H1
// ---------------------------------------------------------------------------

describe("H1: a window change over kept points leaves the row fetchable", () => {
  const ORIG = minutes("14:50", "16:10", stored70); // 81 points, the series the Worker stored for 15:00 to 16:00

  async function setup(id: string, series: Pts = ORIG) {
    const w = await world({ extra: [meeting(id, `${DAY}T15:00:00.000Z`, `${DAY}T16:00:00.000Z`)] });
    const win = winOf(CAL.start, CAL.end);
    await putCachedHr(w.db, {
      eventId: id, windowStartUtc: win.startUtc, windowEndUtc: win.endUtc, status: "ok", points: series, errorText: null,
      // Fetched long after the window closed: settled, as a finished meeting's row is.
      fetchedAt: "2026-11-20T00:00:00.000Z",
    });
    return w;
  }
  const input = (id: string, start: string, end: string) =>
    ({ id, startUtc: `${DAY}T${start}:00.000Z`, endUtc: `${DAY}T${end}:00.000Z`, day: DAY, effective: true as const });

  it("guard: the stored row is final for its own window (the setup is a settled row)", async () => {
    const id = "h1g";
    const w = await setup(id);
    const s = await staleness(w, id, winOf(CAL.start, CAL.end));
    assert.deepEqual(s, { now: false, later: false });
  });

  it("widening: stale right after the PUT and a month later, points and status kept", async () => {
    const id = "h1a";
    const w = await setup(id);
    await w.set(id, { scope: "event", endUtc: at("17:00") });
    const win = winOf(CAL.start, "17:00");
    const row = await getCachedHr(w.db, id);
    assert.equal(row?.windowEndUtc, iso(win.endMs), "the row follows the new window");
    assert.equal(row?.status, "ok");
    assert.equal(row?.points.length, 81, "no point is lost");
    assert.deepEqual(await staleness(w, id, win), { now: true, later: true }, "WHOOP is asked for the new time");
    assertHas(stored(w, id), ORIG, "after widening");
  });

  it("moved to a time with no points: status empty, points kept, still fetchable", async () => {
    const id = "h1b";
    const w = await setup(id);
    await w.set(id, { scope: "event", startUtc: at("17:00"), endUtc: at("18:00") });
    const win = winOf("17:00", "18:00");
    const row = await getCachedHr(w.db, id);
    assert.equal(row?.status, "empty");
    assert.equal(row?.points.length, 0, "readers see no points in the new window");
    assert.equal(stored(w, id).count, 0);
    assertHas(stored(w, id), ORIG, "the kept points are still stored");
    assert.deepEqual(await staleness(w, id, win), { now: true, later: true }, "'No heart rate' is not permanent");
    assert.equal((await view(w, id)).hrStress?.meanBpm ?? null, null, "nothing is scored for the empty window");
  });

  it("a second window change over the marked row stays fetchable, and so does going back to the calendar times", async () => {
    const id = "h1c";
    const w = await setup(id);
    await w.set(id, { scope: "event", endUtc: at("17:00") });
    await w.set(id, { scope: "event", endUtc: at("16:30") });
    assert.deepEqual(await staleness(w, id, winOf(CAL.start, "16:30")), { now: true, later: true });
    await w.set(id, { scope: "event", startUtc: at("14:30") });
    assert.deepEqual(await staleness(w, id, winOf("14:30", "16:30")), { now: true, later: true });
    await w.set(id, { scope: "event", startUtc: null, endUtc: null });
    assert.deepEqual(await staleness(w, id, winOf(CAL.start, CAL.end)), { now: true, later: true });
    assertHas(stored(w, id), ORIG, "every point survived the walk");
  });

  it("a later same-window rebuild with new raw rows does not settle the row, and the points are merged", async () => {
    const id = "h1d";
    const w = await setup(id);
    await w.set(id, { scope: "event", endUtc: at("17:00") });
    const raw = minutes("16:20", "16:40", () => 99);
    putRaw(w, raw);
    const res = await rebuild(w);
    assert.equal(res.status, 200, res.text);
    const row = stored(w, id);
    assertHas(row, ORIG, "stored points after the rebuild");
    assertHas(row, raw, "raw points in the new window");
    assert.equal(row.status, "ok");
    assert.deepEqual(await staleness(w, id, winOf(CAL.start, "17:00")), { now: true, later: true },
      "a projection with no answer from WHOOP must not mark the window as fetched");
  });

  it("a rebuild that adds raw rows to an empty (moved) window does not settle it either", async () => {
    const id = "h1e";
    const w = await setup(id);
    await w.set(id, { scope: "event", startUtc: at("17:00"), endUtc: at("18:00") });
    putRaw(w, minutes("17:10", "17:20", () => 99));
    assert.equal((await rebuild(w)).status, 200);
    assert.equal((await getCachedHr(w.db, id))?.status, "ok");
    assert.deepEqual(await staleness(w, id, winOf("17:00", "18:00")), { now: true, later: true });
    assertHas(stored(w, id), ORIG, "kept points still stored");
  });

  it("scoring cache: never served stale, including a middle edit that keeps length, count and tail", async () => {
    const id = "h1f";
    const w = await setup(id, minutes("14:50", "16:10", () => 70));
    const before = await assertScoringFresh(w, id, "before any change");
    assert.ok(typeof before?.meanBpm === "number");
    await w.set(id, { scope: "event", endUtc: at("17:00") });
    await assertScoringFresh(w, id, "after widening");
    // Raw wins on the same minute: five middle points go from 70 to 99, nothing else about the row changes
    // (same count, same length of text, same tail). A second raw edit follows the first.
    putRaw(w, minutes("15:20", "15:24", () => 99));
    assert.equal((await rebuild(w)).status, 200);
    const afterRaw = await assertScoringFresh(w, id, "after raw rows replaced five stored points");
    assert.equal(afterRaw?.maxBpm, 99, "the rebuilt points are what is scored");
    putRaw(w, minutes("15:20", "15:24", () => 98));
    assert.equal((await rebuild(w)).status, 200);
    const again = await assertScoringFresh(w, id, "after the same minutes changed again");
    assert.equal(again?.maxBpm, 98);
    assert.equal(stored(w, id).points.get(t("15:22")), 98);
  });

  it("a failed fetch on a marked row keeps points and status, and never settles it", async () => {
    const id = "h1h";
    const w = await setup(id);
    await w.set(id, { scope: "event", endUtc: at("17:00") });
    const failedAt = Date.now(); // far after the window closed: a settling write would make the row final
    const row = await storeMeetingHr({ DB: w.db }, input(id, "15:00", "17:00"), failed, iso(failedAt));
    assert.equal(row.status, "ok", "the retention path answers with the kept status");
    const now = await getCachedHr(w.db, id);
    assert.equal(now?.status, "ok");
    assert.equal(now?.points.length, 81);
    assertHas(stored(w, id), ORIG, "after the failed fetch");
    const win = winOf(CAL.start, "17:00");
    assert.equal(isStale(now, win, failedAt + 30 * DAY_MS), true, "a month later it is still fetchable");
    assert.equal(isStale(now, win, failedAt + 31 * MIN), true, "past the retry delay it is fetchable");
    await assertScoringFresh(w, id, "after the failed fetch");
  });

  it("a failed fetch on a moved-to-empty row keeps the kept points and stays fetchable", async () => {
    const id = "h1i";
    const w = await setup(id);
    await w.set(id, { scope: "event", startUtc: at("17:00"), endUtc: at("18:00") });
    const failedAt = Date.now();
    await storeMeetingHr({ DB: w.db }, input(id, "17:00", "18:00"), failed, iso(failedAt));
    const now = await getCachedHr(w.db, id);
    assert.notEqual(now?.status, undefined);
    assertHas(stored(w, id), ORIG, "kept points stay after a failed fetch");
    assert.equal(isStale(now, winOf("17:00", "18:00"), failedAt + 30 * DAY_MS), true);
  });

  it("a good fetch after a failed one settles it, and merges with the kept points", async () => {
    const id = "h1j";
    const w = await setup(id);
    await w.set(id, { scope: "event", endUtc: at("17:00") });
    await storeMeetingHr({ DB: w.db }, input(id, "15:00", "17:00"), failed, iso(Date.now()));
    const fetchedAt = Date.now();
    const fresh = minutes("16:10", "17:10", () => 88); // WHOOP's answer for the widened window
    const out = await storeMeetingHr({ DB: w.db }, input(id, "15:00", "17:00"), ok(fresh), iso(fetchedAt));
    assert.equal(out.status, "ok");
    const win = winOf(CAL.start, "17:00");
    const row = await getCachedHr(w.db, id);
    assert.equal(isStale(row, win, fetchedAt + 30 * DAY_MS), false, "a good answer long after the window closed is final");
    assert.equal(isStale(row, win, fetchedAt), false);
    assertHas(stored(w, id), ORIG.filter(([x]) => x < t("16:10")), "stored minutes before the fetched ones");
    assertHas(stored(w, id), fresh, "fetched minutes");
    await assertScoringFresh(w, id, "after the good fetch");
  });

  it("a good fetch with no points for a moved (empty) window is a good answer and settles it", async () => {
    const id = "h1k";
    const w = await setup(id);
    await w.set(id, { scope: "event", startUtc: at("17:00"), endUtc: at("18:00") });
    const fetchedAt = Date.now();
    const out = await storeMeetingHr({ DB: w.db }, input(id, "17:00", "18:00"), ok([]), iso(fetchedAt));
    assert.equal(out.status, "empty");
    assert.equal(isStale(await getCachedHr(w.db, id), winOf("17:00", "18:00"), fetchedAt + 30 * DAY_MS), false);
    assertHas(stored(w, id), ORIG, "kept points are still not lost");
  });

  it("a meeting with no window change is untouched: a rebuild with new raw rows stamps the time it ran, as before", async () => {
    const id = "h1l";
    const w = await setup(id);
    const before = Date.now();
    putRaw(w, minutes("15:20", "15:22", () => 99));
    assert.equal((await rebuild(w)).status, 200);
    const row = stored(w, id);
    assert.equal(row.points.get(t("15:21")), 99);
    assert.ok(ms(row.fetchedAt) >= before, `fetched_at is ${row.fetchedAt}, the time of the rebuild`);
    assert.deepEqual(await staleness(w, id, winOf(CAL.start, CAL.end)), { now: false, later: false });
    await assertScoringFresh(w, id, "after a raw projection with no window change");
  });

  it("a rebuild with nothing new rewrites nothing", async () => {
    const id = "h1m";
    const w = await setup(id);
    const row = w.raw.prepare("SELECT * FROM whoop_web_hr WHERE event_id = ?").get(id);
    assert.equal((await rebuild(w)).status, 200);
    assert.deepEqual(w.raw.prepare("SELECT * FROM whoop_web_hr WHERE event_id = ?").get(id), row);
  });

  it("an all-raw row behaves as on main: a window change writes the time it ran and the row is final", async () => {
    const id = "h1n";
    const w = await world({ extra: [meeting(id, `${DAY}T15:00:00.000Z`, `${DAY}T16:00:00.000Z`)] });
    putRaw(w, minutes("14:50", "16:30", stored70));
    assert.equal((await rebuild(w)).status, 200);
    assert.equal(stored(w, id).status, "ok");
    const before = Date.now();
    await w.set(id, { scope: "event", endUtc: at("16:15") });
    const row = stored(w, id);
    assert.equal(row.points.size, 96, "every raw minute inside the new window, 14:50 to 16:25");
    assert.equal(row.status, "ok");
    assert.ok(ms(row.fetchedAt) >= before, `fetched_at is ${row.fetchedAt}, the time of the change, not a marker`);
    assert.deepEqual(await staleness(w, id, winOf(CAL.start, "16:15")), { now: false, later: false });
    await assertScoringFresh(w, id, "all-raw row after a window change");
  });
});

// ---------------------------------------------------------------------------
// H3, H4, H6
// ---------------------------------------------------------------------------

describe("H3, H4, H6: seen_none and seen times after the calendar moved", () => {
  // The calendar moved the meeting to 20:00 to 21:00. The Mac's old report is from around 16:05.
  const CS = "2026-11-10T20:00:00.000Z";
  const CE = "2026-11-10T21:00:00.000Z";
  const STALE_AT = "2026-11-10T16:05:00.000Z";

  async function staleNone(id: string, extra: Ev[] = []) {
    const w = await world({ extra: [meeting(id, CS, CE), ...extra] });
    w.raw.prepare("INSERT INTO meeting_override (key, seen_none, updated_at) VALUES (?, 1, ?)").run(`event:${id}`, STALE_AT);
    assert.equal((await view(w, id)).override.seenNone, false, "the setup: a stale seen_none does not count");
    return w;
  }
  const report = (w: World, id: string, body: Record<string, unknown>) =>
    w.attend({ meetingStartUtc: CS, title: `Fix ${id}`, seenNone: false, ...body });

  it("H3: a never saw it report on a stale seen_none moves updated_at and counts", async () => {
    const id = "h3a";
    const w = await staleNone(id);
    const before = Date.now();
    const r = await report(w, id, { seenNone: true });
    assert.equal(r.status, 200, r.text);
    assert.equal(r.body.matched, true);
    assert.ok(ms(w.row(`event:${id}`)!.updated_at) >= before, "updated_at is now");
    assert.equal(w.row(`event:${id}`)!.seen_none, 1);
    assert.equal((await view(w, id)).override.seenNone, true, "the new report counts");
  });

  it("H3: a valid seen_none stays valid after a repeated report", async () => {
    const id = "h3b";
    const w = await world({ extra: [meeting(id, CS, CE)] });
    w.raw.prepare("INSERT INTO meeting_override (key, seen_none, updated_at) VALUES (?, 1, '2026-11-10T21:30:00.000Z')").run(`event:${id}`);
    assert.equal((await view(w, id)).override.seenNone, true);
    assert.equal((await report(w, id, { seenNone: true })).status, 200);
    assert.equal((await view(w, id)).override.seenNone, true);
    assert.equal(w.row(`event:${id}`)!.seen_none, 1);
  });

  it("H4: an owner times edit never revives a stale seen_none", async () => {
    const id = "h4a";
    const w = await staleNone(id);
    await w.set(id, { scope: "event", endUtc: "2026-11-10T21:15:00Z" }); // saved after the calendar end
    assert.equal((await view(w, id)).override.seenNone, false, "the app does not suggest the owner didn't join");
    assert.equal(w.row(`event:${id}`)!.seen_none, 0);
    assert.equal(ms(w.row(`event:${id}`)!.end_utc), ms("2026-11-10T21:15:00Z"), "the edit itself is saved");
  });

  it("H4: an owner state choice on the event key does not either", async () => {
    const id = "h4b";
    const w = await staleNone(id);
    await w.set(id, { scope: "event", state: "linked" });
    assert.equal((await view(w, id)).override.seenNone, false);
    assert.equal(w.row(`event:${id}`)!.seen_none, 0);
    assert.equal(w.row(`event:${id}`)!.state, "linked");
  });

  it("H4: a series PUT that clears the tapped meeting's own linked does not either", async () => {
    const id = "h4ser_20261110T200000Z";
    const w = await world({ extra: [meeting(id, CS, CE)] });
    w.raw.prepare("INSERT INTO meeting_override (key, state, seen_none, updated_at) VALUES (?, 'linked', 1, ?)").run(`event:${id}`, STALE_AT);
    const r = await w.put(id, { scope: "series", state: "not_joined" });
    assert.equal(r.status, 200, r.text);
    await w.settle();
    const row = w.row(`event:${id}`);
    assert.ok(!row || row.seen_none === 0, "no seen_none left on the own row");
    assert.equal((await view(w, id)).override.seenNone, false);
  });

  it("H4: a valid seen_none stays valid through an owner write", async () => {
    const id = "h4d";
    const w = await world({ extra: [meeting(id, CS, CE)] });
    w.raw.prepare("INSERT INTO meeting_override (key, seen_none, updated_at) VALUES (?, 1, '2026-11-10T21:30:00.000Z')").run(`event:${id}`);
    await w.set(id, { scope: "event", endUtc: "2026-11-10T21:15:00Z" });
    assert.equal(w.row(`event:${id}`)!.seen_none, 1);
    assert.equal((await view(w, id)).override.seenNone, true);
  });

  it("H4: a write on a meeting that has no row yet works as before", async () => {
    const id = "h4e";
    const w = await world({ extra: [meeting(id, CS, CE)] });
    await w.set(id, { scope: "event", endUtc: "2026-11-10T21:15:00Z" });
    assert.equal(w.row(`event:${id}`)!.seen_none, 0);
    assert.equal(ms((await view(w, id)).endUtc), ms("2026-11-10T21:15:00Z"));
  });

  it("H6: seen times that no longer fit are replaced by the new report, not widened with", async () => {
    const id = "h6a";
    const w = await world({ extra: [meeting(id, "2026-11-10T18:00:00.000Z", "2026-11-10T19:00:00.000Z")] });
    w.raw.prepare("INSERT INTO meeting_override (key, seen_start_utc, seen_end_utc, seen_none, updated_at) VALUES (?, '2026-11-10T15:02:00.000Z', '2026-11-10T15:50:00.000Z', 0, '2026-11-10T16:00:00.000Z')")
      .run(`event:${id}`);
    const r = await w.attend({ meetingStartUtc: "2026-11-10T18:00:00.000Z", title: `Fix ${id}`, seenStartUtc: "2026-11-10T18:07:00.000Z", seenEndUtc: "2026-11-10T18:40:00.000Z", seenNone: false });
    assert.equal(r.status, 200, r.text);
    assert.equal(ms(w.row(`event:${id}`)!.seen_start_utc), ms("2026-11-10T18:07:00.000Z"));
    assert.equal(ms(w.row(`event:${id}`)!.seen_end_utc), ms("2026-11-10T18:40:00.000Z"));
    const e = await view(w, id);
    assert.equal(ms(e.startUtc), ms("2026-11-10T18:07:00.000Z"), "the fresh start, not 18:00");
    assert.equal(ms(e.endUtc), ms("2026-11-10T18:40:00.000Z"));
  });

  it("H6: seen times that still fit are widened with, as before", async () => {
    const id = "h6b";
    const w = await world({ extra: [meeting(id, "2026-11-10T18:00:00.000Z", "2026-11-10T19:00:00.000Z")] });
    w.raw.prepare("INSERT INTO meeting_override (key, seen_start_utc, seen_end_utc, seen_none, updated_at) VALUES (?, '2026-11-10T17:55:00.000Z', '2026-11-10T18:30:00.000Z', 0, '2026-11-10T18:31:00.000Z')")
      .run(`event:${id}`);
    const r = await w.attend({ meetingStartUtc: "2026-11-10T18:00:00.000Z", title: `Fix ${id}`, seenStartUtc: "2026-11-10T18:07:00.000Z", seenEndUtc: "2026-11-10T18:40:00.000Z", seenNone: false });
    assert.equal(r.status, 200, r.text);
    assert.equal(ms(w.row(`event:${id}`)!.seen_start_utc), ms("2026-11-10T17:55:00.000Z"), "earliest start");
    assert.equal(ms(w.row(`event:${id}`)!.seen_end_utc), ms("2026-11-10T18:40:00.000Z"), "latest end");
  });

  it("H6: a first report on a meeting with no row is stored as sent", async () => {
    const id = "h6c";
    const w = await world({ extra: [meeting(id, "2026-11-10T18:00:00.000Z", "2026-11-10T19:00:00.000Z")] });
    const r = await w.attend({ meetingStartUtc: "2026-11-10T18:00:00.000Z", title: `Fix ${id}`, seenStartUtc: "2026-11-10T18:07:00.000Z", seenEndUtc: "2026-11-10T18:40:00.000Z", seenNone: false });
    assert.equal(r.status, 200, r.text);
    assert.equal(ms(w.row(`event:${id}`)!.seen_start_utc), ms("2026-11-10T18:07:00.000Z"));
  });
});

// ---------------------------------------------------------------------------
// H7
// ---------------------------------------------------------------------------

describe("H7: storeMeetingHr returns the status that was stored", () => {
  const ID = "h7";
  const IN = { id: ID, startUtc: `${DAY}T15:00:00.000Z`, endUtc: `${DAY}T16:00:00.000Z`, day: DAY };
  const win = winOf("15:00", "16:00");
  const NOW = "2026-11-20T00:00:00.000Z";

  async function setup(points: Pts | null, status: "ok" | "empty" | "error" = "ok") {
    const w = await world({ extra: [meeting(ID, IN.startUtc, IN.endUtc)] });
    if (points) {
      await putCachedHr(w.db, { eventId: ID, windowStartUtc: win.startUtc, windowEndUtc: win.endUtc, status, points, errorText: null, fetchedAt: NOW });
    }
    return w;
  }
  async function same(w: World, res: Parameters<typeof storeMeetingHr>[2]) {
    const out = await storeMeetingHr({ DB: w.db }, IN, res, iso(Date.now()));
    const row = w.raw.prepare("SELECT status FROM whoop_web_hr WHERE event_id = ?").get(ID) as { status: string };
    assert.equal(out.status, row.status, "the status it returns is the status that is in the table");
    return { out, row };
  }

  it("a stored point and an ok answer with no points: ok, not empty", async () => {
    const w = await setup([[t("15:30"), 70]]);
    const { out } = await same(w, ok([]));
    assert.equal(out.status, "ok");
  });

  it("an ok answer with points", async () => {
    const w = await setup(null);
    const { out } = await same(w, ok(minutes("15:00", "15:10", () => 80)));
    assert.equal(out.status, "ok");
  });

  it("an empty answer with nothing stored", async () => {
    const w = await setup(null);
    const { out } = await same(w, ok([]));
    assert.equal(out.status, "empty");
  });

  it("an error answer with nothing stored", async () => {
    const w = await setup(null);
    const { out } = await same(w, failed);
    assert.equal(out.status, "error");
  });

  it("an error answer over an ok row keeps ok", async () => {
    const w = await setup([[t("15:30"), 70]]);
    const { out } = await same(w, failed);
    assert.equal(out.status, "ok");
  });

  it("an error answer over an empty row", async () => {
    const w = await setup([], "empty");
    await same(w, failed);
  });

  it("an ok answer whose points are all outside the window, over a stored point inside", async () => {
    const w = await setup([[t("15:30"), 70]]);
    await same(w, ok([[t("15:20"), 90]]));
  });
});
