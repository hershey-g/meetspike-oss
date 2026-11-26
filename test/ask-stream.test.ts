import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import { api } from "../src/routes/api.ts";
import { saveAiKey } from "../src/lib/ai-key.ts";
import { inspect } from "node:util";
import { MAX_ASK_BODY_BYTES, countScoredNights, readJsonLimited, safeErrorMeta, shortDate } from "../src/routes/ask.ts";
import { calendarDayInZone } from "../src/lib/time.ts";
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
    {
      id: "m2",
      source: "google",
      day: "2026-11-06",
      start_utc: "2026-11-06T15:00:00.000Z",
      end_utc: "2026-11-06T15:30:00.000Z",
      start_local: "2026-11-06T10:00:00-05:00",
      duration_s: 1800,
      title: "Standup",
      kind: "internal",
      attendees_json: "[]",
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
      let args: unknown[] = [];
      const stmt = {
        bind: (...values: unknown[]) => {
          args = values;
          return stmt;
        },
        all: async () => ({ results: table.startsWith("daily_") && args[0] !== "whoop" ? [] : ROWS[table] ?? [] }),
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
  await env.TOKENS.put("settings:source_display:whoop", "true");
  return env;
}

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

type AnthropicEvent = Record<string, unknown>;

function sseBody(events: AnthropicEvent[]): string {
  return events.map((e) => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join("");
}

function messageEvents(texts: string[], stopReason = "end_turn"): AnthropicEvent[] {
  return [
    {
      type: "message_start",
      message: { id: "msg_1", type: "message", role: "assistant", model: "claude-opus-5-5", content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 0 } },
    },
    ...(texts.length ? [{ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }] : []),
    ...texts.map((t) => ({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: t } })),
    ...(texts.length ? [{ type: "content_block_stop", index: 0 }] : []),
    { type: "message_delta", delta: { stop_reason: stopReason, stop_sequence: null }, usage: { output_tokens: 5 } },
    { type: "message_stop" },
  ];
}

/** Anthropic answers with a stream of events, or with a JSON error. */
function stubAnthropicStream(events: AnthropicEvent[] | { error: Record<string, unknown>; status: number }) {
  const calls: Array<{ url: string; body: any; signal: AbortSignal | null }> = [];
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init);
    calls.push({ url: req.url, body: await req.json().catch(() => null), signal: init?.signal ?? null });
    if (!Array.isArray(events)) {
      return new Response(JSON.stringify(events.error), { status: events.status, headers: { "content-type": "application/json" } });
    }
    return new Response(sseBody(events), { status: 200, headers: { "content-type": "text/event-stream" } });
  }) as typeof fetch;
  return calls;
}

type Sse = { event: string; data: any };

function parseSse(text: string): Sse[] {
  return text
    .split("\n\n")
    .map((block) => block.trim())
    .filter((block) => block && !block.startsWith(":"))
    .map((block) => {
      const event = /^event: (.*)$/m.exec(block)?.[1] ?? "message";
      const data = block
        .split("\n")
        .filter((l) => l.startsWith("data: "))
        .map((l) => l.slice(6))
        .join("\n");
      return { event, data: JSON.parse(data) };
    });
}

async function postStream(body: unknown, env: Env, signal?: AbortSignal) {
  return api.request(
    "https://app.example/ask/stream",
    { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal },
    env as never,
  );
}

