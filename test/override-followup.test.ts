import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { actionsHtml, planAction } from "../public/meeting-actions.js";
import { putCachedHr } from "../src/sources/whoop-web/store.ts";
import { ADMIN, MIN, world, type Ev, type World } from "./override-world.ts";

/**
 * Build 9 follow-up (fix9b.md): the server and web halves.
 *   G1  changing a meeting's times never loses heart rate that only exists in `whoop_web_hr`
 *   G4  a series PUT sent to an id whose own row is `linked` clears that row's state (server), web plan relies on it
 *   G6  a validation error on the times form keeps what was typed
 *   G7  seen times outside [calendar start - 15 min, calendar end + 4 h] and a stale `seen_none` are ignored
 * The Swift halves are in shared/MeetspikeHRCore/Tests/MeetspikeHRCoreTests/Build9FollowupTests.swift.
 *
 * NAMES FIXED HERE (the builder provides them):
 *   web, public/meeting-actions.js: `actionsHtml(e, ui, tz)` fills the times form from `ui.typed = { start, end }`
 *   (the text of the two inputs, "YYYY-MM-DDTHH:mm" or "") when `ui.typed` is set, else from the saved times.
 *   public/app.js puts `typed` on `state.meetingUi` in the times form's error branch.
 */

const ms = (s: string) => Date.parse(s);
const iso = (n: number) => new Date(n).toISOString();
const meeting = (id: string, start: string, end: string, extra: Partial<Ev> = {}): Ev =>
  ({ id, start, end, title: `Follow ${id}`, people: [], hr: null, ...extra });

async function view(w: World, day: string, id: string) {
  const e = (await w.get(`/view?date=${day}`)).day.calendar.events.find((x: any) => x.id === id);
  assert.ok(e, `${id} is listed on ${day}`);
  return e;
}

// ---------------------------------------------------------------------------
// G1
// ---------------------------------------------------------------------------

const DAY = "2026-11-10";
/** A clock time on 10 Nov as epoch ms. */
const t = (hhmm: string) => ms(`${DAY}T${hhmm}:00.000Z`);
/** The same as the text a PUT takes. */
const at = (hhmm: string) => `${DAY}T${hhmm}:00Z`;
type Pts = Array<[number, number]>;
const minutes = (from: string, to: string, bpm: (ms: number) => number): Pts => {
  const out: Pts = [];
  for (let x = t(from); x <= t(to); x += MIN) out.push([x, bpm(x)]);
  return out;
};
/** Distinct values, so a point that came from the wrong source or the wrong minute shows. */
const stored70 = (x: number) => 60 + ((x / MIN) % 23);
const CAL = { start: "15:00", end: "16:00" };
const fetchWin = (start: string, end: string): [number, number] => [t(start) - 10 * MIN, t(end) + 10 * MIN];

async function storeSeries(w: World, id: string, points: Pts, win: [number, number] = fetchWin(CAL.start, CAL.end)) {
  await putCachedHr(w.db, {
    eventId: id, windowStartUtc: iso(win[0]), windowEndUtc: iso(win[1]), status: "ok", points, errorText: null,
    fetchedAt: "2026-11-20T00:00:00.000Z",
  });
}

function putRaw(w: World, points: Pts) {
  const insert = w.raw.prepare("INSERT OR REPLACE INTO whoop_web_hr_raw (user_id, source, time_ms, bpm, received_at) VALUES ('owner', 'ble', ?, ?, 't')");
  w.raw.exec("BEGIN");
  for (const [x, b] of points) insert.run(x, b);
  w.raw.exec("COMMIT");
}

const rawCount = (w: World) => (w.raw.prepare("SELECT COUNT(*) AS n FROM whoop_web_hr_raw").get() as any).n as number;

type Stored = { windowStart: string; windowEnd: string; count: number; points: Map<number, number> };
function stored(w: World, id: string): Stored {
  const r = w.raw.prepare("SELECT window_start_utc, window_end_utc, sample_count, samples_json FROM whoop_web_hr WHERE event_id = ?").get(id) as any;
  assert.ok(r, `a stored heart rate row for ${id}`);
  const points = new Map<number, number>((r.samples_json ? JSON.parse(r.samples_json) : []) as Pts);
  return { windowStart: r.window_start_utc, windowEnd: r.window_end_utc, count: r.sample_count, points };
}

