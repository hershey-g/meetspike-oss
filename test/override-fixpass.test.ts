import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it, mock } from "node:test";
import { api } from "../src/routes/api.ts";
import { overrideUrl, planAction, readTimes, saveOverride } from "../public/meeting-actions.js";
import { ADMIN, insertEvent, MIN, seedHr, world, type Ev, type World } from "./override-world.ts";

/**
 * Build 9 fix pass (fix9.md): F2 undo re-projects stored heart rate, F5 a moved
 * window may last 12 h, F6 limits answer 400, F8 web Undo sends `linked`.
 * The Swift halves of those items are tested in the Swift packages.
 */

const HOUR = 60 * MIN;
const ms = (s: string) => Date.parse(s);
const iso = (n: number) => new Date(n).toISOString();
const meeting = (id: string, start: string, end: string, extra: Partial<Ev> = {}): Ev =>
  ({ id, start, end, title: `Fix ${id}`, people: [], hr: null, ...extra });

/** One stored raw reading a minute, from `from` to `to` (inclusive), as the Mac's ingest writes them. */
function putRaw(w: World, from: number, to: number, bpm: (t: number) => number = () => 70) {
  const insert = w.raw.prepare("INSERT OR REPLACE INTO whoop_web_hr_raw (user_id, source, time_ms, bpm, received_at) VALUES ('owner', 'ble', ?, ?, 't')");
  w.raw.exec("BEGIN");
  for (let t = from; t <= to; t += MIN) insert.run(t, bpm(t));
  w.raw.exec("COMMIT");
}

const hrRow = (w: World, id: string) =>
  w.raw.prepare("SELECT window_start_utc, window_end_utc, sample_count, status, fetched_at FROM whoop_web_hr WHERE event_id = ?").get(id) as any;

async function view(w: World, day: string, id: string) {
  const e = (await w.get(`/view?date=${day}`)).day.calendar.events.find((x: any) => x.id === id);
  assert.ok(e, `${id} is listed on ${day}`);
  return e;
}

// ---------------------------------------------------------------------------
// F2
// ---------------------------------------------------------------------------