describe("POST /api/ask/stream", () => {
  it("returns plain JSON errors before streaming: no question, no key, bad range", async () => {
    const env = await envWithKey();
    const calls = stubAnthropicStream(messageEvents(["x"]));

    let res = await postStream({ question: "  " }, env);
    assert.equal(res.status, 400);
    assert.match(res.headers.get("content-type") ?? "", /application\/json/);
    assert.match(((await res.json()) as any).error, /Ask a question/);

    res = await postStream({ question: "hi", start: "2026-11-07", end: "2026-11-01" }, env);
    assert.equal(res.status, 400);
    assert.ok(((await res.json()) as any).error);

    const noKey = { WEARABLE: "whoop", AI_KEY_SECRET: SECRET, TOKENS: fakeKv(), DB: fakeDb() } as unknown as Env;
    res = await postStream({ question: "hi" }, noKey);
    assert.equal(res.status, 409);
    assert.equal(((await res.json()) as any).needsKey, true);
    assert.equal(calls.length, 0, "Anthropic is never called");
  });

  it("streams real steps in order, the text deltas, then done", async () => {
    const env = await envWithKey();
    const calls = stubAnthropicStream(messageEvents(["**Nov 5** ", "cost you ", "the most."]));
    const res = await postStream({ question: "Which day cost me most?", start: "2026-11-01", end: "2026-11-07" }, env);
    assert.equal(res.status, 200);
    assert.match(res.headers.get("content-type") ?? "", /text\/event-stream/);
    assert.equal(res.headers.get("cache-control"), "private, no-store, no-transform");
    const events = parseSse(await res.text());

    const steps = events.filter((e) => e.event === "step").map((e) => `${e.data.id}:${e.data.status}:${e.data.label}`);
    assert.deepEqual(steps, [
      "calendar:active:Reading your calendar",
      "calendar:done:Read 2 meetings from Nov 1 to Nov 7",
      "body:active:Lining up sleep and recovery",
      "body:done:Lined up 1 night of WHOOP scores",
      "think:active:Thinking it through",
      "think:done:Thought it through",
      "write:active:Writing the answer",
      "write:done:Wrote the answer",
    ]);
    const text = events.filter((e) => e.event === "text").map((e) => e.data.delta);
    assert.deepEqual(text, ["**Nov 5** ", "cost you ", "the most."]);
    const last = events.at(-1)!;
    assert.equal(last.event, "done");
    // Build 10: done also says what all history is and where the ranked dates came from.
    const today = calendarDayInZone(new Date().toISOString());
    assert.deepEqual(last.data, {
      truncated: false, model: "claude-opus-5-5", start: "2026-11-01", end: "2026-11-07",
      baselineStart: today, baselineEnd: today, rangeSource: "tab",
    });

    // Steps come before the first text, and the write step closes after the last.
    const at = (pred: (e: Sse) => boolean) => events.findIndex(pred);
    const lastText = events.map((e) => e.event).lastIndexOf("text");
    assert.ok(at((e) => e.event === "text") > at((e) => e.data.id === "write" && e.data.status === "active"));
    assert.ok(at((e) => e.data.id === "write" && e.data.status === "done") > lastText);

    assert.equal(calls.length, 1);
    assert.equal(calls[0].body.stream, true);
    assert.equal(calls[0].body.model, "claude-opus-5-5");
    assert.deepEqual(calls[0].body.messages, [{ role: "user", content: "Which day cost me most?" }]);
    assert.match(calls[0].body.system[1].text, /Client review/);
  });

  it("marks a truncated answer", async () => {
    const env = await envWithKey();
    stubAnthropicStream(messageEvents(["Part"], "max_tokens"));
    const events = parseSse(await (await postStream({ question: "hi" }, env)).text());
    assert.equal(events.at(-1)!.data.truncated, true);
  });

  it("says Claude declined on a refusal, instead of an empty answer", async () => {
    const env = await envWithKey();
    stubAnthropicStream(messageEvents([], "refusal"));
    const events = parseSse(await (await postStream({ question: "hi" }, env)).text());
    const text = events.filter((e) => e.event === "text").map((e) => e.data.delta).join("");
    assert.match(text, /declined/);
    const done = events.at(-1)!;
    assert.equal(done.event, "done");
    assert.equal(done.data.refused, true);
  });

  it("sends an error event asking for a new key when Anthropic rejects the saved one", async () => {
    const env = await envWithKey();
    stubAnthropicStream({ error: { type: "error", error: { type: "authentication_error", message: "invalid x-api-key" } }, status: 401 });
    const res = await postStream({ question: "hi" }, env);
    assert.equal(res.status, 200, "the stream had already started");
    const events = parseSse(await res.text());
    const err = events.at(-1)!;
    assert.equal(err.event, "error");
    assert.equal(err.data.needsKey, true);
    assert.match(err.data.error, /no longer accepts the saved key/);
    assert.ok(!events.some((e) => e.event === "done"));
  });

  it("stops quietly when the browser aborts: the Anthropic call is cancelled and nothing more is sent", async () => {
    const env = await envWithKey();
    let anthropicSignal: AbortSignal | null = null;
    globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      anthropicSignal = init?.signal ?? null;
      const enc = new TextEncoder();
      const first = sseBody(messageEvents(["Client pitches "]).slice(0, 3));
      const body = new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(enc.encode(first));
          // Then hangs, as if Claude were still writing, until aborted.
          init?.signal?.addEventListener("abort", () => controller.error(new DOMException("aborted", "AbortError")));
        },
      });
      return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
    }) as typeof fetch;

    const browser = new AbortController();
    const res = await postStream({ question: "hi" }, env, browser.signal);
    const reader = res.body!.getReader();
    const dec = new TextDecoder();
    let seen = "";
    while (!seen.includes("event: text")) {
      const { value, done } = await reader.read();
      if (done) break;
      seen += dec.decode(value);
    }
    assert.match(seen, /Client pitches/);

    browser.abort();
    // The rest of the stream ends without an error or a done event.
    for (;;) {
      const { value, done } = await reader.read().catch(() => ({ value: undefined, done: true }));
      if (done) break;
      seen += dec.decode(value);
    }
    assert.ok(anthropicSignal, "a signal was passed to Anthropic");
    assert.equal((anthropicSignal as AbortSignal).aborted, true, "the Anthropic request was cancelled");
    const events = parseSse(seen);
    assert.ok(!events.some((e) => e.event === "error"), "no error event after a stop");
    assert.ok(!events.some((e) => e.event === "done"), "no done event after a stop");
  });
});