/** Points of `row` with a time inside [from, to]. */
const inside = (row: Stored, from: number, to: number) => [...row.points].filter(([x]) => x >= from && x <= to);

/** Every expected point is in the row with the expected value. */
function assertHas(row: Stored, expected: Pts, label: string) {
  const missing = expected.filter(([x, b]) => row.points.get(x) !== b);
  assert.equal(missing.length, 0,
    `${label}: ${missing.length} of ${expected.length} points are missing or changed, first at ${missing[0] ? iso(missing[0][0]) : "-"}`);
}

describe("G1: changing a meeting's times never loses heart rate that only exists in whoop_web_hr", () => {
  const ORIG = minutes("14:50", "16:10", stored70); // 81 points, the series the Worker stored for 15:00 to 16:00

  async function setup(id: string, series: Pts = ORIG) {
    const w = await world({ extra: [meeting(id, `${DAY}T15:00:00.000Z`, `${DAY}T16:00:00.000Z`)] });
    await storeSeries(w, id, series);
    return w;
  }

  it("the review's case: 60 stored points and 2 raw rows in the new window keep all 62, and clearing the times keeps them", async () => {
    const id = "g1a";
    const stored60 = minutes("15:00", "15:59", stored70);
    const w = await setup(id, stored60);
    const raw: Pts = [[t("16:05"), 90], [t("16:06"), 90]];
    putRaw(w, raw);
    const raws = rawCount(w);

    await w.set(id, { scope: "event", endUtc: at("16:15") });
    let row = stored(w, id);
    assert.ok(row.count >= 60, `sample_count is ${row.count}, the 60 stored points are not lost`);
    assertHas(row, stored60, "stored points after the end moved to 16:15");
    assertHas(row, raw, "raw points in the new window");
    assert.equal(row.count, 62);
    assert.equal(row.windowEnd, iso(t("16:15") + 10 * MIN), "the row follows the new window");

    // A rebuild of the day (the nightly one, or an ingest) must not undo it either.
    const rebuild = await w.call("/whoop-web/rebuild", {
      method: "POST", headers: { authorization: `Bearer ${ADMIN}`, "content-type": "application/json" }, body: JSON.stringify({ day: DAY }),
    });
    assert.equal(rebuild.status, 200, rebuild.text);
    row = stored(w, id);
    assertHas(row, stored60, "after a rebuild of the day");
    assertHas(row, raw, "raw points after a rebuild of the day");

    await w.set(id, { scope: "event", endUtc: null });
    row = stored(w, id);
    assertHas(row, stored60, "after going back to the calendar times");
    assertHas(row, raw, "raw points after going back to the calendar times");
    assert.equal(row.count, 62, "back on the calendar window: every point shows again");
    assert.equal(row.windowEnd, iso(t(CAL.end) + 10 * MIN));
    assert.equal(rawCount(w), raws, "raw rows are never deleted");
  });

  it("stored only, no raw rows at all (a meeting the Worker filled): widening keeps every point and the row follows the window", async () => {
    const id = "g1b";
    const w = await setup(id);
    assert.equal(rawCount(w), 0);

    await w.set(id, { scope: "event", endUtc: at("16:15") });
    let row = stored(w, id);
    assertHas(row, ORIG, "end 16:15");
    assert.equal(row.count, 81);
    assert.equal(row.windowStart, iso(t("14:50")));
    assert.equal(row.windowEnd, iso(t("16:25")), "a merge is possible, so the row is re-projected, not skipped");

    await w.set(id, { scope: "event", endUtc: at("16:30") });
    row = stored(w, id);
    assertHas(row, ORIG, "end 16:30");
    assert.equal(row.windowEnd, iso(t("16:40")));

    await w.set(id, { scope: "event", startUtc: at("14:30") });
    row = stored(w, id);
    assertHas(row, ORIG, "start 14:30");
    assert.equal(row.windowStart, iso(t("14:20")));
    assert.equal(row.count, 81);

    await w.set(id, { scope: "event", startUtc: null, endUtc: null });
    row = stored(w, id);
    assertHas(row, ORIG, "calendar times again");
    assert.equal(row.count, 81);
    assert.equal(row.windowStart, iso(t("14:50")));
    assert.equal(row.windowEnd, iso(t("16:10")));
  });

  it("the score after moving and clearing the times is the score it had before", async () => {
    const id = "g1c";
    const w = await setup(id, minutes("14:50", "16:10", (x) => (x < t("15:30") ? 70 : 120)));
    const mean = async () => (await view(w, DAY, id)).hrStress?.meanBpm;
    const before = await mean();
    assert.ok(typeof before === "number", "it scores before any change");
    await w.set(id, { scope: "event", endUtc: at("16:15") });
    await w.set(id, { scope: "event", startUtc: at("14:30"), endUtc: at("16:30") });
    await w.set(id, { scope: "event", startUtc: null, endUtc: null });
    assert.equal(await mean(), before);
  });

  it("raw plus stored are merged, raw wins on the same minute, and points past the old window come from raw", async () => {
    const id = "g1d";
    const w = await setup(id);
    const raw = minutes("15:55", "16:20", () => 99); // overlaps the stored 15:55 to 16:10 and runs past it
    putRaw(w, raw);

    await w.set(id, { scope: "event", endUtc: at("16:15") }); // window 14:50 to 16:25
    let row = stored(w, id);
    const expected = new Map<number, number>(ORIG.filter(([x]) => x < t("15:55")));
    for (const [x, b] of raw) expected.set(x, b);
    assertHas(row, [...expected], "stored before 15:55, raw from 15:55");
    assert.equal(row.count, 91, "14:50 to 16:20, one point a minute");
    assert.equal(row.points.get(t("16:00")), 99, "raw wins on the same timestamp");
    assert.equal(row.points.get(t("16:18")), 99, "raw past the old window is in");

    await w.set(id, { scope: "event", endUtc: null }); // window 14:50 to 16:10
    row = stored(w, id);
    const back = [...expected].filter(([x]) => x <= t("16:10"));
    assertHas(row, back, "back on the calendar window");
    assert.equal(inside(row, t("14:50"), t("16:10")).length, 81);
  });

  it("raw only in part of the window: narrowing keeps stored points beside it, and widening again brings back the rest", async () => {
    const id = "g1e";
    const w = await setup(id);
    const raw = minutes("15:20", "15:30", () => 99);
    putRaw(w, raw);

    await w.set(id, { scope: "event", endUtc: at("15:30") }); // window 14:50 to 15:40
    let row = stored(w, id);
    const winPoints = (r: Stored) => inside(r, t("14:50"), t("15:40"));
    const expected = new Map<number, number>(ORIG.filter(([x]) => x <= t("15:40")));
    for (const [x, b] of raw) expected.set(x, b);
    assert.equal(winPoints(row).length, 51, "no stored minute in the new window is lost, none is added");
    assertHas(row, [...expected], "inside the new window: stored, raw winning on 15:20 to 15:30");
    assert.ok(row.count >= 51);

    await w.set(id, { scope: "event", endUtc: null });
    row = stored(w, id);
    const all = new Map<number, number>(ORIG);
    for (const [x, b] of raw) all.set(x, b);
    assertHas(row, [...all], "calendar times again: all 81 minutes, raw winning where it has the minute");
    assert.equal(inside(row, t("14:50"), t("16:10")).length, 81);
  });

  it("narrowing then widening past the original window loses nothing", async () => {
    const id = "g1f";
    const w = await setup(id);
    putRaw(w, minutes("15:25", "15:26", () => 99)); // makes the projection write today (the stored row alone is skipped)
    await w.set(id, { scope: "event", startUtc: at("15:20"), endUtc: at("15:40") }); // window 15:10 to 15:50
    const narrow = stored(w, id);
    assert.ok(inside(narrow, t("15:10"), t("15:50")).length >= 41, "every stored minute in the narrow window is kept");
    await w.set(id, { scope: "event", startUtc: at("14:00"), endUtc: at("17:00") }); // window 13:50 to 17:10
    const wide = stored(w, id);
    const expected = new Map<number, number>(ORIG);
    expected.set(t("15:25"), 99);
    expected.set(t("15:26"), 99);
    assertHas(wide, [...expected], "widened past the old window");
    assert.equal(wide.count, 81);
  });

  /** One step of a walk: the fields sent (null clears one, an absent field is left alone). */
  type Step = { startUtc?: string | null; endUtc?: string | null };
  const WALK: Step[] = [
    { endUtc: at("16:15") },
    { endUtc: at("16:30") },
    { startUtc: at("14:30") },
    { endUtc: at("15:30") },
    { startUtc: at("15:10") },
    { endUtc: at("17:00") },
    { startUtc: null },
    { startUtc: at("15:20"), endUtc: at("15:45") },
    { startUtc: null, endUtc: null },
    { endUtc: at("16:15") },
    { endUtc: null },
    { startUtc: at("13:30"), endUtc: at("19:00") },
    { startUtc: null, endUtc: null },
  ];

  /** The effective [start, end] as clock text, after a step. */
  function next(cur: { start: string; end: string }, step: Step) {
    const hhmm = (v: string | null | undefined, keep: string, cal: string) => (v === undefined ? keep : v === null ? cal : v.slice(11, 16));
    return { start: hhmm(step.startUtc, cur.start, CAL.start), end: hhmm(step.endUtc, cur.end, CAL.end) };
  }

  it("repeated changes, stored only: after every step each original point inside the new window is there with its value", async () => {
    const id = "g1g";
    const w = await setup(id);
    let cur = { ...CAL };
    for (const [i, step] of WALK.entries()) {
      cur = next(cur, step);
      await w.set(id, { scope: "event", ...step });
      const row = stored(w, id);
      const [from, to] = fetchWin(cur.start, cur.end);
      assertHas(row, ORIG.filter(([x]) => x >= from && x <= to), `step ${i + 1} ${JSON.stringify(step)} (window ${cur.start} to ${cur.end})`);
    }
    const row = stored(w, id);
    assertHas(row, ORIG, "after the last step the calendar times are back: every point");
    assert.equal(row.count, 81);
    assert.equal(rawCount(w), 0);
  });

  it("repeated changes with raw rows: a step never ends with fewer points inside the overlap of the old and new windows", async () => {
    const id = "g1h";
    const w = await setup(id);
    putRaw(w, minutes("15:30", "16:40", () => 99));
    const raws = rawCount(w);
    let cur = { ...CAL };
    for (const [i, step] of WALK.entries()) {
      const [oldFrom, oldTo] = fetchWin(cur.start, cur.end);
      const before = stored(w, id);
      cur = next(cur, step);
      await w.set(id, { scope: "event", ...step });
      const after = stored(w, id);
      const [newFrom, newTo] = fetchWin(cur.start, cur.end);
      const [from, to] = [Math.max(oldFrom, newFrom), Math.min(oldTo, newTo)];
      assert.ok(inside(after, from, to).length >= inside(before, from, to).length,
        `step ${i + 1} ${JSON.stringify(step)}: ${inside(after, from, to).length} points in the overlap, there were ${inside(before, from, to).length}`);
      assert.ok(after.count >= inside(before, from, to).length, `step ${i + 1}: sample_count is not below the overlap`);
    }
    const row = stored(w, id);
    assertHas(row, ORIG.filter(([x]) => x < t("15:30")), "the stored minutes before the raw rows start are still there");
    assert.equal(rawCount(w), raws, "raw rows are never deleted");
  });

  it("a PUT that changes only the state, or the same times again, does not touch the stored series", async () => {
    const id = "g1i";
    const w = await setup(id);
    putRaw(w, minutes("15:55", "16:20", () => 99));
    await w.set(id, { scope: "event", endUtc: at("16:15") });
    const row = w.raw.prepare("SELECT * FROM whoop_web_hr WHERE event_id = ?").get(id);
    await w.set(id, { scope: "event", endUtc: at("16:15") });
    assert.deepEqual(w.raw.prepare("SELECT * FROM whoop_web_hr WHERE event_id = ?").get(id), row);
    await w.set(id, { scope: "event", state: "linked" });
    assert.deepEqual(w.raw.prepare("SELECT * FROM whoop_web_hr WHERE event_id = ?").get(id), row);
  });
});

