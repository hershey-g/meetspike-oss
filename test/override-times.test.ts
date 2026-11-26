import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import { syncCalendarIncremental } from "../src/sources/calendar/ingest.ts";
import { connectAccount } from "../src/sources/calendar/accounts.ts";
import { fakeKv } from "./sqlite-d1.ts";
import { MIN, world, type Ev, type World } from "./override-world.ts";

const ms = (s: string) => Date.parse(s);
const HOUR = 60 * MIN;

/** One extra meeting on Tue 10 Nov with a title of its own, so nothing folds into another. */
const meeting = (id: string, start: string, end: string, extra: Partial<Ev> = {}): Ev =>
  ({ id, start, end, title: `Case ${id}`, people: [], hr: null, ...extra });

async function view(w: World, day: string, id: string) {
  const e = (await w.get(`/view?date=${day}`)).day.calendar.events.find((x: any) => x.id === id);
  assert.ok(e, `${id} is listed on ${day}`);
  return e;
}

/** An owner row written straight to the table, past the route's limits. */
function storeRaw(w: World, id: string, body: { startUtc?: string; endUtc?: string }) {
  w.raw.prepare("INSERT INTO meeting_override (key, start_utc, end_utc, updated_at) VALUES (?, ?, ?, 't')")
    .run(`event:${id}`, body.startUtc ?? null, body.endUtc ?? null);
}

