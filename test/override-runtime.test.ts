import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it, mock } from "node:test";
import { runWhoopWebFill } from "../src/sources/whoop-web/fill.ts";
import { WHOOP_WEB_TOKEN_KEY } from "../src/sources/whoop-web/constants.ts";
import { ADMIN, MIN, world, type Ev, type World } from "./override-world.ts";

/**
 * The routes the phone and the Mac poll while a meeting runs: live heart rate,
 * the reminder, the ingest and the 15 minute fill. They read the clock, so the
 * clock stands still at NOW.
 */
const NOW = Date.parse("2026-11-14T15:00:00.000Z");
const iso = (ms: number) => new Date(ms).toISOString();
const ms = (s: string) => Date.parse(s);
const AUTH = { authorization: `Bearer ${ADMIN}`, "content-type": "application/json" };
const LIVE_HR = { idFromName: () => "x", get: () => ({ fetch: async () => Response.json({ ok: true, points: [], cursor: 0 }) }) };

const at = (id: string, fromNow: [number, number], extra: Partial<Ev> = {}): Ev =>
  ({ id, start: iso(NOW + fromNow[0] * MIN), end: iso(NOW + fromNow[1] * MIN), title: `Run ${id}`, people: [], hr: null, ...extra });

beforeEach(() => mock.timers.enable({ apis: ["Date"], now: NOW }));
afterEach(() => mock.timers.reset());

const live = (w: World) => w.call("/whoop-web/live", {
  method: "POST", headers: AUTH, body: JSON.stringify({ version: 1, points: [[NOW, 80]], includeMeeting: true }),
}, { ...w.env, LIVE_HR });
const liveHr = (w: World, id: string) => w.call(`/meetings/${id}/live-hr`, {}, { ...w.env, LIVE_HR });
const reminder = (w: World) => w.call("/whoop-web/reminder", { headers: AUTH });

describe("live heart rate", () => {
  it("an excluded meeting is not the current meeting and has no live window", async () => {
    const w = await world({ extra: [at("lv2", [-10, 50])] });
    assert.equal((await live(w)).body.meeting?.id, "lv2");
    assert.equal((await liveHr(w, "lv2")).status, 200);
    await w.set("lv2", { scope: "event", state: "not_joined" });
    const after = await live(w);
    assert.equal(after.status, 200, "the batch is still stored");
    assert.equal(after.body.meeting ?? null, null);
    assert.equal((await liveHr(w, "lv2")).status, 404);
    await w.set("lv2", { scope: "event", state: null });
    assert.equal((await live(w)).body.meeting?.id, "lv2", "undo brings it back");
    assert.equal((await liveHr(w, "lv2")).status, 200);
  });

  it("a series choice reaches the running meeting too", async () => {
    const w = await world({ extra: [at("liveser_20261114T145000Z", [-10, 50])] });
    assert.equal((await live(w)).body.meeting?.id, "liveser_20261114T145000Z");
    await w.set("liveser_20261114T145000Z", { scope: "series", state: "unlinked" });
    assert.equal((await live(w)).body.meeting ?? null, null);
  });

  it("a meeting the user says ran longer is the current meeting until its new end", async () => {
    const w = await world({ extra: [at("lv1", [-70, -40])] });
    assert.equal((await live(w)).body.meeting ?? null, null, "it ended 40 minutes ago on the calendar");
    await w.set("lv1", { scope: "event", endUtc: iso(NOW + 20 * MIN) });
    const r = await live(w);
    assert.equal(r.body.meeting?.id, "lv1");
    assert.equal(ms(r.body.meeting.endUtc), NOW + 20 * MIN);
  });

  it("the live window of a meeting follows its effective start and end", async () => {
    const w = await world({ extra: [at("lv3", [-120, -90])] });
    const before = await liveHr(w, "lv3");
    assert.equal(before.body.active, false);
    await w.set("lv3", { scope: "event", startUtc: iso(NOW - 150 * MIN), endUtc: iso(NOW + 30 * MIN) });
    const r = await liveHr(w, "lv3");
    assert.equal(r.status, 200);
    assert.equal(r.body.active, true);
    assert.equal(r.body.window.startMs, NOW - 150 * MIN);
    assert.equal(r.body.window.endMs, NOW + 30 * MIN);
    assert.equal(r.body.window.fromMs, NOW - 160 * MIN, "10 minute pad before");
    assert.equal(r.body.window.toMs, NOW + 40 * MIN, "10 minute pad after");
  });
});