describe("F2: putting an excluded meeting back projects the heart rate stored while it was out", () => {
  const START = "2026-11-10T15:00:00.000Z";
  const END = "2026-11-10T16:00:00.000Z";
  const SER = "f2ser_20261110T150000Z";

  // [label, id, choices made first (in order), the PUT that puts it back, comes back?]
  type Step = { scope: "event" | "series"; state: "not_joined" | "unlinked" | "linked" | null };
  const CASES: Array<[string, string, Step[], Step, boolean]> = [
    ["event not_joined, state null", "f2a", [{ scope: "event", state: "not_joined" }], { scope: "event", state: null }, true],
    ["event unlinked, state linked", "f2b", [{ scope: "event", state: "unlinked" }], { scope: "event", state: "linked" }, true],
    ["series unlinked, event linked", SER, [{ scope: "series", state: "unlinked" }], { scope: "event", state: "linked" }, true],
    ["series not_joined, series cleared", SER, [{ scope: "series", state: "not_joined" }], { scope: "series", state: null }, true],
    ["series unlinked, series linked", SER, [{ scope: "series", state: "unlinked" }], { scope: "series", state: "linked" }, true],
    ["event and series excluded, event linked", SER, [{ scope: "series", state: "unlinked" }, { scope: "event", state: "not_joined" }], { scope: "event", state: "linked" }, true],
    // Still excluded afterwards: nothing may be projected.
    ["event and series excluded, event cleared (the series still leaves it out)", SER, [{ scope: "series", state: "unlinked" }, { scope: "event", state: "not_joined" }], { scope: "event", state: null }, false],
    ["series cleared while the event is excluded on its own", SER, [{ scope: "series", state: "unlinked" }, { scope: "event", state: "not_joined" }], { scope: "series", state: null }, false],
  ];

  for (const [label, id, first, back, comes] of CASES) {
    it(comes ? `${label}: the stored raw rows become the series, bounded to the meeting window` : `${label}: stays out, no series is built`, async () => {
      const w = await world({ extra: [meeting(id, START, END)] });
      putRaw(w, ms(START) - 20 * MIN, ms(END) + 20 * MIN);
      for (const step of first) await w.set(id, step);
      assert.equal(hrRow(w, id), undefined, "nothing was built while it was out");
      const rawBefore = (w.raw.prepare("SELECT COUNT(*) AS n FROM whoop_web_hr_raw").get() as any).n;
      await w.set(id, back);
      if (!comes) {
        assert.equal(hrRow(w, id), undefined);
        return;
      }
      const row = hrRow(w, id);
      assert.ok(row, "the series is built without waiting for another upload");
      assert.equal(row.window_start_utc, "2026-11-10T14:50:00.000Z");
      assert.equal(row.window_end_utc, "2026-11-10T16:10:00.000Z");
      assert.equal(row.sample_count, 81);
      assert.equal((w.raw.prepare("SELECT COUNT(*) AS n FROM whoop_web_hr_raw").get() as any).n, rawBefore, "raw rows are kept");
      assert.equal((await view(w, "2026-11-10", id)).hrStress?.meanBpm, 70, "and it scores");
    });
  }

  it("the work runs in waitUntil, so the PUT does not wait for it", async () => {
    const w = await world({ extra: [meeting("f2w", START, END)] });
    putRaw(w, ms(START) - 20 * MIN, ms(END) + 20 * MIN);
    await w.set("f2w", { scope: "event", state: "not_joined" });
    const queued: Promise<unknown>[] = [];
    const ctx = { waitUntil: (p: Promise<unknown>) => void queued.push(p), passThroughOnException: () => {} };
    const res = await api.request(`https://app.example/meetings/f2w/override`, {
      method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ scope: "event", state: null }),
    }, w.env as never, ctx as never);
    assert.equal(res.status, 200);
    assert.ok(queued.length >= 1, "the re-projection was handed to waitUntil");
    await Promise.all(queued);
    assert.ok(hrRow(w, "f2w"));

    // The same for a series choice.
    const sid = "f2ws_20261111T150000Z";
    const w2 = await world({ extra: [meeting(sid, "2026-11-11T15:00:00.000Z", "2026-11-11T16:00:00.000Z")] });
    putRaw(w2, ms("2026-11-11T14:40:00.000Z"), ms("2026-11-11T16:20:00.000Z"));
    await w2.set(sid, { scope: "series", state: "unlinked" });
    const queued2: Promise<unknown>[] = [];
    const ctx2 = { waitUntil: (p: Promise<unknown>) => void queued2.push(p), passThroughOnException: () => {} };
    const res2 = await api.request(`https://app.example/meetings/${sid}/override`, {
      method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ scope: "series", state: null }),
    }, w2.env as never, ctx2 as never);
    assert.equal(res2.status, 200);
    assert.ok(queued2.length >= 1, "the series re-projection was handed to waitUntil");
    await Promise.all(queued2);
    assert.ok(hrRow(w2, sid));
  });

  it("a failed re-projection leaves the old stored series and the PUT still answers 200", async () => {
    const w = await world({ extra: [meeting("f2f", START, END)] });
    putRaw(w, ms(START) - 20 * MIN, ms(END) + 20 * MIN);
    // Build a series, then leave the meeting out: the stored series is kept while it is out.
    await w.set("f2f", { scope: "event", state: "not_joined" });
    await w.set("f2f", { scope: "event", state: null });
    await w.set("f2f", { scope: "event", state: "not_joined" });
    const before = hrRow(w, "f2f");
    assert.ok(before);
    w.raw.exec("DROP TABLE whoop_web_hr_raw");
    const r = await w.put("f2f", { scope: "event", state: null });
    assert.equal(r.status, 200, r.text);
    await w.settle();
    assert.deepEqual(hrRow(w, "f2f"), before);
    assert.equal(r.body.excluded, false, "the choice itself is saved");
  });

  it("a series choice re-projects every affected instance that has stored raw rows, and no other", async () => {
    const ids = ["f2s_20261109T150000Z", "f2s_20261110T150000Z", "f2s_20261111T150000Z", "f2s_20261112T150000Z"];
    const days = ["2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12"];
    const w = await world({ extra: ids.map((id, i) => meeting(id, `${days[i]}T15:00:00.000Z`, `${days[i]}T15:30:00.000Z`)) });
    // The third instance has no raw rows. The fourth is excluded on its own and stays so.
    for (const i of [0, 1, 3]) putRaw(w, ms(`${days[i]}T14:40:00.000Z`), ms(`${days[i]}T15:50:00.000Z`));
    await w.set(ids[0], { scope: "series", state: "unlinked" });
    await w.set(ids[3], { scope: "event", state: "not_joined" });
    await w.set(ids[0], { scope: "series", state: null });
    assert.ok(hrRow(w, ids[0]));
    assert.ok(hrRow(w, ids[1]));
    assert.equal(hrRow(w, ids[2]), undefined, "no raw rows, no row (and no empty row either)");
    assert.equal(hrRow(w, ids[3]), undefined, "still excluded by its own choice");
  });

  it("a series with many instances re-projects at most the 60 newest", async () => {
    const day0 = ms("2026-09-01T15:00:00.000Z");
    const ids: string[] = [];
    const events: Ev[] = [];
    for (let d = 0; d < 62; d++) {
      const start = day0 + d * 86_400_000;
      const id = `f2big_${iso(start).slice(0, 10).replaceAll("-", "")}T150000Z`;
      ids.push(id);
      events.push(meeting(id, iso(start), iso(start + 30 * MIN)));
    }
    const w = await world({ extra: events });
    for (let d = 0; d < 62; d++) putRaw(w, day0 + d * 86_400_000 - 15 * MIN, day0 + d * 86_400_000 + 45 * MIN);
    await w.set(ids[0], { scope: "series", state: "unlinked" });
    await w.set(ids[0], { scope: "series", state: null });
    const built = ids.filter((id) => hrRow(w, id));
    assert.equal(built.length, 60);
    assert.deepEqual(ids.filter((id) => !hrRow(w, id)), ids.slice(0, 2), "the two oldest are the ones left out");
  });

  it("a 9 h calendar meeting is still not projected when it comes back (the 8 h limit holds for calendar times)", async () => {
    const w = await world({ extra: [meeting("f2long", "2026-11-10T12:00:00.000Z", "2026-11-10T21:00:00.000Z")] });
    putRaw(w, ms("2026-11-10T11:00:00.000Z"), ms("2026-11-10T22:00:00.000Z"));
    await w.set("f2long", { scope: "event", state: "not_joined" });
    await w.set("f2long", { scope: "event", state: null });
    assert.equal(hrRow(w, "f2long"), undefined);
  });
});

