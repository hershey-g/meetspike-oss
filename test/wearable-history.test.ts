import assert from "node:assert/strict";
import { test } from "node:test";
import type { Env } from "../src/env.ts";
import { api } from "../src/routes/api.ts";
import { HISTORY_START_DAY, historyWindows, runWearableHistory } from "../src/lib/wearable-history.ts";
import { writeSyncLog } from "../src/lib/synclog.ts";
import { addUtcDays } from "../src/sources/oura/endpoints.ts";
import { listDocuments, ouraRetryAfter, RateLimitError } from "../src/sources/oura/client.ts";
import { ingestOneDocument } from "../src/sources/oura/ingest.ts";
import { fakeKv, sqliteD1 } from "./sqlite-d1.ts";

const plan = {
  source: "oura" as const, startDay: "2026-10-30", endDay: "2026-11-08", trigger: "history-test", fullHistory: true,
};
const now = Date.parse("2026-11-08T00:00:00Z");
const token = JSON.stringify({ access_token: "test-only", expires_at: "2100-01-01T00:00:00Z" });

test("full-history planning covers inclusive windows through DST and leap days", () => {
  for (const source of ["oura", "whoop"] as const) {
    const windows = historyWindows({ ...plan, source, startDay: HISTORY_START_DAY, endDay: "2024-03-01" });
    const endpoints = [...new Set(windows.map((w) => w.endpoint))];
    assert.deepEqual(endpoints, source === "oura"
      ? ["daily_sleep", "daily_readiness", "sleep", "heartrate"]
      : ["recovery,cycle,sleep,workout"]);
    for (const key of endpoints) {
      const chunks = windows.filter((w) => w.endpoint === key);
      assert.equal(chunks[0].start, HISTORY_START_DAY);
      assert.equal(chunks.at(-1)?.end, "2024-03-01");
      chunks.slice(1).forEach((chunk, i) => assert.equal(chunk.start, addUtcDays(chunks[i].end, 1)));
    }
  }
  assert.deepEqual(historyWindows(plan).filter((w) => w.endpoint === "heartrate").map((w) => [w.start, w.end]), [
    ["2026-10-30", "2026-11-05"], ["2026-11-06", "2026-11-08"],
  ]);
});

test("resumes from durable checkpoints and waits for the full provider Retry-After", async () => {
  const { db } = sqliteD1();
  const env = { DB: db } as Env;
  const waits: number[] = [];
  const steps = {
    do: async (_name: string, _opts: unknown, fn: () => Promise<unknown>) => fn(),
    sleep: async (_name: string, delay: number) => { waits.push(delay); },
  } as never;
  const windows = historyWindows(plan);
  const calls: string[] = [];
  let stopped = false;
  let rateLimited = false;
  const ingest = async (window: (typeof windows)[number]) => {
    calls.push(window.endpoint);
    if (window.endpoint === "daily_readiness" && !stopped) {
      stopped = true;
      throw new Error("simulated interruption");
    }
    if (window.endpoint === "daily_readiness" && !rateLimited) {
      rateLimited = true;
      throw new RateLimitError(375);
    }
    await writeSyncLog(env, {
      trigger: plan.trigger, endpoint: window.endpoint, windowStart: window.start,
      windowEnd: window.end, status: "ok", rowsWritten: 1,
    });
    return { written: 1, skipped: 0 };
  };
  await assert.rejects(runWearableHistory(env, steps, plan, ingest), /simulated interruption/);
  const result = await runWearableHistory(env, steps, plan, ingest);
  assert.equal(calls.filter((key) => key === "daily_sleep").length, 1);
  assert.ok(waits.includes(375_000));
  assert.equal(result.completedWindows, windows.length);
  assert.equal(result.written, windows.length);
  calls.length = 0;
  assert.deepEqual(await runWearableHistory(env, steps, plan, ingest), result);
  assert.deepEqual(calls, []);
});

