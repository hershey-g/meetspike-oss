import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import { api } from "../src/routes/api.ts";
import { WHOOP_TOKEN_KEY } from "../src/sources/whoop/endpoints.ts";
import {
  CRON_MIN_INTERVAL_MS,
  MANUAL_MIN_INTERVAL_MS,
  RECENT_SYNC_KEY,
  recentWindow,
  syncRecentWhoop,
} from "../src/sources/whoop/recent.ts";
import { DEFAULT_TIME_ZONE } from "../src/lib/time.ts";
import { fakeKv, sqliteD1 } from "./sqlite-d1.ts";

// Wed 18 Nov 2026, 14:28 Eastern: after WHOOP scored the night, long after the 06:00 reconcile.
const NOW = Date.parse("2026-11-18T19:28:00Z");
const TZ = "America/New_York";

function whoopTokens(): string {
  return JSON.stringify({ access_token: "whoop-access-000000", refresh_token: "whoop-refresh-000000", expires_at: new Date(Date.now() + 3600_000).toISOString() });
}

function makeEnv(opts: { wearable?: string; whoop?: boolean; kv?: Record<string, string> } = {}) {
  const d1 = sqliteD1();
  const kv = fakeKv({ ...(opts.whoop === false ? {} : { [WHOOP_TOKEN_KEY]: whoopTokens() }), ...(opts.kv ?? {}) });
  const env = { DB: d1.db, TOKENS: kv, WEARABLE: opts.wearable ?? "whoop", WHOOP_WEB_HR: "off" };
  return { env: env as never, raw: d1.raw, kv };
}

function syncLog(raw: ReturnType<typeof sqliteD1>["raw"]) {
  return raw.prepare(`SELECT trigger, source, status, error_text, window_start, window_end FROM sync_log ORDER BY id`).all() as Array<Record<string, string | null>>;
}

describe("WHOOP: keeping today's sleep and recovery current", () => {
  it("covers last night and today in the user's zone", () => {
    assert.deepEqual(recentWindow(NOW, TZ), { start: "2026-11-17", end: "2026-11-18" });
    // 00:30 UTC on the 19th is still the evening of the 18th in New York.
    assert.deepEqual(recentWindow(Date.parse("2026-11-19T00:30:00Z"), TZ), { start: "2026-11-17", end: "2026-11-18" });
  });

  it("pulls the recent window, then waits out the interval", async () => {
    const { env, kv } = makeEnv();
    const windows: Array<{ start: string; end: string }> = [];
    const ingest = async (_e: unknown, w: { start: string; end: string }) => (windows.push(w), { written: 2, skipped: 5 });
    const first = await syncRecentWhoop(env, { trigger: "cron", minIntervalMs: CRON_MIN_INTERVAL_MS }, { now: () => NOW, ingest });
    assert.equal(first.ok, true);
    assert.equal(windows.length, 1);
    assert.deepEqual(windows[0], recentWindow(NOW, DEFAULT_TIME_ZONE));
    assert.equal(kv.store.get(RECENT_SYNC_KEY), String(NOW));

    const soon = await syncRecentWhoop(env, { trigger: "cron", minIntervalMs: CRON_MIN_INTERVAL_MS }, { now: () => NOW + 5 * 60_000, ingest });
    assert.deepEqual(soon, { ok: true, skipped: "too_soon" });
    // A manual refresh only waits a minute.
    const manual = await syncRecentWhoop(env, { trigger: "manual", minIntervalMs: MANUAL_MIN_INTERVAL_MS }, { now: () => NOW + 5 * 60_000, ingest });
    assert.equal(manual.ok, true);
    assert.equal(windows.length, 2);
  });

  it("pulls connected WHOOP even with Oura preferred, and skips unconnected WHOOP", async () => {
    let calls = 0;
    const ingest = async () => {
      calls++;
      return { written: 0, skipped: 0 };
    };
    const r = await syncRecentWhoop(makeEnv({ wearable: "oura" }).env, { trigger: "cron", minIntervalMs: 0 }, { ingest });
    assert.equal(r.ok, true);
    assert.equal(calls, 1);
    assert.deepEqual(await syncRecentWhoop(makeEnv({ whoop: false }).env, { trigger: "cron", minIntervalMs: 0 }, { ingest }), { ok: true, skipped: "not_connected" });
    assert.equal(calls, 1);
  });

  it("logs a failure and never throws", async () => {
    const { env, raw } = makeEnv();
    const r = await syncRecentWhoop(env, { trigger: "cron", minIntervalMs: 0 }, {
      now: () => NOW,
      ingest: async () => {
        throw new Error("whoop 401 and no tokens");
      },
    });
    assert.equal(r.ok, false);
    const rows = syncLog(raw);
    assert.equal(rows.at(-1)?.status, "error");
    assert.equal(rows.at(-1)?.source, "whoop");
    assert.match(rows.at(-1)?.error_text ?? "", /401/);
  });
});

describe("POST /api/refresh", () => {
  const realFetch = globalThis.fetch;
  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  async function call(env: unknown, body: unknown = {}) {
    const res = await api.request("https://app.example/refresh", { method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json" } }, env as never);
    return { status: res.status, body: (await res.json()) as Record<string, any> };
  }

  it("answers per source, even when nothing is connected", async () => {
    const { env } = makeEnv({ whoop: false });
    const r = await call(env);
    assert.equal(r.status, 200);
    assert.equal(r.body.calendar.ok, false);
    assert.equal(r.body.calendar.needsGoogle, true);
    assert.deepEqual(r.body.whoop, { ok: true, skipped: "not_connected" });
    assert.equal(r.body.whoopWeb, undefined);
    assert.ok(r.body.syncedAt);
  });

  it("asks WHOOP for sleep, recovery, cycles and workouts", async () => {
    const { env, raw } = makeEnv();
    const paths: string[] = [];
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = new URL(String(input));
      paths.push(url.pathname);
      return new Response(JSON.stringify({ records: [], next_token: null }), { status: 200, headers: { "content-type": "application/json" } });
    }) as typeof fetch;
    const r = await call(env);
    assert.equal(r.status, 200);
    assert.equal(r.body.whoop.ok, true);
    assert.equal(r.body.whoop.written, 0);
    assert.deepEqual(paths.sort(), ["/developer/v2/activity/sleep", "/developer/v2/activity/workout", "/developer/v2/cycle", "/developer/v2/recovery"]);
    assert.ok(syncLog(raw).some((row) => row.source === "whoop" && row.trigger === "manual" && row.status === "ok"));
  });
});