describe("effective times: user, then seen, then calendar, per field", () => {
  // Calendar 15:00 to 16:00 UTC (10:00 to 11:00 in New York).
  const CAL = { start: "2026-11-10T15:00:00.000Z", end: "2026-11-10T16:00:00.000Z" };
  // "stored": the PUT route refuses these now (fix pass 9, F6), so the row is written straight to the table,
  // like one left behind by an older build or by a calendar entry that moved later. Reads must still ignore it.
  const CASES: Array<[string, { startUtc?: string; endUtc?: string }, string, string, "stored"?]> = [
    ["both exactly at the limits (2 h early, 4 h late)", { startUtc: "2026-11-10T13:00:00Z", endUtc: "2026-11-10T20:00:00Z" }, "2026-11-10T13:00:00.000Z", "2026-11-10T20:00:00.000Z"],
    ["start 1 s past the 2 h limit is ignored", { startUtc: "2026-11-10T12:59:59Z" }, CAL.start, CAL.end, "stored"],
    ["end 1 s past the 4 h limit is ignored", { endUtc: "2026-11-10T20:00:01Z" }, CAL.start, CAL.end, "stored"],
    ["an end before the start is ignored", { endUtc: "2026-11-10T14:00:00Z" }, CAL.start, CAL.end, "stored"],
    ["an end equal to the start is ignored", { endUtc: "2026-11-10T15:00:00Z" }, CAL.start, CAL.end, "stored"],
    ["times inside the bounds are used", { startUtc: "2026-11-10T15:10:00Z", endUtc: "2026-11-10T15:50:00Z" }, "2026-11-10T15:10:00.000Z", "2026-11-10T15:50:00.000Z"],
    ["only a start: the end stays on the calendar", { startUtc: "2026-11-10T14:30:00Z" }, "2026-11-10T14:30:00.000Z", CAL.end],
    ["only an end: the start stays on the calendar", { endUtc: "2026-11-10T16:45:00Z" }, CAL.start, "2026-11-10T16:45:00.000Z"],
  ];

  it("applies each bound exactly, on /view", async () => {
    const w = await world({ extra: CASES.map((_, i) => meeting(`tb${i}`, CAL.start, CAL.end)) });
    for (const [i, [label, body, start, end, stored]] of CASES.entries()) {
      if (stored) storeRaw(w, `tb${i}`, body);
      else await w.set(`tb${i}`, { scope: "event", ...body });
      const e = await view(w, "2026-11-10", `tb${i}`);
      assert.equal(ms(e.startUtc), ms(start), `${label}: start`);
      assert.equal(ms(e.endUtc), ms(end), `${label}: end`);
      assert.equal(e.durationS, (ms(end) - ms(start)) / 1000, `${label}: duration is recomputed`);
      assert.ok(!e.excluded, label);
    }
  });

  it("caps the window at 12 hours, and each time is still one of the two sources", async () => {
    // A 9 hour calendar entry: 15:00 UTC to 00:00 UTC.
    const long = meeting("long1", "2026-11-10T15:00:00.000Z", "2026-11-11T00:00:00.000Z");
    const w = await world({ extra: [long, { ...long, id: "long2", title: "Case long2" }, { ...long, id: "long3", title: "Case long3" }, { ...long, id: "long4", title: "Case long4" }] });
    await w.set("long1", { scope: "event", endUtc: "2026-11-11T03:00:00Z" });
    const exact = await view(w, "2026-11-10", "long1");
    assert.equal(ms(exact.endUtc), ms("2026-11-11T03:00:00.000Z"), "exactly 12 h is allowed");
    // The route refuses a 13 h window now (fix pass 9, F6); a stored row is still ignored on read.
    storeRaw(w, "long2", { endUtc: "2026-11-11T04:00:00Z" });
    const over = await view(w, "2026-11-10", "long2");
    assert.equal(ms(over.endUtc), ms("2026-11-11T00:00:00.000Z"), "13 h is ignored, inside the 4 h bound");
    await w.set("long3", { scope: "event", startUtc: "2026-11-10T13:00:00Z" });
    assert.equal(ms((await view(w, "2026-11-10", "long3")).startUtc), ms("2026-11-10T13:00:00.000Z"), "11 h is fine");
    storeRaw(w, "long4", { startUtc: "2026-11-10T13:00:00Z", endUtc: "2026-11-11T04:00:00Z" });
    const both = await view(w, "2026-11-10", "long4");
    assert.ok(ms(both.endUtc) - ms(both.startUtc) <= 12 * HOUR, "never more than 12 h");
    assert.ok([ms("2026-11-10T13:00:00.000Z"), ms("2026-11-10T15:00:00.000Z")].includes(ms(both.startUtc)));
    assert.ok([ms("2026-11-11T04:00:00.000Z"), ms("2026-11-11T00:00:00.000Z")].includes(ms(both.endUtc)));
  });

  it("reports the choice back on the meeting", async () => {
    const w = await world({ extra: [meeting("echo", CAL.start, CAL.end)] });
    await w.set("echo", { scope: "event", startUtc: "2026-11-10T14:30:00Z", endUtc: "2026-11-10T16:15:00Z" });
    const o = (await view(w, "2026-11-10", "echo")).override;
    assert.equal(o.state, null);
    assert.equal(ms(o.startUtc), ms("2026-11-10T14:30:00Z"));
    assert.equal(ms(o.endUtc), ms("2026-11-10T16:15:00Z"));
    assert.equal(o.seenStartUtc, null);
    assert.equal(o.seenEndUtc, null);
    assert.equal(o.seenNone, false);
    assert.equal(o.seriesId, null);
    // null clears.
    await w.set("echo", { scope: "event", startUtc: null });
    const after = (await view(w, "2026-11-10", "echo"));
    assert.equal(ms(after.startUtc), ms(CAL.start));
    assert.equal(ms(after.endUtc), ms("2026-11-10T16:15:00Z"), "the end stays");
    await w.set("echo", { scope: "event", endUtc: null });
    assert.equal(ms((await view(w, "2026-11-10", "echo")).endUtc), ms(CAL.end));
  });

  it("uses what the Mac saw when the user has not set a time, and the user's time wins per field", async () => {
    const at = (i: number) => new Date(ms("2026-11-10T06:00:00.000Z") + i * 3 * HOUR).toISOString();
    const evs = [0, 1, 2, 3, 4].map((i) => meeting(`sn${i}`, at(i), new Date(ms(at(i)) + HOUR).toISOString()));
    const w = await world({ extra: evs });
    const sighting = (i: number, from: number, to: number) => w.attend({
      meetingStartUtc: at(i), seenStartUtc: new Date(ms(at(i)) + from * MIN).toISOString(),
      seenEndUtc: new Date(ms(at(i)) + to * MIN).toISOString(), seenNone: false,
    });
    const day = "2026-11-10";
    const t = async (i: number) => {
      const e = await view(w, day, `sn${i}`);
      return [(ms(e.startUtc) - ms(at(i))) / MIN, (ms(e.endUtc) - ms(at(i))) / MIN];
    };
    for (let i = 0; i < 3; i++) assert.equal((await sighting(i, 5, 55)).body?.matched, true, `sn${i} matched`);
    assert.deepEqual(await t(0), [5, 55], "seen times");
    // A user start beats the seen start. The end stays seen.
    await w.set("sn1", { scope: "event", startUtc: new Date(ms(at(1)) + 20 * MIN).toISOString() });
    assert.deepEqual(await t(1), [20, 55]);
    // Clearing it goes back to seen, not to the calendar.
    await w.set("sn1", { scope: "event", startUtc: null });
    assert.deepEqual(await t(1), [5, 55]);
    // Both user times beat both seen times.
    await w.set("sn2", { scope: "event", startUtc: new Date(ms(at(2)) + 10 * MIN).toISOString(), endUtc: new Date(ms(at(2)) + 40 * MIN).toISOString() });
    assert.deepEqual(await t(2), [10, 40]);
    // The Mac saw nothing: calendar times.
    const none = await w.attend({ meetingStartUtc: at(4), seenStartUtc: null, seenEndUtc: null, seenNone: true });
    assert.equal(none.body?.matched, true);
    assert.equal(w.row("event:sn4")?.seen_none, 1);
  });

  it("ignores a seen time outside the bounds on its own", async () => {
    const start = "2026-11-10T07:00:00.000Z";
    const w = await world({ extra: [meeting("oob", start, "2026-11-10T08:00:00.000Z")] });
    const r = await w.attend({
      meetingStartUtc: start, seenStartUtc: "2026-11-10T04:30:00.000Z", seenEndUtc: "2026-11-10T13:00:00.000Z", seenNone: false,
    });
    assert.equal(r.body?.matched, true);
    const e = await view(w, "2026-11-10", "oob");
    assert.equal(ms(e.startUtc), ms(start), "2.5 h early is too early");
    assert.equal(ms(e.endUtc), ms("2026-11-10T08:00:00.000Z"), "5 h late is too late");
  });
});

