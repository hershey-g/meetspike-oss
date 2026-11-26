import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import type { Env } from "../src/env.ts";
import { meetingLive, whoopWeb } from "../src/routes/whoop-web.ts";
import { LIVE_MAX_POINTS, LIVE_RETENTION_MS, LiveHeartRate } from "../src/sources/whoop-web/live.ts";
import { fakeKv, sqliteD1 } from "./sqlite-d1.ts";

const MINUTE = 60_000;
const NOW = Date.parse("2026-01-20T16:00:00Z");
const ADMIN = { Authorization: "Bearer fixture-admin", "Content-Type": "application/json" };

function fixtures() {
  const { db, raw: calendar } = sqliteD1();
  const sql = new DatabaseSync(":memory:");
  let alarm: number | null = null;
  const object = new LiveHeartRate({ storage: {
    sql: { exec: (query: string, ...args: number[]) => {
      if (query.startsWith("CREATE")) return sql.exec(query);
      const statement = sql.prepare(query);
      if (query.startsWith("SELECT")) {
        const rows = statement.all(...args);
        return Object.assign(rows, { toArray: () => rows, one: () => rows[0] });
      }
      return statement.run(...args);
    } },
    transactionSync: (callback: () => void) => {
      sql.exec("BEGIN");
      try {
        callback();
        sql.exec("COMMIT");
      } catch (err) {
        sql.exec("ROLLBACK");
        throw err;
      }
    },
    getAlarm: async () => alarm,
    setAlarm: async (time: number) => { alarm = time; },
  } } as unknown as DurableObjectState);
  const env = {
    WEARABLE: "whoop", WHOOP_WEB_HR: "enabled", INGEST_ADMIN_SECRET: "fixture-admin", DB: db,
    TOKENS: fakeKv({ "settings:source_display:whoop": "true" }),
    LIVE_HR: { idFromName: () => "fixture", get: () => ({ fetch: (url: string, init: RequestInit) => object.fetch(new Request(url, init)) }) },
  } as unknown as Env;
  const post = (body: unknown, headers = ADMIN as HeadersInit, bindings = env) => whoopWeb.request("/live", {
    method: "POST", headers, body: JSON.stringify(body),
  }, bindings);
  const get = (id: string, since?: number) => meetingLive.request(`/${id}/live-hr${since === undefined ? "" : `?since=${since}`}`, {}, env);
  const meeting = (id: string, startMs: number, endMs: number, source = "calendar") => calendar.prepare(`INSERT INTO calendar_event
    (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, title, kind, source_type, updated_at)
    VALUES (?, 'google', '2026-01-20', ?, ?, 0, ?, 'Synthetic meeting', 'meeting', ?, '2026-01-20')`)
    .run(id, new Date(startMs).toISOString(), new Date(endMs).toISOString(), (endMs - startMs) / 1000, source);
  return { env, post, get, meeting, sql, calendar, object, alarmAt: () => alarm, cleanup: async () => { alarm = null; await object.alarm(); } };
}

test("live uploads are kept while WHOOP display is off and become visible when enabled", async (t) => {
  t.mock.method(Date, "now", () => NOW);
  const { env, post, get, meeting, calendar } = fixtures();
  meeting("meeting", NOW - MINUTE, NOW + MINUTE);
  await env.TOKENS.delete("settings:source_display:whoop");
  assert.equal((await post({ version: 1, points: [[NOW, 80]] })).status, 200);
  assert.equal(calendar.prepare("SELECT COUNT(*) AS n FROM whoop_web_hr_raw").get()?.n, 1);
  assert.equal((await get("meeting")).status, 404);
  await env.TOKENS.put("settings:source_display:whoop", "true");
  const response = await get("meeting");
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json() as { points: number[][] }).points, [[NOW, 80]]);
});

test("live ingest uses the replay route's admin guard and rejects oversized or malformed batches", async (t) => {
  t.mock.method(Date, "now", () => NOW);
  const { env, post, sql } = fixtures();
  const batch = { version: 1, points: [[NOW, 80]] };
  assert.equal((await post(batch, {})).status, 401);
  assert.equal((await post(batch, { "x-admin-secret": "wrong" })).status, 401);
  assert.equal((await post(batch, ADMIN, { ...env, INGEST_ADMIN_SECRET: undefined })).status, 503);
  assert.equal((await post(batch, ADMIN, { ...env, WHOOP_WEB_HR: "off" })).status, 409);
  assert.equal((await post(batch, ADMIN, { ...env, LIVE_HR: undefined })).status, 503);
  assert.equal((await post({ ...batch, extra: "x".repeat(4096) })).status, 413);
  for (const invalid of [[], [[NOW, 24]], [[NOW, 251]], [[NOW, 80.5]], [["now", 80]], [[NOW, 80, 1]],
    Array.from({ length: LIVE_MAX_POINTS + 1 }, (_, i) => [NOW - i, 80])]) {
    assert.equal((await post({ version: 1, points: invalid })).status, 400);
  }
  assert.equal((await post({ version: 2, points: batch.points })).status, 400);
  assert.equal(sql.prepare("SELECT COUNT(*) AS n FROM points").get()?.n, 0);
  const maxBatch = { version: 1, points: Array.from({ length: LIVE_MAX_POINTS }, (_, i) => [NOW - i * 1000, 80]) };
  assert.equal((await post(maxBatch, { "x-admin-secret": "fixture-admin" })).status, 200);
  assert.equal(sql.prepare("SELECT COUNT(*) AS n FROM points").get()?.n, LIVE_MAX_POINTS);
});

