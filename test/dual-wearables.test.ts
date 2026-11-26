import assert from "node:assert/strict";
import { test } from "node:test";
import { api } from "../src/routes/api.ts";
import { attachMeetingHr } from "../src/lib/heartrate.ts";
import { selectMeetingHr } from "../src/lib/meeting-hr.ts";
import { scoreWhoopWebMeeting, fetchWindow } from "../src/sources/whoop-web/meeting-hr.ts";
import { putCachedHr, putCachedStressDay } from "../src/sources/whoop-web/store.ts";
import { meetingHrLabel, scoreLabel } from "../public/wearable-labels.js";
import { fakeKv, sqliteD1 } from "./sqlite-d1.ts";

const start = Date.parse("2026-11-05T15:00:00.000Z");
const iso = (minute: number) => new Date(start + minute * 60_000).toISOString();
const meeting = { id: "review", startUtc: iso(0), endUtc: iso(30), day: "2026-11-05" };
const win = fetchWindow(meeting.startUtc, meeting.endUtc);
const minutes = (from: number, to: number, by = 1) =>
  Array.from({ length: Math.floor((to - from) / by) + 1 }, (_, i) => from + i * by);

function whoopAt(times: number[]) {
  const points = times.map((m) => [Date.parse(iso(m)), 100] as [number, number]);
  return scoreWhoopWebMeeting(meeting, {
    eventId: meeting.id, windowStartUtc: win.startUtc, windowEndUtc: win.endUtc,
    status: "ok", sampleCount: points.length, fetchedAt: iso(360), minutePoints: points,
  }, [], 52).hr;
}

function ouraAt(times: number[]) {
  const samples = times.map((m) => ({ timestamp: iso(m), timestampMs: Date.parse(iso(m)), bpm: 80, source: "awake" }));
  return attachMeetingHr([meeting], samples, new Map([[meeting.day, 57]])).get(meeting.id)!;
}

test("full WHOOP wins and full Oura wins over gapped or missing WHOOP", () => {
  const fullWhoop = whoopAt(minutes(0, 29));
  const fullOura = ouraAt(minutes(0, 25, 5));
  const gappedWhoop = whoopAt([...minutes(0, 9), ...minutes(20, 29)]);
  assert.equal(selectMeetingHr(meeting, fullWhoop, fullOura).source, "WHOOP");
  assert.equal(gappedWhoop.partial?.lateStart, false);
  assert.equal(gappedWhoop.partial?.earlyEnd, false);
  assert.equal(selectMeetingHr(meeting, gappedWhoop, fullOura).source, "Oura");
  assert.equal(selectMeetingHr(meeting, whoopAt([]), fullOura).restingBpm, 57);
  assert.equal(selectMeetingHr(meeting, whoopAt([]), ouraAt([])).coverage, "none");
});

test("combines only complementary partial readings and keeps an individual fallback", () => {
  const earlyWhoop = whoopAt(minutes(0, 13));
  const lateOura = ouraAt([15, 20, 25]);
  const result = selectMeetingHr(meeting, earlyWhoop, lateOura);
  assert.equal(result.source, "WHOOP + Oura");
  assert.equal(result.partial, null);
  assert.equal(result.zone, null);
  assert.equal(result.restingBpm, null);
  assert.deepEqual([...new Set(result.series.map((p) => p.source))], ["WHOOP", "Oura"]);
  assert.equal(selectMeetingHr(meeting, earlyWhoop, ouraAt([0, 5, 10])).source, "WHOOP");
  assert.equal(selectMeetingHr(meeting, undefined, lateOura).source, "Oura");
  assert.equal(meetingHrLabel(result), "WHOOP + Oura");
  assert.equal(meetingHrLabel(earlyWhoop), "WHOOP");
  assert.equal(meetingHrLabel(lateOura), "Oura");
  assert.equal(meetingHrLabel(whoopAt([])), "");
});