// ---------------------------------------------------------------------------
// F5
// ---------------------------------------------------------------------------

describe("F5: a window the owner moved may be up to 12 h, a calendar window still only 8 h", () => {
  // Calendar 14:00 to 18:00 UTC (4 h). Moved to 12:00 to 22:00: 10 h.
  const CAL: [string, string] = ["2026-11-10T14:00:00.000Z", "2026-11-10T18:00:00.000Z"];
  const MOVED = { startUtc: "2026-11-10T12:00:00.000Z", endUtc: "2026-11-10T22:00:00.000Z" };

  it("scores a moved 10 h meeting on its detail and in the day list", async () => {
    const w = await world({ extra: [meeting("mv1", ...CAL)] });
    await w.set("mv1", { scope: "event", ...MOVED });
    await seedHr(w.db, { id: "mv1", start: MOVED.startUtc, end: MOVED.endUtc }, 80);
    const detail = await w.get("/meetings/mv1/hr?fill=0");
    assert.equal(detail.hrStress?.coverage, "ok", "scored");
    assert.equal(detail.hrStress?.meanBpm, 80);
    assert.equal(ms(detail.window.endUtc) - ms(detail.window.startUtc), 10 * HOUR);
    assert.equal((await view(w, "2026-11-10", "mv1")).hrStress?.meanBpm, 80, "and in the day list");
  });

  it("does not score a 9 h calendar meeting in the day list", async () => {
    const w = await world({ extra: [meeting("cal9", "2026-11-10T14:00:00.000Z", "2026-11-10T23:00:00.000Z")] });
    await seedHr(w.db, { id: "cal9", start: "2026-11-10T14:00:00.000Z", end: "2026-11-10T23:00:00.000Z" }, 90);
    assert.notEqual((await view(w, "2026-11-10", "cal9")).hrStress?.coverage, "ok");
  });

  it("re-projects stored heart rate over a moved 10 h window", async () => {
    const w = await world({ extra: [meeting("mv1", ...CAL)] });
    putRaw(w, ms("2026-11-10T11:00:00.000Z"), ms("2026-11-10T23:00:00.000Z"));
    assert.equal(hrRow(w, "mv1"), undefined);
    await w.set("mv1", { scope: "event", ...MOVED });
    const row = hrRow(w, "mv1");
    assert.ok(row, "projected");
    assert.equal(row.window_start_utc, "2026-11-10T11:50:00.000Z");
    assert.equal(row.window_end_utc, "2026-11-10T22:10:00.000Z");
    assert.equal(row.sample_count, 621);
  });

  it("a moved window of exactly 12 h is projected", async () => {
    // 9 h calendar entry, 15:00 to 00:00. The owner moves the start 2 h early and the end 1 h late: 12 h.
    const w = await world({ extra: [meeting("mv12", "2026-11-10T15:00:00.000Z", "2026-11-11T00:00:00.000Z")] });
    putRaw(w, ms("2026-11-10T12:00:00.000Z"), ms("2026-11-11T02:00:00.000Z"));
    await w.set("mv12", { scope: "event", startUtc: "2026-11-10T13:00:00.000Z", endUtc: "2026-11-11T01:00:00.000Z" });
    const row = hrRow(w, "mv12");
    assert.ok(row, "a 12 h moved window is projected");
    assert.equal(row.window_start_utc, "2026-11-10T12:50:00.000Z");
    assert.equal(row.window_end_utc, "2026-11-11T01:10:00.000Z");
  });

  describe("live, ingest", () => {
    const NOW = Date.parse("2026-11-14T15:00:00.000Z");
    const AUTH = { authorization: `Bearer ${ADMIN}`, "content-type": "application/json" };
    const LIVE_HR = { idFromName: () => "x", get: () => ({ fetch: async () => Response.json({ ok: true, points: [], cursor: 0 }) }) };
    const at = (id: string, fromNow: [number, number]): Ev =>
      meeting(id, iso(NOW + fromNow[0] * MIN), iso(NOW + fromNow[1] * MIN));
    const live = (w: World) => w.call("/whoop-web/live", {
      method: "POST", headers: AUTH, body: JSON.stringify({ version: 1, points: [[NOW, 80]], includeMeeting: true }),
    }, { ...w.env, LIVE_HR });
    const liveHr = (w: World, id: string) => w.call(`/meetings/${id}/live-hr`, {}, { ...w.env, LIVE_HR });

    beforeEach(() => mock.timers.enable({ apis: ["Date"], now: NOW }));
    afterEach(() => mock.timers.reset());

    it("a meeting moved to a 9 h window is the live meeting and has a live window", async () => {
      const w = await world({ extra: [at("lv9", [-120, 60])] });
      await w.set("lv9", { scope: "event", startUtc: iso(NOW - 240 * MIN), endUtc: iso(NOW + 300 * MIN) });
      const r = await live(w);
      assert.equal(r.body.meeting?.id, "lv9");
      assert.equal(ms(r.body.meeting.endUtc) - ms(r.body.meeting.startUtc), 9 * HOUR);
      const win = await liveHr(w, "lv9");
      assert.equal(win.status, 200);
      assert.equal(win.body.active, true);
      assert.equal(win.body.window.startMs, NOW - 240 * MIN);
      assert.equal(win.body.window.endMs, NOW + 300 * MIN);
    });

    it("a moved meeting that started more than 8 h ago is still live (up to 12 h back)", async () => {
      // Calendar 500 to 240 minutes ago. Start 2 h earlier (620 min ago), end 4 h later (now): 10 h 20 min.
      const w = await world({ extra: [at("lv10", [-500, -240])] });
      await w.set("lv10", { scope: "event", startUtc: iso(NOW - 620 * MIN), endUtc: iso(NOW) });
      assert.equal((await live(w)).body.meeting?.id, "lv10");
      assert.equal((await liveHr(w, "lv10")).body.active, true);
    });

    it("a 9 h calendar meeting is still not live", async () => {
      const w = await world({ extra: [at("lvcal", [-300, 240])] });
      assert.equal((await live(w)).body.meeting ?? null, null);
      assert.equal((await liveHr(w, "lvcal")).status, 404);
    });

    const span: [number, number] = [NOW - 640 * MIN, NOW - 50 * MIN];
    const post = (w: World) => {
      const points: Array<[number, number]> = [];
      for (let t = span[0]; t <= span[1]; t += MIN) points.push([t, 80]);
      return w.call("/whoop-web/ingest", {
        method: "POST", headers: AUTH,
        body: JSON.stringify({ version: 1, fetchedAt: iso(NOW - 60_000), hr: { spans: [{ startMs: span[0], endMs: span[1] }], points } }),
      });
    };

    it("ingest builds the series of a meeting moved to a 9 h window, and not of a 9 h calendar meeting", async () => {
      // Calendar 500 to 320 minutes ago. Start 2 h early (620 ago), end 4 h late (80 ago): 9 h.
      const w = await world({ extra: [at("ing1", [-500, -320]), at("ing9", [-700, -160])] });
      await w.set("ing1", { scope: "event", startUtc: iso(NOW - 620 * MIN), endUtc: iso(NOW - 80 * MIN) });
      const r = await post(w);
      assert.equal(r.status, 200, r.text);
      const row = hrRow(w, "ing1");
      assert.ok(row, "projected over the moved window");
      assert.equal(row.window_start_utc, iso(NOW - 630 * MIN));
      assert.equal(row.window_end_utc, iso(NOW - 70 * MIN));
      assert.equal(row.sample_count, 561);
      assert.equal(hrRow(w, "ing9"), undefined, "a 9 h calendar meeting is not projected");
    });
  });
});

