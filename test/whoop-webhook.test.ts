import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { afterEach, it } from "node:test";
import type { Env } from "../src/env.ts";
import { handleQueue } from "../src/queue/consumer.ts";
import { hooks } from "../src/routes/hooks.ts";
import { resetWhoopRateState } from "../src/sources/whoop/client.ts";
import { WHOOP_API, WHOOP_TOKEN_KEY } from "../src/sources/whoop/endpoints.ts";
import { makeWhoopFixtures } from "../src/sources/whoop/fixtures.ts";
import type { WhoopWebhookQueueMessage } from "../src/sources/whoop/webhook.ts";
import { fakeKv, sqliteD1 } from "./sqlite-d1.ts";

const CLIENT_SECRET = "test-whoop-client-secret";
const WEBHOOK_SECRET = "test-whoop-webhook-secret";
const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
  resetWhoopRateState();
});

function fixture() {
  const { db, raw } = sqliteD1();
  const kv = fakeKv({ [WHOOP_TOKEN_KEY]: JSON.stringify({
    access_token: "synthetic-whoop-token",
    expires_at: new Date(Date.now() + 3_600_000).toISOString(),
  }) });
  const cacheWrites: Array<[string, number | undefined]> = [];
  const tokens = {
    ...kv,
    put: async (key: string, value: string, opts: { expirationTtl?: number }) => {
      cacheWrites.push([key, opts?.expirationTtl]);
      await kv.put(key, value);
    },
  };
  const queued: WhoopWebhookQueueMessage[] = [];
  let queueUnavailable = false;
  const env = {
    DB: db, TOKENS: tokens, WEARABLE: "whoop", WHOOP_CLIENT_SECRET: CLIENT_SECRET,
    RAW: { put: async () => {} },
    INGEST_Q: { send: async (body: WhoopWebhookQueueMessage, opts: QueueSendOptions) => {
      assert.equal(opts.delaySeconds, 5);
      if (queueUnavailable) throw new Error("queue unavailable");
      queued.push(body);
    } },
  } as unknown as Env;
  const paths: string[] = [];
  globalThis.fetch = async (input) => {
    assert.ok(String(input).startsWith(`${WHOOP_API}/v2/`));
    paths.push(new URL(String(input)).pathname);
    return Response.json({ records: [] });
  };
  return { env, kv, raw, paths, queued, cacheWrites, setQueueUnavailable: (value: boolean) => { queueUnavailable = value; } };
}

function event(traceId = "trace-1", type = "sleep.updated") {
  return { user_id: 1, id: "d3b52704-de5f-4e98-a396-938a52e3e968", type, trace_id: traceId };
}

async function deliver(env: Env, opts: {
  body?: string;
  secret?: string;
  timestamp?: string;
  signature?: string;
  signedBody?: string;
} = {}) {
  const body = opts.body ?? JSON.stringify(event());
  const timestamp = opts.timestamp ?? String(Date.now());
  const signature = opts.signature ?? createHmac("sha256", opts.secret ?? CLIENT_SECRET)
    .update(timestamp + (opts.signedBody ?? body)).digest("base64");
  const tasks: Promise<unknown>[] = [];
  const ctx = { waitUntil: (task: Promise<unknown>) => tasks.push(task) } as ExecutionContext;
  const response = await hooks.fetch(new Request("https://test.invalid/whoop", {
    method: "POST",
    headers: { "X-WHOOP-Signature": signature, "X-WHOOP-Signature-Timestamp": timestamp },
    body,
  }), env, ctx);
  return { response, tasks };
}

async function consume(env: Env, bodies: WhoopWebhookQueueMessage[]) {
  const acked: number[] = [];
  const retries: Array<{ id: number; delay: number }> = [];
  await handleQueue({ messages: bodies.map((body) => ({
    body,
    ack: () => acked.push(body.receiptId),
    retry: ({ delaySeconds }: QueueRetryOptions) => retries.push({ id: body.receiptId, delay: delaySeconds! }),
  })) } as unknown as MessageBatch<WhoopWebhookQueueMessage>, env);
  return { acked, retries };
}