test("display settings filter stored meeting HR, morning scores and dashboard lists together", async (t) => {
  const { db, raw } = sqliteD1();
  t.after(() => raw.close());
  raw.prepare(`INSERT INTO calendar_event
    (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, title, kind, attendee_count, after_hours, updated_at, start_local, end_local)
    VALUES (?, 'google', ?, ?, ?, -300, 1800, 'Review', 'client', 0, 0, ?, ?, ?)`)
    .run(meeting.id, meeting.day, meeting.startUtc, meeting.endUtc, iso(0), iso(0), iso(30));
  raw.exec(`UPDATE calendar_event SET attendees_json = '[{"email":"person@example.com","name":"Example Person"}]';
    INSERT INTO calendar_attendee (event_id, source, email, self) VALUES ('review', 'google', 'person@example.com', 0)`);
  raw.prepare("INSERT INTO raw_object (source, endpoint, document_id, day, r2_key, content_hash, fetched_at) VALUES ('oura', 'heartrate', 'hr-2026-11-01-p0', '2026-11-01', 'fixture', 'hash', ?)").run(iso(45));
  const readiness = raw.prepare("INSERT INTO daily_readiness (source, day, score, updated_at) VALUES (?, ?, ?, ?)");
  for (const [source, past, now] of [["oura", 72, 84], ["whoop", 30, 50]] as const) {
    readiness.run(source, "2026-11-04", past, iso(0));
    readiness.run(source, meeting.day, now, iso(0));
    readiness.run(source, "2026-11-06", now + 5, iso(0));
    raw.prepare("INSERT INTO daily_sleep (source, day, score, updated_at) VALUES (?, ?, ?, ?)").run(source, meeting.day, now, iso(0));
  }
  const tokens = JSON.stringify({ access_token: "fixture", expires_at: iso(360) });
  const env = {
    DB: db,
    RAW: { get: async () => ({ text: async () => JSON.stringify({ data: minutes(0, 25, 5).map((m) => ({
      timestamp: iso(m), bpm: 80, source: "awake",
    })) }) }) },
    TOKENS: fakeKv({ "oura:tokens": tokens, "whoop:tokens": tokens }),
    WEARABLE: "whoop",
    WHOOP_WEB_HR: "enabled",
  } as never;
  await putCachedHr(db, {
    eventId: meeting.id, windowStartUtc: win.startUtc, windowEndUtc: win.endUtc,
    status: "ok", points: [[Date.parse(iso(2)), 100]], errorText: null, fetchedAt: iso(360),
  });
  await putCachedStressDay(db, {
    day: meeting.day, status: "ok", points: [[Date.parse(iso(3)), 1]],
    currentLevel: 1, peakLevel: 1, minLevel: 1, errorText: null, fetchedAt: iso(360),
  });
  const request = (path: string, init: RequestInit = {}) => api.request(path, init, env);
  const patch = (body: unknown, contentType = "application/json") =>
    request("/settings/source-display", {
      method: "PATCH", headers: { "Content-Type": contentType }, body: JSON.stringify(body),
    });
  const get = async (path: string, status = 200) => {
    const response = await request(path);
    assert.equal(response.status, status, path);
    assert.equal(response.headers.get("Cache-Control"), "private, no-store");
    return await response.json();
  };
  const span = `start=2026-11-04&end=${meeting.day}`;
  const state = [
    { change: null, oura: false, whoop: false, hr: null, next: null, morning: [] },
    { change: { oura: true }, oura: true, whoop: false, hr: "Oura", next: 89, morning: [["Readiness (Oura)", 84, 78]] },
    { change: { whoop: true }, oura: true, whoop: true, hr: "Oura", next: 55, morning: [["Recovery (WHOOP)", 50, 40], ["Readiness (Oura)", 84, 78]] },
    { change: { oura: false }, oura: false, whoop: true, hr: "WHOOP", next: 55, morning: [["Recovery (WHOOP)", 50, 40]] },
  ];
  for (const { change, oura, whoop, hr, next, morning } of state) {
    const display = { oura, whoop };
    if (change) {
      const written = await patch(change);
      assert.equal(written.status, 200);
      assert.deepEqual(await written.json(), display);
    }
    assert.deepEqual(await get("/settings/source-display"), display);
    const day = await get(`/view?date=${meeting.day}`);
    assert.deepEqual(day.status.sourceDisplay, display);
    assert.ok(day.status.wearables.every((source: any) => source.connected && source.displayEnabled === display[source.source]));
    assert.deepEqual(day.status.wearables.find((source: any) => source.source === "oura").history, { min: "2026-11-01", max: "2026-11-06" });
    assert.deepEqual(day.morningScores.map((score: any) => [scoreLabel(score), score.morning, score.usual.recovery]), morning);
    assert.equal(day.day.hr?.source ?? null, oura ? "Oura" : null);
    const event = day.day.calendar.events[0];
    assert.equal(event.id, meeting.id);
    assert.equal(event.hrStress?.source ?? null, hr);
    assert.equal(event.signals.nextReadinessScore, next);

    const range = await get(`/view?${span}`);
    assert.equal(range.range.summary.meetingCount, 1);
    assert.equal(range.series.at(-1).nextRecovery, next);
    const people = await get(`/people?${span}`);
    assert.equal(people.people[0].meetings, 1);
    assert.equal(people.people[0].avg, next);
    const person = await get(`/people/person%40example.com/meetings?${span}`);
    assert.equal(person.meetings[0].nextReadinessScore, next);
    assert.deepEqual(person.trendsByHrSource.map((t: any) => t.source), hr ? [hr] : []);
    const list = await get(`/meetings/stressed?${span}`);
    assert.equal(list.meetings[0].hrStress?.source ?? null, hr);
    const sleep = await get("/sleep?limit=1");
    assert.deepEqual(sleep.map((row: any) => row.source), whoop ? ["whoop"] : oura ? ["oura"] : []);
    const metrics = await get(`/metrics/daily?${span}&source=oura`);
    assert.equal(metrics.days.at(-1)?.readinessScore ?? null, oura ? 84 : null);

    const chart = await get(`/meetings/${meeting.id}/hr?fill=0`, hr ? 200 : 404);
    assert.equal(chart.hrStress?.source ?? null, hr);
    if (hr) {
      assert.ok(chart.series.length > 0);
      assert.ok(chart.series.every((p: { bpm: number }) => p.bpm === (hr === "Oura" ? 80 : 100)));
      assert.equal(chart.stress?.peakLevel ?? null, whoop ? 1 : null);
      assert.equal(raw.prepare("SELECT source FROM meeting_hr_source WHERE event_id = ?").get(meeting.id)?.source, hr);
    } else {
      assert.equal(chart.series, undefined);
    }
  }
  const health = await get("/health");
  assert.deepEqual(health.sourceDisplay, { oura: false, whoop: true });
  for (const body of [null, {}, { oura: "true" }, { whoop: true, oura: true }, { unknown: true }]) {
    assert.equal((await patch(body)).status, 400);
  }
  assert.equal((await patch({ whoop: false }, "text/plain")).status, 415);
  await Promise.all([patch({ oura: true }), patch({ whoop: false })]);
  assert.deepEqual(await get("/settings/source-display"), { oura: true, whoop: false });
});