describe("a time change moves the meeting to the right day", () => {
  it("moves a meeting later across midnight and back earlier across midnight", async () => {
    const w = await world({ extra: [
      // 23:00 to 00:30 in New York, starting on the 10th.
      meeting("mn1", "2026-11-11T04:00:00.000Z", "2026-11-11T05:30:00.000Z"),
      // 00:30 to 01:30 in New York, starting on the 11th.
      meeting("mn2", "2026-11-11T05:30:00.000Z", "2026-11-11T06:30:00.000Z"),
    ] });
    const ids = async (day: string) => (await w.get(`/view?date=${day}`)).day.calendar.events.map((e: any) => e.id);
    assert.ok((await ids("2026-11-10")).includes("mn1"));
    assert.ok((await ids("2026-11-11")).includes("mn2"));
    await w.set("mn1", { scope: "event", startUtc: "2026-11-11T05:10:00Z" });
    await w.set("mn2", { scope: "event", startUtc: "2026-11-11T04:30:00Z" });
    for (const route of ["/view?date=", "/briefing/day?date="]) {
      const on = async (day: string) => ((await w.get(`${route}${day}`)).day?.calendar ?? (await w.get(`${route}${day}`)).calendar).events.map((e: any) => e.id);
      assert.ok(!(await on("2026-11-10")).includes("mn1"), `${route}: mn1 left the 10th`);
      assert.ok((await on("2026-11-11")).includes("mn1"), `${route}: mn1 is on the 11th`);
      assert.ok((await on("2026-11-10")).includes("mn2"), `${route}: mn2 is on the 10th`);
      assert.ok(!(await on("2026-11-11")).includes("mn2"), `${route}: mn2 left the 11th`);
    }
    const mn1 = await view(w, "2026-11-11", "mn1");
    assert.equal(mn1.day, "2026-11-11");
    assert.match(mn1.startLocal, /^2026-11-11T00:10:00/);
    const mn2 = await view(w, "2026-11-10", "mn2");
    assert.equal(mn2.day, "2026-11-10");
    assert.match(mn2.startLocal, /^2026-11-10T23:30:00/);
    // Ranges find a meeting that only falls inside them because of its new time.
    const range = async (day: string) => (await w.get(`/briefing/range?start=${day}&end=${day}`));
    assert.match(JSON.stringify(await range("2026-11-10")), /Case mn2/);
    assert.doesNotMatch(JSON.stringify(await range("2026-11-10")), /Case mn1/);
    assert.match(JSON.stringify(await range("2026-11-11")), /Case mn1/);
    assert.doesNotMatch(JSON.stringify(await range("2026-11-11")), /Case mn2/);
    // The week reads the same effective day.
    assert.match(JSON.stringify(await w.get("/briefing/week?date=2026-11-10")), /Case mn1/);
  });

  it("recomputes duration, local times and after hours", async () => {
    // Fri 13 Nov. ah1: 17:30 to 18:30 local. ah2: 18:30 to 19:30 local (after hours).
    const w = await world({ extra: [
      meeting("ah1", "2026-11-13T22:30:00.000Z", "2026-11-13T23:30:00.000Z"),
      meeting("ah2", "2026-11-13T23:30:00.000Z", "2026-11-14T00:30:00.000Z"),
    ] });
    const load = async () => (await w.get("/briefing/day?date=2026-11-13")).calendar;
    const before = await load();
    assert.equal(before.afterHoursCount, 1);
    assert.equal((await view(w, "2026-11-13", "ah1")).afterHours, false);
    await w.set("ah1", { scope: "event", startUtc: "2026-11-13T23:15:00Z" });
    await w.set("ah2", { scope: "event", startUtc: "2026-11-13T21:30:00Z", endUtc: "2026-11-13T22:30:00Z" });
    const ah1 = await view(w, "2026-11-13", "ah1");
    assert.equal(ah1.afterHours, true, "18:15 local is after hours");
    assert.equal(ah1.durationS, 15 * 60);
    assert.match(ah1.startLocal, /T18:15:00/);
    assert.match(ah1.endLocal, /T18:30:00/);
    const ah2 = await view(w, "2026-11-13", "ah2");
    assert.equal(ah2.afterHours, false, "16:30 local is not");
    assert.equal(ah2.durationS, 60 * 60);
    assert.match(ah2.startLocal, /T16:30:00/);
    const after = await load();
    assert.equal(after.afterHoursCount, 1);
    assert.equal(after.eventCount, before.eventCount);
    assert.equal(after.totalDurationS, before.totalDurationS - 60 * 60 - 60 * 60 + 15 * 60 + 60 * 60, "the day total follows the new lengths");
  });
});