// ---------------------------------------------------------------------------
// F6
// ---------------------------------------------------------------------------

describe("F6: times outside the limits are refused with 400 and nothing is stored", () => {
  // 15:00 to 16:00 UTC. Limits: start from 13:00, end to 20:00, window up to 12 h.
  const CAL = { start: "2026-11-10T15:00:00.000Z", end: "2026-11-10T16:00:00.000Z" };
  // 9 h: 15:00 to 00:00. Start from 13:00, end to 04:00.
  const LONG = { start: "2026-11-10T15:00:00.000Z", end: "2026-11-11T00:00:00.000Z" };

  async function setup() {
    return world({ extra: [meeting("lim1", CAL.start, CAL.end), meeting("lim2", LONG.start, LONG.end)] });
  }

  const REFUSED: Array<[string, string, Record<string, unknown>]> = [
    ["a start 1 s more than 2 h before the calendar start", "lim1", { startUtc: "2026-11-10T12:59:59Z" }],
    ["an end 1 s more than 4 h after the calendar end", "lim1", { endUtc: "2026-11-10T20:00:01Z" }],
    ["an end equal to the start (both sent)", "lim1", { startUtc: "2026-11-10T15:30:00Z", endUtc: "2026-11-10T15:30:00Z" }],
    ["an end before the start (both sent)", "lim1", { startUtc: "2026-11-10T15:30:00Z", endUtc: "2026-11-10T15:00:00Z" }],
    ["only an end, not after the calendar start", "lim1", { endUtc: "2026-11-10T14:30:00Z" }],
    ["only an end equal to the calendar start", "lim1", { endUtc: "2026-11-10T15:00:00Z" }],
    ["only a start, not before the calendar end", "lim1", { startUtc: "2026-11-10T16:30:00Z" }],
    ["only a start equal to the calendar end", "lim1", { startUtc: "2026-11-10T16:00:00Z" }],
    ["a cleared start with an end before the calendar start", "lim1", { startUtc: null, endUtc: "2026-11-10T14:30:00Z" }],
    ["a window of 12 h and 1 s (both sent)", "lim2", { startUtc: "2026-11-10T13:00:00Z", endUtc: "2026-11-11T01:00:01Z" }],
    ["a window of 12 h and 1 s (only an end)", "lim2", { endUtc: "2026-11-11T03:00:01Z" }],
    ["a window of 15 h", "lim2", { startUtc: "2026-11-10T13:00:00Z", endUtc: "2026-11-11T04:00:00Z" }],
  ];

  for (const [label, id, times] of REFUSED) {
    it(`refuses ${label}`, async () => {
      const w = await setup();
      const r = await w.put(id, { scope: "event", ...times });
      assert.equal(r.status, 400, r.text);
      assert.equal(typeof r.body?.error, "string");
      assert.ok(r.body.error.length > 0 && r.body.error.length <= 120, `short message: ${r.body.error}`);
      assert.ok(!r.body.error.includes("—"), "plain words, no dash");
      await w.settle();
      assert.deepEqual(w.rows(), [], "nothing is stored");
      const e = await view(w, "2026-11-10", id);
      assert.equal(e.override?.startUtc ?? null, null);
      assert.equal(e.override?.endUtc ?? null, null);
    });
  }

  it("a refused PUT stores nothing at all, not even the state sent with the bad time", async () => {
    const w = await setup();
    const r = await w.put("lim1", { scope: "event", state: "not_joined", endUtc: "2026-11-10T20:00:01Z" });
    assert.equal(r.status, 400, r.text);
    assert.deepEqual(w.rows(), []);
    assert.equal((await view(w, "2026-11-10", "lim1")).excluded ?? false, false);
  });

  it("a refused PUT leaves an earlier choice exactly as it was", async () => {
    const w = await setup();
    await w.set("lim1", { scope: "event", state: "not_joined", startUtc: "2026-11-10T14:30:00Z" });
    const before = w.rows();
    const r = await w.put("lim1", { scope: "event", endUtc: "2026-11-10T20:00:01Z" });
    assert.equal(r.status, 400, r.text);
    assert.deepEqual(w.rows(), before);
  });

  it("accepts the limits themselves", async () => {
    const w = await setup();
    // 2 h early and 4 h late: a 7 h window.
    await w.set("lim1", { scope: "event", startUtc: "2026-11-10T13:00:00Z", endUtc: "2026-11-10T20:00:00Z" });
    // Exactly 12 h.
    await w.set("lim2", { scope: "event", startUtc: "2026-11-10T13:00:00Z", endUtc: "2026-11-11T01:00:00Z" });
    // A shorter or later window inside the calendar one is fine too, and null always clears.
    await w.set("lim1", { scope: "event", startUtc: "2026-11-10T15:10:00Z", endUtc: "2026-11-10T15:50:00Z" });
    await w.set("lim1", { scope: "event", startUtc: null, endUtc: null });
    assert.deepEqual(w.rows().map((r) => r.key), ["event:lim2"]);
  });

  it("checks a lone time against the other effective value, whatever set it", async () => {
    const w = await setup();
    // The owner's start is 15:30. An end of 15:20 is before it, though after the calendar start.
    await w.set("lim1", { scope: "event", startUtc: "2026-11-10T15:30:00Z" });
    const early = await w.put("lim1", { scope: "event", endUtc: "2026-11-10T15:20:00Z" });
    assert.equal(early.status, 400, early.text);
    assert.equal(w.row("event:lim1")?.end_utc ?? null, null);
    // The Mac saw the call end at 15:50 (no owner end). A start of 15:55 is after that.
    const w2 = await setup();
    const sight = await w2.attend({ meetingStartUtc: CAL.start, title: "Fix lim1", seenStartUtc: "2026-11-10T15:02:00Z", seenEndUtc: "2026-11-10T15:50:00Z", seenNone: false });
    assert.equal(sight.body?.matched, true);
    const late = await w2.put("lim1", { scope: "event", startUtc: "2026-11-10T15:55:00Z" });
    assert.equal(late.status, 400, late.text);
    assert.equal(w2.row("event:lim1")?.start_utc ?? null, null);
  });

  it("answers an unknown meeting 404 and a series time 400 as before", async () => {
    const w = await setup();
    assert.equal((await w.put("nope", { scope: "event", endUtc: "2026-11-10T16:30:00Z" })).status, 404);
    const series = await world({ extra: [meeting("sx_20261110T150000Z", CAL.start, CAL.end)] });
    assert.equal((await series.put("sx_20261110T150000Z", { scope: "series", endUtc: "2026-11-10T16:30:00Z" })).status, 400);
  });
});