describe("ask request size limit", () => {
  const big = { question: "hi", pad: "x".repeat(1024 * 1024) };

  for (const path of ["https://app.example/ask/stream", "https://app.example/ask"]) {
    it(`refuses a 1 MiB body with 413 before parsing or calling Anthropic (${new URL(path).pathname})`, async () => {
      const env = await envWithKey();
      const calls = stubAnthropicStream(messageEvents(["x"]));
      const res = await api.request(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(big) }, env as never);
      assert.equal(res.status, 413);
      assert.match(((await res.json()) as any).error, /too long/);
      assert.equal(calls.length, 0, "Anthropic is never called");
    });
  }

  it("refuses on a declared Content-Length before reading the body", async () => {
    const env = await envWithKey();
    const calls = stubAnthropicStream(messageEvents(["x"]));
    let pulled = 0;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulled += 1;
        controller.enqueue(new TextEncoder().encode('{"question":"hi"}'));
        controller.close();
      },
    });
    const res = await api.request(
      "https://app.example/ask/stream",
      { method: "POST", headers: { "content-type": "application/json", "content-length": String(MAX_ASK_BODY_BYTES + 1) }, body, duplex: "half" } as RequestInit,
      env as never,
    );
    assert.equal(res.status, 413);
    assert.ok(pulled <= 1, "the body is not drained");
    assert.equal(calls.length, 0);
  });

  it("stops reading a streamed body without Content-Length once it passes the limit", async () => {
    const chunk = new Uint8Array(64 * 1024).fill(0x20);
    let sent = 0;
    let cancelled = false;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        sent += chunk.byteLength;
        controller.enqueue(chunk);
      },
      cancel() {
        cancelled = true;
      },
    });
    const req = new Request("https://app.example/x", { method: "POST", body, duplex: "half" } as RequestInit);
    const got = await readJsonLimited(req, 256 * 1024);
    assert.deepEqual(got, { ok: false, tooLarge: true });
    assert.ok(cancelled, "the rest of the body is cancelled");
    assert.ok(sent <= 256 * 1024 + 2 * chunk.byteLength, `read ${sent} bytes`);
  });

  it("accepts a full-size legitimate question and parses it", async () => {
    const history = Array.from({ length: 12 }, (_, i) => ({ role: i % 2 ? "assistant" : "user", content: "é".repeat(8000) }));
    const text = JSON.stringify({ question: "q".repeat(2000), history });
    assert.ok(new TextEncoder().encode(text).byteLength < MAX_ASK_BODY_BYTES);
    const got = await readJsonLimited(new Request("https://app.example/x", { method: "POST", body: text }), MAX_ASK_BODY_BYTES);
    assert.equal(got.ok, true);
    assert.equal(((got as any).value.history as unknown[]).length, 12);
    const bad = await readJsonLimited(new Request("https://app.example/x", { method: "POST", body: "{not json" }), MAX_ASK_BODY_BYTES);
    assert.deepEqual(bad, { ok: true, value: null });
  });
});