describe("raw heart rate follows a time change and is never deleted", () => {
  const CAL = { start: "2026-11-10T15:00:00.000Z", end: "2026-11-10T16:00:00.000Z" };

  async function setup() {
    const w = await world({ extra: [meeting("rp1", CAL.start, CAL.end)] });
    // One reading a minute from 13:00 to 18:00 UTC: 70 bpm until 16:00, 120 after.
    const insert = w.raw.prepare("INSERT INTO whoop_web_hr_raw (user_id, source, time_ms, bpm, received_at) VALUES ('owner', 'ble', ?, ?, 't')");
    for (let t = ms("2026-11-10T13:00:00.000Z"); t <= ms("2026-11-10T18:00:00.000Z"); t += MIN) insert.run(t, t < ms("2026-11-10T16:00:00.000Z") ? 70 : 120);
    const rebuild = await w.call("/whoop-web/rebuild", {
      method: "POST", headers: { authorization: "Bearer admin-secret-xyz", "content-type": "application/json" }, body: JSON.stringify({ day: "2026-11-10" }),
    });
    assert.equal(rebuild.status, 200, rebuild.text);
    const hrRow = () => w.raw.prepare("SELECT window_start_utc, window_end_utc, sample_count, fetched_at FROM whoop_web_hr WHERE event_id = 'rp1'").get() as any;
    const rawCount = () => (w.raw.prepare("SELECT COUNT(*) AS n FROM whoop_web_hr_raw").get() as any).n;
    const mean = async () => (await view(w, "2026-11-10", "rp1")).hrStress?.meanBpm;
    return { w, hrRow, rawCount, mean };
  }

  it("projects again over the new window, scores the new window, and keeps every raw row", async () => {
    const { w, hrRow, rawCount, mean } = await setup();
    assert.equal(hrRow().window_start_utc, "2026-11-10T14:50:00.000Z");
    assert.equal(hrRow().window_end_utc, "2026-11-10T16:10:00.000Z");
    assert.equal(await mean(), 70);
    const raws = rawCount();
    const neighbour = (w.raw.prepare("SELECT fetched_at FROM whoop_web_hr WHERE event_id = 'ser1_20261110T160000Z'").get() as any).fetched_at;

    await w.set("rp1", { scope: "event", endUtc: "2026-11-10T17:00:00Z" });
    assert.equal(hrRow().window_start_utc, "2026-11-10T14:50:00.000Z");
    assert.equal(hrRow().window_end_utc, "2026-11-10T17:10:00.000Z", "the pad follows the effective end");
    assert.equal(hrRow().sample_count, 141);
    assert.equal(await mean(), 95, "the hour of 70 and the hour of 120");
    assert.equal(rawCount(), raws, "raw rows are never deleted");
    assert.equal((w.raw.prepare("SELECT fetched_at FROM whoop_web_hr WHERE event_id = 'ser1_20261110T160000Z'").get() as any).fetched_at, neighbour,
      "only the meeting that changed is projected again");

    await w.set("rp1", { scope: "event", startUtc: "2026-11-10T14:00:00Z" });
    assert.equal(hrRow().window_start_utc, "2026-11-10T13:50:00.000Z");
    assert.equal(hrRow().sample_count, 201);

    await w.set("rp1", { scope: "event", startUtc: null, endUtc: null });
    assert.equal(hrRow().window_start_utc, "2026-11-10T14:50:00.000Z");
    assert.equal(hrRow().window_end_utc, "2026-11-10T16:10:00.000Z");
    assert.equal(await mean(), 70);
    assert.equal(rawCount(), raws);
  });

  it("a failed projection leaves the old series, and the answer to the user's change still succeeds", async () => {
    const { w, hrRow } = await setup();
    w.raw.exec("DROP TABLE whoop_web_hr_raw");
    const before = hrRow();
    const r = await w.put("rp1", { scope: "event", endUtc: "2026-11-10T17:00:00Z" });
    assert.equal(r.status, 200, r.text);
    await w.settle();
    assert.deepEqual(hrRow(), before);
    assert.equal((await view(w, "2026-11-10", "rp1")).endUtc, "2026-11-10T17:00:00.000Z", "the new time is saved anyway");
  });

  it("excluding a meeting deletes nothing, and undoing it brings the same heart rate back", async () => {
    const { w, hrRow, rawCount, mean } = await setup();
    const row = hrRow();
    const raws = rawCount();
    await w.set("rp1", { scope: "event", state: "not_joined" });
    assert.equal(rawCount(), raws);
    assert.deepEqual(hrRow(), row, "the stored series is kept");
    await w.set("rp1", { scope: "event", state: null });
    assert.equal(await mean(), 70);
  });
});