describe("F6 on the web: the times form checks the same limits and shows the server's message", () => {
  const TZ = "America/New_York";
  // Calendar 15:00 to 16:00 UTC is 10:00 to 11:00 in New York (EST).
  const e = { id: "w1", startUtc: "2026-11-10T15:00:00.000Z", endUtc: "2026-11-10T16:00:00.000Z", override: null as any };
  const form = (start: string, end: string) => ({ elements: { start: { value: start }, end: { value: end } } });
  const errorOf = (r: any) => {
    assert.equal(r.body, undefined, "nothing to send");
    assert.equal(typeof r.error, "string");
    assert.ok(r.error.length > 0 && r.error.length <= 120, r.error);
    assert.ok(!r.error.includes("—"));
    return r.error as string;
  };

  it("sends times inside the limits, calendar times from the meeting", () => {
    const r = readTimes(form("2026-11-10T08:00", "2026-11-10T15:00"), TZ, e) as any;
    assert.equal(r.error, undefined);
    assert.deepEqual(r.body, { scope: "event", startUtc: "2026-11-10T13:00:00.000Z", endUtc: "2026-11-10T20:00:00.000Z" });
  });

  it("refuses a start more than 2 h before the calendar start, an end more than 4 h after the calendar end", () => {
    errorOf(readTimes(form("2026-11-10T07:59", "2026-11-10T11:00"), TZ, e));
    errorOf(readTimes(form("2026-11-10T10:00", "2026-11-10T15:01"), TZ, e));
  });

  it("refuses an end that is not after the start", () => {
    errorOf(readTimes(form("2026-11-10T10:30", "2026-11-10T10:30"), TZ, e));
    errorOf(readTimes(form("2026-11-10T10:30", "2026-11-10T10:00"), TZ, e));
  });

  it("refuses a window over 12 h, and takes exactly 12 h", () => {
    const long = { ...e, endUtc: "2026-11-11T00:00:00.000Z" }; // 10:00 to 19:00 local
    const ok = readTimes(form("2026-11-10T08:00", "2026-11-10T20:00"), TZ, long) as any;
    assert.equal(ok.error, undefined, "12 h exactly");
    errorOf(readTimes(form("2026-11-10T08:00", "2026-11-10T20:01"), TZ, long));
  });

  it("measures against the calendar's times, not the times the meeting was moved to", () => {
    // Moved to 13:00 to 20:00 UTC already; the calendar still says 15:00 to 16:00.
    const moved = {
      ...e, startUtc: "2026-11-10T13:00:00.000Z", endUtc: "2026-11-10T20:00:00.000Z",
      override: { startUtc: "2026-11-10T13:00:00.000Z", endUtc: "2026-11-10T20:00:00.000Z", calendarStartUtc: e.startUtc, calendarEndUtc: e.endUtc },
    };
    // 07:30 local is 12:30 UTC: 30 minutes before the moved start, 2 h 30 min before the calendar start.
    errorOf(readTimes(form("2026-11-10T07:30", "2026-11-10T11:00"), TZ, moved));
    const ok = readTimes(form("2026-11-10T08:00", "2026-11-10T11:00"), TZ, moved) as any;
    assert.equal(ok.error, undefined);
  });

  it("keeps the old messages for a blank or reversed form", () => {
    errorOf(readTimes(form("", "2026-11-10T11:00"), TZ, e));
  });

  it("saveOverride hands the server's refusal to the form, and says nothing changed", async () => {
    const message = "The end can be at most 4 hours after the calendar end.";
    const api = async () => { throw Object.assign(new Error(message), { status: 400 }); };
    const r = await saveOverride(api, "w1", { scope: "event", endUtc: "2026-11-10T20:00:01Z" });
    assert.equal(r.ok, false);
    assert.ok((r as any).message.includes(message));
    assert.ok((r as any).message.includes("Nothing changed"));
  });
});