// ---------------------------------------------------------------------------
// G4 (server)
// ---------------------------------------------------------------------------

describe("G4: a series PUT sent to an id whose own row is linked clears that row's state", () => {
  const S1 = "g4ser_20261110T150000Z";
  const S2 = "g4ser_20261111T150000Z";
  const START = "2026-11-10T15:00:00.000Z";
  const END = "2026-11-10T16:00:00.000Z";
  const two = () => [meeting(S1, START, END), meeting(S2, "2026-11-11T15:00:00.000Z", "2026-11-11T16:00:00.000Z")];

  for (const state of ["not_joined", "unlinked"] as const) {
    it(`"All of them" (${state}) on a meeting that said linked leaves the tapped meeting out too`, async () => {
      const w = await world({ extra: two() });
      await w.set(S1, { scope: "event", state: "linked" });
      assert.equal(w.row(`event:${S1}`)?.state, "linked");
      const r = await w.put(S1, { scope: "series", state });
      assert.equal(r.status, 200, r.text);
      await w.settle();
      assert.equal(r.body.excluded, true, "the answer says it is out");
      assert.equal(r.body.override.state, state);
      assert.equal(r.body.override.scope, "series", "the series rule now decides");
      assert.equal(w.row(`event:${S1}`), undefined, "its own `linked` is gone (a row with nothing left is removed)");
      assert.equal(w.row("series:g4ser")?.state, state);
      assert.equal((await view(w, "2026-11-10", S1)).excluded, true);
      assert.equal((await view(w, "2026-11-11", S2)).excluded, true, "the rest of the series is out as before");
    });
  }

  it("its times stay when its state is cleared", async () => {
    const w = await world({ extra: two() });
    await w.set(S1, { scope: "event", state: "linked", startUtc: "2026-11-10T14:45:00Z", endUtc: "2026-11-10T16:20:00Z" });
    const r = await w.put(S1, { scope: "series", state: "not_joined" });
    assert.equal(r.status, 200, r.text);
    await w.settle();
    const own = w.row(`event:${S1}`);
    assert.ok(own, "the row stays because it still has times");
    assert.equal(own.state, null);
    assert.equal(ms(own.start_utc), ms("2026-11-10T14:45:00Z"));
    assert.equal(ms(own.end_utc), ms("2026-11-10T16:20:00Z"));
    assert.equal(r.body.excluded, true);
    assert.equal(ms(r.body.startUtc), ms("2026-11-10T14:45:00Z"), "the effective times are still the owner's");
    assert.equal(ms(r.body.endUtc), ms("2026-11-10T16:20:00Z"));
  });

  it("only the meeting the PUT was sent to is cleared: another instance that said linked stays in", async () => {
    const w = await world({ extra: two() });
    await w.set(S1, { scope: "event", state: "linked" });
    await w.set(S2, { scope: "event", state: "linked" });
    const r = await w.put(S1, { scope: "series", state: "not_joined" });
    assert.equal(r.status, 200, r.text);
    await w.settle();
    assert.equal(w.row(`event:${S1}`), undefined);
    assert.equal(w.row(`event:${S2}`)?.state, "linked", "its own choice still beats the series");
    assert.ok(!(await view(w, "2026-11-11", S2)).excluded);
  });

  it("an own choice that is not linked is left alone, and so is a meeting with no row of its own", async () => {
    const w = await world({ extra: two() });
    await w.set(S1, { scope: "event", state: "unlinked" });
    assert.equal((await w.put(S1, { scope: "series", state: "not_joined" })).status, 200);
    await w.settle();
    assert.equal(w.row(`event:${S1}`)?.state, "unlinked", "its own exclusion is not rewritten");

    const w2 = await world({ extra: two() });
    assert.equal((await w2.put(S2, { scope: "series", state: "not_joined" })).status, 200);
    await w2.settle();
    assert.deepEqual(w2.rows().map((r) => r.key), ["series:g4ser"], "no event row is made up");
  });

  it("the web plan for \"All of them\" is one series request, which relies on the server for the tapped meeting", () => {
    const e = { id: S1, override: { state: "linked", scope: "event", seriesId: "g4ser" } };
    const ask = planAction("not_joined", e);
    assert.equal(ask.mode, "scope");
    const plan = planAction("scope-series", e, { pending: ask.pending });
    assert.deepEqual(plan, { body: { scope: "series", state: "not_joined" } });
  });
});