describe("a calendar resync does not wipe overrides", () => {
  const realFetch = globalThis.fetch;
  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  const google = (id: string, startLocal: string, endLocal: string, status = "confirmed") => ({
    id, status, summary: "Synced standup", start: { dateTime: startLocal }, end: { dateTime: endLocal },
    attendees: [{ email: "me@example.com", self: true }, { email: "kim@synced.io", displayName: "Kim" }],
  });

  async function sync(w: World, items: unknown[], force = true) {
    const env = {
      ...w.env, RAW: { put: async () => undefined },
      TOKENS: fakeKv({ "settings:source_display:whoop": "true" }),
    } as never;
    // One connected Google account (its primary calendar chosen), as the OAuth callback stores it.
    const me = "me@example.com";
    await connectAccount(env, me, { access_token: "at", refresh_token: "rt", expires_at: "2999-01-01T00:00:00.000Z" });
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const body = String(input).includes("/users/me/calendarList")
        ? { items: [{ id: me, summary: me, primary: true, accessRole: "owner" }] }
        : { items, nextSyncToken: "tok" };
      return new Response(JSON.stringify(body), { status: 200 });
    }) as typeof fetch;
    return syncCalendarIncremental(env, "test", { force, now: new Date("2026-11-12T12:00:00.000Z") });
  }

  it("keeps state, times and sightings across a full resync, a move, and a cancel", async () => {
    const w = await world();
    const id = "sync1_20261111T150000Z";
    await sync(w, [google(id, "2026-11-11T10:00:00-05:00", "2026-11-11T11:00:00-05:00")]);
    await w.set(id, { scope: "series", state: "unlinked" });
    await w.set(id, { scope: "event", startUtc: "2026-11-11T14:30:00Z", endUtc: "2026-11-11T16:30:00Z" });
    assert.equal((await w.attend({ meetingStartUtc: "2026-11-11T15:00:00Z", title: "Synced standup", seenStartUtc: "2026-11-11T15:02:00Z", seenEndUtc: "2026-11-11T15:50:00Z", seenNone: false })).body?.matched, true);
    const rows = w.rows();
    assert.deepEqual(rows.map((r) => r.key), [`event:${id}`, "series:sync1"]);

    // Same data again, then the meeting moves on the calendar.
    await sync(w, [google(id, "2026-11-11T10:00:00-05:00", "2026-11-11T11:00:00-05:00")]);
    await sync(w, [google(id, "2026-11-11T10:20:00-05:00", "2026-11-11T11:20:00-05:00")]);
    const strip = (r: Record<string, any>) => ({ ...r, updated_at: undefined });
    assert.deepEqual(w.rows().map(strip), rows.map(strip), "nothing in the table changed");
    const e = (await w.get("/view?date=2026-11-11")).day.calendar.events.find((x: any) => x.id === id);
    assert.equal(e.excluded, true);
    assert.equal(e.override.scope, "series");
    assert.equal(ms(e.override.startUtc), ms("2026-11-11T14:30:00Z"));
    assert.equal(ms(e.override.endUtc), ms("2026-11-11T16:30:00Z"));
    assert.equal(ms(e.override.seenStartUtc), ms("2026-11-11T15:02:00Z"));

    // Cancelled: gone from the views, choices kept.
    await sync(w, [google(id, "2026-11-11T10:20:00-05:00", "2026-11-11T11:20:00-05:00", "cancelled")], false);
    assert.deepEqual(w.rows().map(strip), rows.map(strip));
    const events = (await w.get("/view?date=2026-11-11")).day.calendar.events;
    assert.ok(!events.some((x: any) => x.id === id));
  });
});