describe("ask stream logging", () => {
  it("never logs raw provider stream data, answer text or the error object", async () => {
    const env = await envWithKey();
    const SECRET_TEXT = "PRIVATE-ANSWER-Sam-Okafor-readiness-44";
    const good = sseBody(messageEvents([`${SECRET_TEXT} `]).slice(0, 3));
    const broken = `event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"${SECRET_TEXT} more\n\n`;
    globalThis.fetch = (async () =>
      new Response(good + broken, { status: 200, headers: { "content-type": "text/event-stream" } })) as typeof fetch;

    const logged: unknown[][] = [];
    const methods = ["log", "info", "warn", "error", "debug", "trace"] as const;
    const saved = methods.map((m) => console[m]);
    const savedEnv = process.env.ANTHROPIC_LOG;
    process.env.ANTHROPIC_LOG = "debug"; // even with SDK debug logging asked for in the environment
    for (const m of methods) (console as any)[m] = (...args: unknown[]) => void logged.push(args);
    let events: Sse[];
    try {
      events = parseSse(await (await postStream({ question: "hi" }, env)).text());
    } finally {
      methods.forEach((m, i) => ((console as any)[m] = saved[i]));
      if (savedEnv === undefined) delete process.env.ANTHROPIC_LOG;
      else process.env.ANTHROPIC_LOG = savedEnv;
    }

    const all = logged.map((args) => args.map((a) => (typeof a === "string" ? a : inspect(a, { depth: 5 }))).join(" ")).join("\n");
    assert.ok(!all.includes(SECRET_TEXT), `logs leaked answer text:\n${all}`);
    assert.ok(!all.includes("sk-ant-"), "logs leaked the key");
    assert.ok(logged.length > 0, "the failure is still logged");
    for (const args of logged) {
      for (const a of args.slice(1)) {
        assert.ok(!(a instanceof Error), "no raw error object is logged");
      }
    }
    assert.match(all, /SyntaxError/, "the error name is logged");

    const last = events.at(-1)!;
    assert.equal(last.event, "error");
    assert.ok(!JSON.stringify(last.data).includes("Unexpected"), "the browser gets a plain sentence");
  });

  it("safeErrorMeta keeps only name and status", () => {
    const err = Object.assign(new Error("secret body text"), { status: 529, error: { body: "secret" } });
    assert.deepEqual(safeErrorMeta(err), { name: "Error", status: 529 });
    assert.deepEqual(safeErrorMeta(new SyntaxError("Unexpected token in secret")), { name: "SyntaxError" });
    assert.deepEqual(safeErrorMeta("boom"), { name: "string" });
  });
});

describe("ask stream interruption", () => {
  it("marks the answer interrupted, keeping partial text, when Anthropic closes before message_stop", async () => {
    const env = await envWithKey();
    // message_start, content_block_start, one text delta, then the connection closes.
    stubAnthropicStream(messageEvents(["Your Thursday pitches "]).slice(0, 3));
    const res = await postStream({ question: "hi", start: "2026-11-01", end: "2026-11-07" }, env);
    const events = parseSse(await res.text());
    const text = events.filter((e) => e.event === "text").map((e) => e.data.delta).join("");
    assert.equal(text, "Your Thursday pitches ");
    const last = events.at(-1)!;
    assert.equal(last.event, "done");
    assert.equal(last.data.interrupted, true);
    assert.equal(last.data.truncated, true);
    assert.equal(last.data.start, "2026-11-01");
    assert.ok(!events.some((e) => e.event === "step" && e.data.id === "write" && e.data.status === "done"), "the answer is not reported as written");
  });

  it("also flags a close after message_delta but before message_stop", async () => {
    const env = await envWithKey();
    stubAnthropicStream(messageEvents(["Done text"]).slice(0, -1));
    const events = parseSse(await (await postStream({ question: "hi" }, env)).text());
    assert.equal(events.at(-1)!.data.interrupted, true);
  });

  it("does not flag a complete answer", async () => {
    const env = await envWithKey();
    stubAnthropicStream(messageEvents(["All here."]));
    const events = parseSse(await (await postStream({ question: "hi" }, env)).text());
    assert.equal(events.at(-1)!.event, "done");
    assert.equal(events.at(-1)!.data.interrupted, undefined);
  });
});

describe("ask stream helpers", () => {
  it("counts each scored morning once", () => {
    assert.equal(
      countScoredNights([
        { day: "2026-11-05", morning: null, next: { s: 1 } },
        { day: "2026-11-06", morning: { s: 1 }, next: null },
        { day: "2026-11-07", morning: null, next: { s: 1 } },
      ]),
      2,
    );
  });

  it("writes short dates", () => {
    assert.equal(shortDate("2026-09-22"), "Sep 22");
  });
});