// ---------------------------------------------------------------------------
// G6
// ---------------------------------------------------------------------------

describe("G6: a validation error on the times form keeps what was typed", () => {
  const e = { id: "g6", startUtc: "2026-11-10T15:00:00.000Z", endUtc: "2026-11-10T16:00:00.000Z", override: null };
  const value = (html: string, name: string) => new RegExp(`name="${name}" value="([^"]*)"`).exec(html)?.[1];

  it("shows the saved times when nothing was typed", () => {
    const html = actionsHtml(e, { id: "g6", mode: "times" }, "America/New_York");
    assert.equal(value(html, "start"), "2026-11-10T10:00");
    assert.equal(value(html, "end"), "2026-11-10T11:00");
  });

  it("shows what was typed, with the error, instead of the saved times", () => {
    const ui = { id: "g6", mode: "times", error: "The end has to be after the start.", typed: { start: "2026-11-10T12:00", end: "2026-11-10T09:30" } };
    const html = actionsHtml(e, ui, "America/New_York");
    assert.equal(value(html, "start"), "2026-11-10T12:00");
    assert.equal(value(html, "end"), "2026-11-10T09:30");
    assert.match(html, /The end has to be after the start\./);
    assert.match(html, /<form class="mtimes"/, "the form stays open");
  });

  it("keeps an empty field empty, and a half typed pair as typed", () => {
    const ui = { id: "g6", mode: "times", error: "Pick a start and an end.", typed: { start: "2026-11-10T12:00", end: "" } };
    const html = actionsHtml(e, ui, "America/New_York");
    assert.equal(value(html, "start"), "2026-11-10T12:00");
    assert.equal(value(html, "end"), "", "an emptied field is not refilled with the saved time");
  });

  it("typed text for another meeting is not shown on this one", () => {
    const other = { id: "g6b", startUtc: "2026-11-10T20:00:00.000Z", endUtc: "2026-11-10T21:00:00.000Z", override: null };
    const html = actionsHtml(other, { id: "g6", mode: "times", typed: { start: "2026-11-10T12:00", end: "2026-11-10T09:30" } }, "America/New_York");
    assert.doesNotMatch(html, /mtimes/);
  });

  it("app.js hands the typed text to the form when it shows the error", () => {
    // app.js is a browser module with no DOM here, so this reads the handler's error branch.
    const src = readFileSync(new URL("../public/app.js", import.meta.url), "utf8");
    const from = src.indexOf("if (picked.error)");
    assert.ok(from > 0, "the times form submit handler is where it was");
    const branch = src.slice(from, src.indexOf("commitMeetingChange(form.dataset.id", from));
    assert.match(branch, /typed/, "the error branch records what was typed in state.meetingUi");
    assert.match(branch, /form\.elements\.start\.value/);
    assert.match(branch, /form\.elements\.end\.value/);
  });
});