it("rejects bad signatures, unsigned requests, stale or future timestamps, and seconds timestamps", async () => {
  const { env, queued, paths } = fixture();
  for (const opts of [
    { signature: "invalid-base64" },
    { secret: "wrong-secret", body: "invalid JSON" },
    { signature: "" },
    { timestamp: String(Date.now() - 301_000) },
    { timestamp: String(Date.now() + 301_000) },
    { timestamp: String(Math.floor(Date.now() / 1000)) },
  ]) {
    const { response, tasks } = await deliver(env, opts);
    assert.equal(response.status, 401);
    assert.equal(tasks.length, 0);
  }
  assert.deepEqual(queued, []);
  assert.deepEqual(paths, []);
});

it("uses the dedicated secret when configured and verifies the original UTF-8 body before parsing", async () => {
  const { env, paths, queued } = fixture();
  env.WHOOP_WEBHOOK_SECRET = WEBHOOK_SECRET;
  const compact = JSON.stringify({ ...event("trace-raw"), extra: "é⌚" });
  const body = `\uFEFF \n${compact}\n`;
  assert.equal((await deliver(env, { body })).response.status, 401);
  assert.equal((await deliver(env, { body, signedBody: compact, secret: WEBHOOK_SECRET })).response.status, 401);
  assert.equal((await deliver(env, { body: "null", secret: WEBHOOK_SECRET })).response.status, 400);
  assert.equal((await deliver(env, { body: "{", secret: WEBHOOK_SECRET })).response.status, 400);
  const accepted = await deliver(env, { body, secret: WEBHOOK_SECRET });
  assert.equal(accepted.response.status, 204);
  assert.equal(await accepted.response.text(), "");
  await Promise.all(accepted.tasks);
  assert.deepEqual(paths, ["/developer/v2/activity/sleep", "/developer/v2/recovery", "/developer/v2/cycle", "/developer/v2/activity/workout"]);
  assert.deepEqual(await consume(env, queued), { acked: [queued[0].receiptId], retries: [] });
});

it("falls back to the client secret and deduplicates traces even across concurrent KV misses", async () => {
  const { env, kv, paths, queued, cacheWrites } = fixture();
  const isolatedTokens = { ...env.TOKENS, get: async (key: string) => key.startsWith("whoop:webhook:") ? null : kv.get(key) };
  const deliveries = await Promise.all([deliver(env), deliver({ ...env, TOKENS: isolatedTokens } as Env)]);
  assert.ok(deliveries.every(({ response }) => response.status === 204));
  await Promise.all(deliveries.flatMap(({ tasks }) => tasks));
  const duplicate = await deliver(env);
  assert.equal(duplicate.response.status, 204);
  assert.deepEqual(duplicate.tasks, []);
  assert.ok(cacheWrites.some(([key, ttl]) => key === "whoop:webhook:trace-1" && ttl === 86_400));
  assert.equal(new Set(queued.map((msg) => msg.receiptId)).size, 1);
  assert.equal((await consume(env, queued)).retries.length, 0);
  assert.equal(paths.length, 4);
});

it("ignores unknown events and logs each deletion once with its trace", async () => {
  const { env, raw, kv, queued, paths } = fixture();
  const unknown = await deliver(env, { body: JSON.stringify(event("unknown", "profile.updated")) });
  assert.equal(unknown.response.status, 204);
  assert.deepEqual(unknown.tasks, []);
  assert.deepEqual(queued, []);

  await kv.delete(WHOOP_TOKEN_KEY);
  for (const kind of ["sleep", "recovery", "workout"]) {
    const body = JSON.stringify(event(kind, `${kind}.deleted`));
    const [first, second] = await Promise.all([deliver(env, { body }), deliver(env, { body })]);
    assert.deepEqual([first.response.status, second.response.status], [204, 204]);
    await Promise.all([...first.tasks, ...second.tasks]);
  }
  const rows = raw.prepare(`SELECT endpoint, event_id, status, error_text FROM sync_log WHERE source = 'whoop' ORDER BY id`).all();
  assert.deepEqual(rows.map((row) => ({ ...row })), ["sleep", "recovery", "workout"].map((kind) => ({
    endpoint: `${kind}.deleted`, event_id: kind, status: "partial", error_text: "WHOOP deletion deferred",
  })));
  assert.deepEqual(paths, []);
});

