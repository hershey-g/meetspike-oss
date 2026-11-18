import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import { api } from "../src/routes/api.ts";
import { saveAiKey } from "../src/lib/ai-key.ts";
import type { Env } from "../src/env.ts";

const SECRET = "s".repeat(40);
const KEY = "sk-ant-api03-test-test-test-test-test-test-0000";

function fakeKv() {
  const store = new Map<string, string>();
  return {
    get: async (k: string) => store.get(k) ?? null,
    put: async (k: string, v: string) => void store.set(k, v),
    delete: async (k: string) => void store.delete(k),
  };
}

const ROWS: Record<string, Array<Record<string, unknown>>> = {
  calendar_event: [
    {
      id: "m1",
      source: "google",
      day: "2026-11-05",
      start_utc: "2026-11-05T15:00:00.000Z",
      end_utc: "2026-11-05T16:00:00.000Z",
      start_local: "2026-11-05T10:00:00-05:00",
      duration_s: 3600,
      title: "Client review",
      kind: "client",
      attendees_json: JSON.stringify([{ email: "sam@client.example", displayName: "Sam Okafor" }]),
      after_hours: 0,
    },
  ],
  daily_readiness: [{ day: "2026-11-06", score: 44 }],
  daily_sleep: [{ day: "2026-11-06", score: 61 }],
};

function fakeDb() {
  return {
    prepare(sql: string) {
      const table = /FROM (\w+)/.exec(sql)?.[1] ?? "";
      const stmt = {
        bind: () => stmt,
        all: async () => ({ results: ROWS[table] ?? [] }),
        first: async () => null,
        run: async () => ({ success: true }),
      };
      return stmt;
    },
  } as unknown as D1Database;
}

async function envWithKey(): Promise<Env> {
  const env = { WEARABLE: "whoop", AI_KEY_SECRET: SECRET, TOKENS: fakeKv(), DB: fakeDb() } as unknown as Env;
  await saveAiKey(env, KEY);
  return env;
}

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

function stubAnthropic(reply: Record<string, unknown>, status = 200) {
  const calls: Array<{ url: string; headers: Headers; body: any }> = [];
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init);
    calls.push({ url: req.url, headers: req.headers, body: await req.json().catch(() => null) });
    return new Response(JSON.stringify(reply), { status, headers: { "content-type": "application/json" } });
  }) as typeof fetch;
  return calls;
}

async function post(path: string, body: unknown, env: Env) {
  const res = await api.request(
    `https://app.example${path}`,
    { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) },
    env as never,
  );
  return { status: res.status, body: (await res.json()) as Record<string, any> };
}

const MESSAGE = {
  id: "msg_1",
  type: "message",
  role: "assistant",
  model: "claude-opus-5-5",
  content: [{ type: "text", text: "**Nov 5.** You woke at 44% the next morning." }],
  stop_reason: "end_turn",
  stop_sequence: null,
  usage: { input_tokens: 10, output_tokens: 10 },
};

describe("POST /api/ask", () => {
  it("sends the question with the user's key, the data block, effort and fallbacks, and returns the text", async () => {
    const env = await envWithKey();
    const calls = stubAnthropic(MESSAGE);
    const { status, body } = await post(
      "/ask",
      { question: "Which day cost me most?", start: "2026-11-01", end: "2026-11-07", history: [{ role: "assistant", content: "dropped: must start with user" }] },
      env,
    );
    assert.equal(status, 200);
    assert.equal(body.answer, "**Nov 5.** You woke at 44% the next morning.");
    assert.equal(calls.length, 1);
    const call = calls[0];
    assert.match(call.url, /\/v1\/messages/);
    assert.equal(call.headers.get("authorization"), `Bearer ${KEY}`, "the saved key is the one used");
    assert.match(call.headers.get("anthropic-beta") ?? "", /server-side-fallback-2026-07-01/);
    assert.equal(call.body.model, "claude-opus-5-5");
    assert.equal(call.body.fallbacks, "default");
    assert.deepEqual(call.body.output_config, { effort: "medium" });
    assert.deepEqual(call.body.messages, [{ role: "user", content: "Which day cost me most?" }]);
    const data = call.body.system[1].text as string;
    assert.match(data, /2026-11-05 Thu .* next recovery 44, sleep 61 \| 1 meetings/);
    assert.match(data, /10:00 Client review \(client, 60m\) with Sam Okafor/);
    assert.doesNotMatch(data, /sam@client\.example/);
    assert.deepEqual(call.body.system[1].cache_control, { type: "ephemeral" });
  });

  it("asks for a key when none is saved, without calling Anthropic", async () => {
    const env = { WEARABLE: "whoop", AI_KEY_SECRET: SECRET, TOKENS: fakeKv(), DB: fakeDb() } as unknown as Env;
    const calls = stubAnthropic(MESSAGE);
    const { status, body } = await post("/ask", { question: "hi" }, env);
    assert.equal(status, 409);
    assert.equal(body.needsKey, true);
    assert.equal(calls.length, 0);
  });

  it("says plainly when Anthropic rejects the saved key", async () => {
    const env = await envWithKey();
    stubAnthropic({ type: "error", error: { type: "authentication_error", message: "invalid x-api-key" } }, 401);
    const { status, body } = await post("/ask", { question: "hi" }, env);
    assert.equal(status, 400);
    assert.equal(body.needsKey, true);
    assert.match(body.error, /no longer accepts the saved key/);
  });

  it("handles a refusal without showing an empty answer", async () => {
    const env = await envWithKey();
    stubAnthropic({ ...MESSAGE, content: [], stop_reason: "refusal", stop_details: { type: "refusal", category: null, explanation: null } });
    const { status, body } = await post("/ask", { question: "hi" }, env);
    assert.equal(status, 200);
    assert.equal(body.refused, true);
    assert.match(body.answer, /declined/);
  });
});