test("Oura paginates HR into stable UTC day documents without losing the DST boundary", async (t) => {
  const env = { TOKENS: fakeKv({ "oura:tokens": token }), OURA_SANDBOX: "false" } as never;
  const sample = (timestamp: string) => ({ timestamp, bpm: 70, source: "awake" });
  const pages = [
    { next_token: "next", data: [sample("2026-11-01T23:55:00Z"), sample("2026-11-02T00:00:00Z")] },
    { data: [sample("2026-11-02T23:59:59.999Z"), sample("2026-11-03T00:00:00Z")] },
  ];
  const requests: URL[] = [];
  t.mock.method(globalThis, "fetch", async (resource: string) => {
    requests.push(new URL(resource));
    return Response.json(pages.shift());
  });
  const docs = await listDocuments(env, "heartrate", { start: "2026-11-01", end: "2026-11-02" });
  assert.deepEqual(docs.map((doc) => [doc.id, (doc.data as unknown[]).length]), [
    ["hr-2026-11-01-daily", 1], ["hr-2026-11-02-daily", 2],
  ]);
  assert.equal(requests[0].searchParams.get("start_datetime"), "2026-11-01T00:00:00Z");
  assert.equal(requests[0].searchParams.get("end_datetime"), "2026-11-03T00:00:00Z");
  assert.equal(requests[1].searchParams.get("next_token"), "next");
  assert.equal(ouraRetryAfter(new Headers({ "Retry-After": "300" }), now), 300);
  assert.equal(ouraRetryAfter(new Headers({ "X-RateLimit-Reset": String(now / 1000 + 123) }), now), 123);
});

test("retries an archived revision when projection fails and skips it once projected", async () => {
  const { db, raw } = sqliteD1();
  const objects = new Set<string>();
  const env = { DB: db, RAW: { put: async (key: string) => { objects.add(key); } } } as never;
  const doc = { id: "readiness", day: "2026-10-31", score: 79 };
  raw.exec(`CREATE TRIGGER interrupt BEFORE INSERT ON daily_readiness BEGIN SELECT RAISE(FAIL, 'interrupted'); END`);
  await assert.rejects(ingestOneDocument(env, "daily_readiness", doc), /interrupted/);
  assert.equal(raw.prepare("SELECT projection_pending FROM raw_object").get()?.projection_pending, 1);
  raw.exec("DROP TRIGGER interrupt");
  assert.equal(await ingestOneDocument(env, "daily_readiness", doc), "written");
  assert.equal(await ingestOneDocument(env, "daily_readiness", doc), "skipped");
  assert.equal(raw.prepare("SELECT score FROM daily_readiness").get()?.score, 79);
  assert.equal(raw.prepare("SELECT projection_pending FROM raw_object").get()?.projection_pending, 0);
  assert.equal(objects.size, 1);
});

test("the full-history start, progress and resume routes require admin authentication", async () => {
  const { db } = sqliteD1();
  let created: any;
  let restarts = 0;
  const env = {
    DB: db, TOKENS: fakeKv({ "oura:tokens": token, "whoop:tokens": token }), OURA_SANDBOX: "false",
    INGEST_ADMIN_SECRET: "test-admin",
    BACKFILL: {
      create: async (params: any) => { created = params; return { id: params.id }; },
      get: async () => ({ status: async () => ({ status: "errored" }), restart: async () => { restarts++; } }),
    },
  } as never;
  const path = "/history/backfill";
  const headers = { "content-type": "application/json", "x-admin-secret": "test-admin" };
  const request = { method: "POST", headers, body: JSON.stringify({ source: "oura", endDay: "2026-11-03" }) };
  assert.equal((await api.request(path, { ...request, headers: {} }, env)).status, 401);
  assert.equal(created, undefined);
  const accepted = await api.request(path, request, env);
  assert.equal(accepted.status, 202);
  assert.equal(created.params.startDay, HISTORY_START_DAY);
  assert.equal(created.params.source, "oura");
  const { workflowId } = await accepted.json();
  const progress = `${path}/${workflowId}`;
  assert.equal((await api.request(progress, {}, env)).status, 401);
  assert.equal((await api.request(`${progress}/resume`, { method: "POST" }, env)).status, 401);
  assert.equal((await api.request(progress, { headers }, env)).status, 200);
  assert.equal((await api.request(`${progress}/resume`, { method: "POST", headers }, env)).status, 202);
  assert.equal(restarts, 1);
  const bad = await api.request(path, { ...request, body: JSON.stringify({ source: "oura", startDay: "2026-02-30" }) }, env);
  assert.equal(bad.status, 400);
});