test("meeting reads include both pads and cursor updates deduplicate retries and deliver out-of-order corrections", async (t) => {
  let now = NOW;
  t.mock.method(Date, "now", () => now);
  const { post, get, meeting, sql } = fixtures();
  meeting("long-running", NOW - 50 * MINUTE, NOW + MINUTE);
  meeting("recently-ended", NOW - 16 * MINUTE, NOW - MINUTE);
  meeting("test-meeting", NOW - 12 * MINUTE, NOW - 2 * MINUTE);
  meeting("future", NOW + 20 * MINUTE, NOW + 30 * MINUTE);
  meeting("recording", NOW - MINUTE, NOW + MINUTE, "plaud_phone");
  const fromMs = NOW - 22 * MINUTE;
  const toMs = NOW + 8 * MINUTE;
  const points = [[fromMs - 1, 50], [NOW, 82], [fromMs, 70], [NOW - 3 * MINUTE, 90], [NOW, 83]];
  const posted = await post({ version: 1, points, includeMeeting: true });
  assert.equal(posted.status, 200);
  assert.equal((await posted.json() as { meeting: { id: string } }).meeting.id, "long-running");
  const first = await get("test-meeting");
  assert.equal(first.status, 200);
  assert.equal(first.headers.get("Cache-Control"), "private, no-store");
  const snapshot = await first.json() as { window: { fromMs: number; toMs: number }; cursor: number; points: number[][] };
  assert.equal(snapshot.window.fromMs, fromMs);
  assert.equal(snapshot.window.toMs, toMs);
  assert.deepEqual(snapshot.points, [[fromMs, 70], [NOW - 3 * MINUTE, 90], [NOW, 83]]);

  const readSince = (cursor: number) => get("test-meeting", cursor).then((r) => r.json());
  now += 5_000;
  assert.equal((await post({ version: 1, points })).status, 200);
  assert.deepEqual(await readSince(snapshot.cursor), { window: snapshot.window, active: true, points: [], cursor: snapshot.cursor });
  await post({ version: 1, points: [[NOW - 3 * MINUTE, 91], [NOW - 4 * MINUTE, 81], [NOW + 5_000, 84]] });
  const changed = await readSince(snapshot.cursor) as { points: number[][]; cursor: number };
  assert.deepEqual(changed.points, [[NOW - 4 * MINUTE, 81], [NOW - 3 * MINUTE, 91], [NOW + 5_000, 84]]);
  assert.equal(sql.prepare("SELECT COUNT(*) AS n FROM points").get()?.n, 6);
  assert.equal((await get("test-meeting", -1)).status, 400);
  assert.equal((await get("recording")).status, 404);
  assert.equal((await get("missing")).status, 404);
  assert.equal((await (await get("future")).json() as { active: boolean }).active, false);
  now = toMs;
  assert.equal((await readSince(changed.cursor) as { active: boolean }).active, false);
});

test("expired and future readings never enter the live window and an alarm physically removes old rows", async (t) => {
  let now = NOW;
  t.mock.method(Date, "now", () => now);
  const { post, get, meeting, sql, calendar, object, alarmAt, cleanup } = fixtures();
  const old = NOW - LIVE_RETENTION_MS + 30_000;
  await post({ version: 1, points: [[NOW + MINUTE, 70], [NOW - LIVE_RETENTION_MS - 1, 81], [old, 82], [NOW, 84]] });
  assert.deepEqual(sql.prepare("SELECT ts FROM points ORDER BY ts").all().map((r) => r.ts), [old, NOW]);
  assert.equal(alarmAt(), NOW + MINUTE);
  now = NOW + MINUTE;
  meeting("new-meeting", now - MINUTE, now + MINUTE);
  const body = await (await get("new-meeting")).json() as { points: number[][] };
  assert.deepEqual(body.points, [[NOW, 84]]);
  const expiredRead = await object.fetch(new Request(`https://fixture.example/?from=${old}&to=${old}&since=0`));
  assert.deepEqual(await expiredRead.json(), { points: [], cursor: 0 });
  await cleanup();
  assert.deepEqual(sql.prepare("SELECT ts FROM points").all().map((r) => r.ts), [NOW]);
  assert.equal(alarmAt(), NOW + LIVE_RETENTION_MS);
  now = NOW + LIVE_RETENTION_MS;
  await cleanup();
  assert.equal(sql.prepare("SELECT COUNT(*) AS n FROM points").get()?.n, 0);
  assert.equal(alarmAt(), null);
  assert.deepEqual(calendar.prepare("SELECT time_ms, bpm FROM whoop_web_hr_raw ORDER BY time_ms").all()
    .map((r) => [r.time_ms, r.bpm]), [[NOW - LIVE_RETENTION_MS - 1, 81], [old, 82], [NOW, 84], [NOW + MINUTE, 70]]);
});