// ---------------------------------------------------------------------------
// F8 (web half)
// ---------------------------------------------------------------------------

describe("F8: web Undo brings back a meeting excluded by its own choice and by its series", () => {
  const ID = "ser1_20261110T160000Z";

  /** What the menu does for Undo, then (when asked which) "Just this one" / "All of them". Returns the PUT it sent. */
  async function undo(w: World, id: string, day: string, pick?: "scope-event" | "scope-series") {
    const e = await view(w, day, id);
    let plan = planAction("undo", e);
    assert.ok(plan, "Undo is offered");
    if (!(plan as any).body) {
      assert.equal((plan as any).mode, "scope");
      assert.ok(pick, "the menu asks which one");
      plan = planAction(pick!, e, { pending: (plan as any).pending });
    }
    const body = (plan as any)?.body;
    assert.ok(body, "a request to send");
    const r = await w.call(overrideUrl(id).replace(/^\/api/, ""), {
      method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
    });
    assert.equal(r.status, 200, r.text);
    await w.settle();
    return body;
  }

  it("event and series both exclude it: Undo puts this meeting back", async () => {
    const w = await world();
    await w.set(ID, { scope: "series", state: "unlinked" });
    await w.set(ID, { scope: "event", state: "not_joined" });
    assert.equal((await view(w, "2026-11-10", ID)).excluded, true);
    await undo(w, ID, "2026-11-10");
    const after = await view(w, "2026-11-10", ID);
    assert.equal(after.excluded ?? false, false, "it really comes back");
    // The other instances stay out: only this meeting was undone.
    assert.equal((await view(w, "2026-11-11", "ser1_20261111T160000Z")).excluded, true);
  });

  it("event and series both exclude it: the request says linked for the event", async () => {
    const w = await world();
    await w.set(ID, { scope: "series", state: "not_joined" });
    await w.set(ID, { scope: "event", state: "unlinked" });
    const body = await undo(w, ID, "2026-11-10");
    assert.deepEqual(body, { scope: "event", state: "linked" });
  });

  it("only the event is excluded (the series has no choice): Undo puts it back", async () => {
    const w = await world();
    await w.set(ID, { scope: "event", state: "not_joined" });
    await undo(w, ID, "2026-11-10");
    assert.equal((await view(w, "2026-11-10", ID)).excluded ?? false, false);
  });

  it("an event that is not in a series is put back by clearing its state, leaving no row behind", async () => {
    const w = await world();
    await w.set("evt-board", { scope: "event", state: "not_joined" });
    const body = await undo(w, "evt-board", "2026-11-11");
    assert.deepEqual(body, { scope: "event", state: null });
    assert.equal(w.row("event:evt-board"), undefined);
    assert.equal((await view(w, "2026-11-11", "evt-board")).excluded ?? false, false);
  });

  it("only the series is excluded: 'Just this one' puts one back, 'All of them' clears the series", async () => {
    const one = await world();
    await one.set(ID, { scope: "series", state: "unlinked" });
    await undo(one, ID, "2026-11-10", "scope-event");
    assert.equal((await view(one, "2026-11-10", ID)).excluded ?? false, false);
    assert.equal((await view(one, "2026-11-11", "ser1_20261111T160000Z")).excluded, true);

    const all = await world();
    await all.set(ID, { scope: "series", state: "unlinked" });
    await undo(all, ID, "2026-11-10", "scope-series");
    for (const [day, id] of [["2026-11-10", ID], ["2026-11-11", "ser1_20261111T160000Z"]] as const) {
      assert.equal((await view(all, day, id)).excluded ?? false, false);
    }
  });
});