// ---------------------------------------------------------------------------
// G7
// ---------------------------------------------------------------------------

describe("G7: seen times and seen_none after the calendar start moved", () => {
  // The calendar moved the meeting to 15:30 to 16:30 (the Mac saw Zoom around the old 15:00 to 16:00).
  const CS = "2026-11-10T15:30:00.000Z";
  const CE = "2026-11-10T16:30:00.000Z";

  async function seen(id: string, row: { seenStart?: string; seenEnd?: string; seenNone?: boolean; updatedAt?: string }) {
    const w = await world({ extra: [meeting(id, CS, CE)] });
    w.raw.prepare(
      "INSERT INTO meeting_override (key, seen_start_utc, seen_end_utc, seen_none, updated_at) VALUES (?, ?, ?, ?, ?)",
    ).run(`event:${id}`, row.seenStart ?? null, row.seenEnd ?? null, row.seenNone ? 1 : 0, row.updatedAt ?? "2026-11-10T17:00:00.000Z");
    return view(w, "2026-11-10", id);
  }

  it("a seen start earlier than 15 minutes before the calendar start is ignored", async () => {
    const e = await seen("g7a", { seenStart: "2026-11-10T15:00:00.000Z", seenEnd: "2026-11-10T16:20:00.000Z" });
    assert.equal(ms(e.startUtc), ms(CS), "the start stays on the calendar");
    assert.equal(ms(e.endUtc), ms("2026-11-10T16:20:00.000Z"), "the seen end is inside the limits and counts");
  });

  it("the start limit is exactly 15 minutes before the calendar start", async () => {
    const on = await seen("g7b", { seenStart: "2026-11-10T15:15:00.000Z", seenEnd: "2026-11-10T16:20:00.000Z" });
    assert.equal(ms(on.startUtc), ms("2026-11-10T15:15:00.000Z"), "15 minutes early is used");
    const past = await seen("g7c", { seenStart: "2026-11-10T15:14:59.000Z", seenEnd: "2026-11-10T16:20:00.000Z" });
    assert.equal(ms(past.startUtc), ms(CS), "1 s earlier is ignored");
  });

  it("a seen end is used up to 4 hours after the calendar end and not a second more", async () => {
    const on = await seen("g7d", { seenStart: "2026-11-10T15:35:00.000Z", seenEnd: "2026-11-10T20:30:00.000Z" });
    assert.equal(ms(on.endUtc), ms("2026-11-10T20:30:00.000Z"));
    const past = await seen("g7e", { seenStart: "2026-11-10T15:35:00.000Z", seenEnd: "2026-11-10T20:30:01.000Z" });
    assert.equal(ms(past.endUtc), ms(CE));
  });

  it("a seen end that lies before the calendar window opens is ignored", async () => {
    const e = await seen("g7f", { seenStart: "2026-11-10T15:20:00.000Z", seenEnd: "2026-11-10T15:10:00.000Z" });
    assert.equal(ms(e.startUtc), ms("2026-11-10T15:20:00.000Z"));
    assert.equal(ms(e.endUtc), ms(CE));
  });

  it("the owner's own times keep the old 2 h and 4 h limits", async () => {
    const w = await world({ extra: [meeting("g7g", CS, CE)] });
    await w.set("g7g", { scope: "event", startUtc: "2026-11-10T14:00:00Z", endUtc: "2026-11-10T20:30:00Z" });
    const e = await view(w, "2026-11-10", "g7g");
    assert.equal(ms(e.startUtc), ms("2026-11-10T14:00:00.000Z"), "1.5 h early by the owner's choice");
    assert.equal(ms(e.endUtc), ms("2026-11-10T20:30:00.000Z"));
  });

  it("seen times from a route report still count when they are inside the limits", async () => {
    const w = await world({ extra: [meeting("g7h", CS, CE)] });
    const r = await w.attend({ meetingStartUtc: CS, title: "Follow g7h", seenStartUtc: "2026-11-10T15:32:00.000Z", seenEndUtc: "2026-11-10T16:10:00.000Z", seenNone: false });
    assert.equal(r.body?.matched, true);
    const e = await view(w, "2026-11-10", "g7h");
    assert.equal(ms(e.startUtc), ms("2026-11-10T15:32:00.000Z"));
    assert.equal(ms(e.endUtc), ms("2026-11-10T16:10:00.000Z"));
  });

  it("seen_none stored before the calendar end (so before the meeting could have happened as it stands) is ignored", async () => {
    const early = await seen("g7i", { seenNone: true, updatedAt: "2026-11-10T16:00:00.000Z" }); // calendar end is 16:30
    assert.equal(early.override.seenNone, false, "stored before the meeting's calendar end: it was about another time");
    const late = await seen("g7j", { seenNone: true, updatedAt: "2026-11-10T16:31:00.000Z" });
    assert.equal(late.override.seenNone, true, "stored after the calendar end: counts");
  });

  it("a rescheduled event: seen_none and seen times saved for the old time stop counting", async () => {
    const id = "g7k";
    const w = await world({ extra: [meeting(id, "2026-11-10T15:00:00.000Z", "2026-11-10T16:00:00.000Z"), meeting(`${id}b`, "2026-11-10T18:00:00.000Z", "2026-11-10T19:00:00.000Z")] });
    // Saved as the Mac would after the old time passed, then the calendar moves both meetings to the future.
    w.raw.prepare("INSERT INTO meeting_override (key, seen_none, updated_at) VALUES (?, 1, '2026-11-10T16:05:00.000Z')").run(`event:${id}`);
    w.raw.prepare("INSERT INTO meeting_override (key, seen_start_utc, seen_end_utc, seen_none, updated_at) VALUES (?, '2026-11-10T18:02:00.000Z', '2026-11-10T18:50:00.000Z', 0, '2026-11-10T19:00:00.000Z')").run(`event:${id}b`);
    assert.equal((await view(w, "2026-11-10", id)).override.seenNone, true, "before the move it counts");
    w.raw.prepare("UPDATE calendar_event SET start_utc = '2026-11-10T20:00:00.000Z', end_utc = '2026-11-10T21:00:00.000Z', day = '2026-11-10', duration_s = 3600 WHERE id = ?").run(id);
    assert.equal((await view(w, "2026-11-10", id)).override.seenNone, false, "after the calendar end moved past updated_at it does not");
    w.raw.prepare("UPDATE calendar_event SET start_utc = '2026-11-10T20:30:00.000Z', end_utc = '2026-11-10T21:30:00.000Z', duration_s = 3600 WHERE id = ?").run(`${id}b`);
    const e = await view(w, "2026-11-10", `${id}b`);
    assert.equal(ms(e.startUtc), ms("2026-11-10T20:30:00.000Z"), "a seen start from the old time does not pull the moved meeting back");
  });
});