describe("heart rate reminder", () => {
  it("is quiet for an excluded meeting, and speaks for a meeting the user started early", async () => {
    const w = await world({ extra: [at("rm2", [-5, 55]), at("rm1", [30, 90])] });
    assert.equal((await reminder(w)).body.meeting?.id, "rm2");
    await w.set("rm2", { scope: "event", state: "unlinked" });
    assert.equal((await reminder(w)).body.meeting ?? null, null);
    // rm1 starts in 30 minutes: not yet. The user says it started 90 minutes ago.
    assert.equal((await reminder(w)).body.meeting ?? null, null);
    await w.set("rm1", { scope: "event", startUtc: iso(NOW - 90 * MIN) });
    assert.equal((await reminder(w)).body.meeting?.id, "rm1");
  });

  it("the phone's coverage is matched on the meeting's original start", async () => {
    const original = NOW + 30 * MIN;
    const moved = NOW - 90 * MIN;
    const w = await world({ extra: [at("rm1", [30, 90])] });
    await w.set("rm1", { scope: "event", startUtc: iso(moved) });
    const checkIn = (start: number) => w.call("/whoop-web/reminder/owner", {
      method: "POST", headers: AUTH, body: JSON.stringify({ active: true, covered: [iso(start)] }),
    });
    assert.equal((await checkIn(original)).status, 200);
    const covered = await reminder(w);
    assert.equal(covered.body.meeting?.id, "rm1");
    assert.equal(covered.body.owner, "phone", "the phone scheduled its reminder for the calendar start");
    await checkIn(moved);
    assert.equal((await reminder(w)).body.owner, "mac", "a start the phone never saw is not covered");
  });
});

describe("ingest", () => {
  const spanFrom = NOW - 3 * 60 * MIN - 10 * MIN;
  const spanTo = NOW - 50 * MIN;
  const post = (w: World) => {
    const points: Array<[number, number]> = [];
    for (let t = spanFrom; t <= spanTo; t += MIN) points.push([t, 80]);
    return w.call("/whoop-web/ingest", {
      method: "POST", headers: AUTH,
      body: JSON.stringify({ version: 1, fetchedAt: iso(NOW - 60_000), hr: { spans: [{ startMs: spanFrom, endMs: spanTo }], points } }),
    });
  };
  const row = (w: World, id: string) =>
    w.raw.prepare("SELECT window_start_utc, window_end_utc, sample_count FROM whoop_web_hr WHERE event_id = ?").get(id) as any;

  it("projects a meeting over its effective window, using the same raw points", async () => {
    const plain = await world({ extra: [at("ig1", [-180, -120])] });
    assert.equal((await post(plain)).status, 200);
    assert.equal(row(plain, "ig1").window_end_utc, iso(NOW - 110 * MIN), "calendar end plus the pad");

    const moved = await world({ extra: [at("ig1", [-180, -120])] });
    await moved.set("ig1", { scope: "event", endUtc: iso(NOW - 60 * MIN) });
    assert.equal((await post(moved)).status, 200);
    assert.equal(row(moved, "ig1").window_end_utc, iso(NOW - 50 * MIN), "effective end plus the pad");
    assert.ok(row(moved, "ig1").sample_count > row(plain, "ig1").sample_count);
  });

  it("does not build a heart rate row for an excluded meeting, and still raw-stores every point", async () => {
    const w = await world({ extra: [at("ig1", [-180, -120]), at("ig2", [-180, -120], { title: "Other" })] });
    await w.set("ig2", { scope: "event", state: "not_joined" });
    const r = await post(w);
    assert.equal(r.status, 200, r.text);
    assert.ok(row(w, "ig1"));
    assert.equal(row(w, "ig2"), undefined);
    assert.equal(r.body.meetings.written, 1);
    assert.ok((w.raw.prepare("SELECT COUNT(*) AS n FROM whoop_web_hr_raw").get() as any).n > 100, "raw data is kept");
    await w.set("ig2", { scope: "event", state: null });
    await post(w);
    assert.ok(row(w, "ig2"), "after undo the next ingest builds it");
  });
});