it("coalesces distinct concurrent and sequential traces and pulls the last score after cooldown", async () => {
  const { env, raw, queued, paths } = fixture();
  const { promise: firstCollecting, resolve: firstStarted } = Promise.withResolvers<void>();
  const { promise: unblockFirst, resolve: finishFirst } = Promise.withResolvers<void>();
  const sleep = makeWhoopFixtures(1).sleep[0] as { score: { sleep_performance_percentage: number } };
  let latestScore = 71;
  globalThis.fetch = async (input) => {
    assert.ok(String(input).startsWith(`${WHOOP_API}/v2/`));
    const path = new URL(String(input)).pathname;
    paths.push(path);
    if (!path.endsWith("/sleep")) return Response.json({ records: [] });
    sleep.score.sleep_performance_percentage = latestScore;
    const snapshot = Response.json({ records: [sleep] });
    if (paths.length === 1) {
      firstStarted();
      await unblockFirst;
    }
    return snapshot;
  };
  const send = (id: number) => deliver({ ...env }, { body: JSON.stringify(event(`burst-${id}`, "recovery.updated")) });
  const first = await send(0);
  assert.equal(first.response.status, 204);
  await firstCollecting;
  try {
    const simultaneous = await Promise.all(Array.from({ length: 30 }, (_, index) => send(index + 1)));
    assert.ok(simultaneous.every(({ response }) => response.status === 204));
    await Promise.all(simultaneous.flatMap(({ tasks }) => tasks));
    const waiting = await consume(env, queued.slice(0, 10));
    assert.equal(waiting.acked.length, 0);
    assert.ok(waiting.retries.every(({ delay }) => delay > 0 && delay <= 10));
    assert.equal(paths.length, 1);
  } finally {
    finishFirst();
  }
  await Promise.all(first.tasks);
  assert.equal(raw.prepare("SELECT score FROM daily_sleep WHERE source = 'whoop'").get()?.score, 71);

  for (let id = 31; id <= 60; id++) {
    const delivery = await send(id);
    assert.equal(delivery.response.status, 204);
    await Promise.all(delivery.tasks);
  }
  latestScore = 96;
  const duringCooldown = await consume(env, queued.slice(-10));
  assert.equal(duringCooldown.acked.length, 0);
  assert.equal(duringCooldown.retries.length, 10);
  assert.ok(duringCooldown.retries.every(({ delay }) => delay > 0 && delay <= 21));
  assert.equal(paths.length, 4);

  // Advance the stored deadline to avoid waiting through a real cooldown.
  raw.exec("UPDATE whoop_webhook_sync SET available_at = unixepoch()");
  const batches = await Promise.all(Array.from({ length: 7 }, (_, index) => consume({ ...env }, queued.slice(index * 10, index * 10 + 10))));
  assert.ok(batches.some(({ acked }) => acked.length > 0));
  assert.equal((await consume(env, queued.slice(-10))).retries.length, 0);
  assert.equal(paths.length, 8);
  assert.equal(raw.prepare("SELECT score FROM daily_sleep WHERE source = 'whoop'").get()?.score, 96);
});

it("leaves a trace retryable when queue intake fails", async () => {
  const { env, kv, setQueueUnavailable, queued } = fixture();
  await kv.delete(WHOOP_TOKEN_KEY);
  setQueueUnavailable(true);
  const unavailable = await deliver(env);
  assert.equal(unavailable.response.status, 503);
  assert.deepEqual(unavailable.tasks, []);
  assert.equal(await kv.get("whoop:webhook:trace-1"), null);
  setQueueUnavailable(false);
  const retried = await deliver(env);
  assert.equal(retried.response.status, 204);
  await Promise.all(retried.tasks);
  assert.equal(queued.length, 1);
});

it("keeps a receipt pending and backs off across isolates after a WHOOP 429", async () => {
  const { env, raw, queued } = fixture();
  let calls = 0;
  globalThis.fetch = async (input) => {
    assert.ok(String(input).startsWith(`${WHOOP_API}/v2/`));
    calls++;
    return new Response(null, { status: 429, headers: { "Retry-After": "75" } });
  };
  const delivery = await deliver(env);
  assert.equal(delivery.response.status, 204);
  await Promise.all(delivery.tasks);
  assert.equal(raw.prepare("SELECT covered_through FROM whoop_webhook_sync").get()?.covered_through, 0);
  resetWhoopRateState();
  const { acked, retries } = await consume({ ...env }, queued);
  assert.deepEqual(acked, []);
  assert.equal(retries.length, 1);
  assert.ok(retries[0].delay >= 74);
  assert.equal(calls, 1);
});
