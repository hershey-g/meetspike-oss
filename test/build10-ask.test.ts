/**
 * Build 10 acceptance tests, server side: Ask uses all your history.
 * Spec sections A (which dates are ranked), B (baselines and heavy-day comparison over all
 * history, per wearable), C (what comes back, the `range` SSE event) and the body flags
 * `allTime` / `ignorePeriod` from E.
 *
 * Names the builder must match:
 *   src/lib/history-range.ts   questionPeriod(question, today): {start,end} | "all" | null
 *                              questionRange(question, today) is unchanged
 *   POST /api/ask and /api/ask/stream bodies: allTime (true only), ignorePeriod (true only)
 *   POST /api/ask response and the stream's `done`: baselineStart, baselineEnd, rangeSource
 *   stream event `range`: {start, end, baselineStart, baselineEnd, rangeSource}, once, first
 *
 * The data block is checked through the route (what Claude is sent), not through
 * buildAskContext, because its argument list is the builder's to design.
 *
 * The world: today is 2026-11-25 (clock mocked). WHOOP scores start 2026-03-02 and run to today,
 * Oura scores run 2026-04-01 to 2026-11-20, the first meeting is 2026-06-01. Scores before the
 * first meeting are 100 on purpose, so counting those days as "light" changes the numbers.
 */
import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it, mock } from "node:test";
import { api } from "../src/routes/api.ts";
import { shortDate } from "../src/routes/ask.ts";
import { saveAiKey } from "../src/lib/ai-key.ts";
import { addCalendarDays } from "../src/lib/time.ts";
import * as historyRange from "../src/lib/history-range.ts";
import { ASK_SYSTEM_PROMPT } from "../src/lib/ask-context.ts";
import { buildDayRows, buildUsual, heavyEffect } from "../src/lib/usual.ts";
import { putCachedHr } from "../src/sources/whoop-web/store.ts";
import type { OuraDaySlice } from "../src/sources/calendar/join.ts";
import type { CalendarEventRow } from "../src/types.ts";
import type { Env } from "../src/env.ts";
import { fakeKv, sqliteD1 } from "./sqlite-d1.ts";

const SECRET = "s".repeat(40);
const KEY = "sk-ant-api03-test-test-test-test-test-test-0000";
const NOW = "2026-11-25T17:00:00.000Z";
const TODAY = "2026-11-25";
const BOTH = { oura: true, whoop: true };

beforeEach(() => {
  mock.timers.enable({ apis: ["Date"], now: new Date(NOW) });
});
afterEach(() => {
  mock.timers.reset();
  globalThis.fetch = realFetch;
});
const realFetch = globalThis.fetch;

/* ---------- the world ---------- */

type Raw = ReturnType<typeof sqliteD1>["raw"];
type Ev = { id: string; day: string; hours: number; title: string; transcript?: boolean };

const HEAVY_TITLES: Record<string, string> = {
  "2026-06-02": "Offsite Jun 2",
  "2026-07-07": "Offsite Jul 7",
  "2026-10-13": "Offsite Oct 13",
  "2026-11-10": "Offsite Nov 10",
};
const HEAVY_NEXT = new Set(Object.keys(HEAVY_TITLES).map((d) => addCalendarDays(d, 1)));
const FIRST_MEETING = "2026-06-01";

function days(from: string, to: string): string[] {
  const out: string[] = [];
  for (let d = from; d <= to; d = addCalendarDays(d, 1)) out.push(d);
  return out;
}
function isWeekday(day: string): boolean {
  const wd = new Date(`${day}T12:00:00.000Z`).getUTCDay();
  return wd >= 1 && wd <= 5;
}

function addEvent(raw: Raw, e: Ev) {
  const start = `${e.day}T15:00:00.000Z`;
  const end = new Date(Date.parse(start) + e.hours * 3_600_000).toISOString();
  const people = [{ email: "me@owner.example", self: true }, { email: "pat.reyes@client.example", displayName: "Pat Reyes" }];
  raw.prepare(`INSERT INTO calendar_event
    (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, title, kind, attendee_count, after_hours,
     updated_at, attendees_json, source_type, has_transcript)
    VALUES (?, 'google', ?, ?, ?, -300, ?, ?, 'client', 2, 0, 't', ?, 'calendar', ?)`)
    .run(e.id, e.day, start, end, e.hours * 3600, e.title, JSON.stringify(people), e.transcript ? 1 : 0);
}

function addScores(raw: Raw, source: "whoop" | "oura", from: string, to: string, ready: (d: string) => number, sleep: (d: string) => number, hrv: number, rhr: number) {
  for (const d of days(from, to)) {
    raw.prepare(`INSERT INTO daily_readiness (day, source, source_day, score, updated_at) VALUES (?, ?, ?, ?, 't')`).run(d, source, d, ready(d));
    raw.prepare(`INSERT INTO daily_sleep (day, source, source_day, score, avg_hrv, lowest_hr, updated_at) VALUES (?, ?, ?, ?, ?, ?, 't')`)
      .run(d, source, d, sleep(d), hrv, rhr);
  }
}

/** Events: 1 hour on every weekday from the first meeting to yesterday, 5 hours on four heavy days and today. */
function bigEvents(): Ev[] {
  const out: Ev[] = [];
  for (const d of days(FIRST_MEETING, addCalendarDays(TODAY, -1))) {
    if (!isWeekday(d)) continue;
    out.push(HEAVY_TITLES[d]
      ? { id: `e-${d}`, day: d, hours: 5, title: HEAVY_TITLES[d], transcript: d === "2026-11-10" }
      : { id: `e-${d}`, day: d, hours: 1, title: "Team sync" });
  }
  out.push({ id: `e-${TODAY}`, day: TODAY, hours: 5, title: "Offsite today" });
  return out;
}

async function bigWorld() {
  const { db, raw } = sqliteD1();
  const events = bigEvents();
  for (const e of events) addEvent(raw, e);
  const pre = (d: string) => d < FIRST_MEETING;
  addScores(raw, "whoop", "2026-03-02", TODAY,
    (d) => (HEAVY_NEXT.has(d) ? 41 : pre(d) ? 100 : 82), (d) => (pre(d) ? 95 : 77), 61, 49);
  // A score dated tomorrow (clock skew) must never reach the baseline or count as a finished day.
  raw.prepare(`INSERT INTO daily_readiness (day, source, source_day, score, updated_at) VALUES ('2026-11-26', 'whoop', '2026-11-26', 20, 't')`).run();
  addScores(raw, "oura", "2026-04-01", "2026-11-20",
    (d) => (HEAVY_NEXT.has(d) ? 53 : pre(d) ? 100 : 67), (d) => (pre(d) ? 95 : 70), 45, 48);
  raw.prepare(`INSERT INTO daily_strain (day, source, source_day, strain, avg_hr, max_hr, updated_at) VALUES ('2026-11-10', 'whoop', '2026-11-10', 11.7, 137, 187, 't')`).run();
  await putCachedHr(db, {
    eventId: "e-2026-11-10",
    windowStartUtc: "2026-11-10T14:50:00.000Z",
    windowEndUtc: "2026-11-10T20:10:00.000Z",
    status: "ok",
    points: [[Date.parse("2026-11-10T15:30:00.000Z"), 191]],
    errorText: null,
    fetchedAt: "2026-11-11T00:00:00.000Z",
  });
  return { db, raw, events };
}

/** Meetings only on `hours` days, WHOOP scores from 2026-10-01. For the weekday-hours cases. */
function tinyWorld(hours: Record<string, number>) {
  const { db, raw } = sqliteD1();
  for (const [day, h] of Object.entries(hours)) addEvent(raw, { id: `t-${day}`, day, hours: h, title: "Review" });
  addScores(raw, "whoop", "2026-10-01", TODAY, () => 82, () => 77, 61, 49);
  return db;
}

async function makeEnv(db: D1Database, opts: { oura?: boolean; whoop?: boolean } = {}): Promise<Env> {
  const env = {
    WEARABLE: "whoop",
    AI_KEY_SECRET: SECRET,
    TOKENS: fakeKv({
      "settings:source_display:whoop": String(opts.whoop ?? true),
      "settings:source_display:oura": String(opts.oura ?? true),
    }),
    DB: db,
  } as unknown as Env;
  await saveAiKey(env, KEY);
  return env;
}

/* ---------- Anthropic stubs and requests ---------- */

const MESSAGE = {
  id: "msg_1", type: "message", role: "assistant", model: "claude-opus-5-5",
  content: [{ type: "text", text: "Nov 10 cost you the most." }],
  stop_reason: "end_turn", stop_sequence: null, usage: { input_tokens: 10, output_tokens: 10 },
};

function stubJson() {
  const calls: Array<{ body: any }> = [];
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init);
    calls.push({ body: await req.json().catch(() => null) });
    return new Response(JSON.stringify(MESSAGE), { status: 200, headers: { "content-type": "application/json" } });
  }) as typeof fetch;
  return calls;
}

type AnthropicEvent = Record<string, unknown>;
function messageEvents(texts: string[], stopReason = "end_turn"): AnthropicEvent[] {
  return [
    { type: "message_start", message: { id: "msg_1", type: "message", role: "assistant", model: "claude-opus-5-5", content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 0 } } },
    ...(texts.length ? [{ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }] : []),
    ...texts.map((t) => ({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: t } })),
    ...(texts.length ? [{ type: "content_block_stop", index: 0 }] : []),
    { type: "message_delta", delta: { stop_reason: stopReason, stop_sequence: null }, usage: { output_tokens: 5 } },
    { type: "message_stop" },
  ];
}
function stubStream(events: AnthropicEvent[]) {
  const calls: Array<{ body: any }> = [];
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init);
    calls.push({ body: await req.json().catch(() => null) });
    const text = events.map((e) => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join("");
    return new Response(text, { status: 200, headers: { "content-type": "text/event-stream" } });
  }) as typeof fetch;
  return calls;
}

type Sse = { event: string; data: any };
function parseSse(text: string): Sse[] {
  return text.split("\n\n").map((b) => b.trim()).filter((b) => b && !b.startsWith(":")).map((b) => ({
    event: /^event: (.*)$/m.exec(b)?.[1] ?? "message",
    data: JSON.parse(b.split("\n").filter((l) => l.startsWith("data: ")).map((l) => l.slice(6)).join("\n")),
  }));
}

async function post(env: Env, body: Record<string, unknown>) {
  const res = await api.request("https://app.example/ask", {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ sourceDisplay: BOTH, ...body }),
  }, env as never);
  return { status: res.status, body: (await res.json()) as Record<string, any> };
}
async function stream(env: Env, body: Record<string, unknown>) {
  const res = await api.request("https://app.example/ask/stream", {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ sourceDisplay: BOTH, ...body }),
  }, env as never);
  return { status: res.status, events: res.status === 200 ? parseSse(await res.text()) : [], res };
}
/** The data block Claude was sent for this question. */
async function context(env: Env, body: Record<string, unknown>): Promise<{ text: string; res: Awaited<ReturnType<typeof post>> }> {
  const calls = stubJson();
  const res = await post(env, body);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  return { text: calls[0].body.system[1].text as string, res };
}

const Q = "Which meetings cost me the most?";
const BASELINE = { baselineStart: "2026-03-02", baselineEnd: TODAY };
const MONTH = { start: "2026-11-01", end: TODAY };

/* ---------- helpers on the data block ---------- */

const lines = (text: string) => text.split("\n");
const dayLines = (text: string) => [...text.matchAll(/^(\d{4}-\d{2}-\d{2}) (?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) \|/gm)].map((m) => m[1]);
/** Numbers in a line, leaving out dates and the "(4+ hours or 5+ meetings)" note. */
function numbers(line: string): number[] {
  return (line.replace(/\([^)]*\)/g, " ").replace(/\d{4}-\d{2}-\d{2}/g, " ").match(/\d+(?:\.\d+)?/g) ?? []).map(Number);
}
function subsequence(have: number[], want: number[]): boolean {
  let i = 0;
  for (const n of have) if (n === want[i]) i += 1;
  return i === want.length;
}
const usualLines = (text: string) => lines(text).filter((l) => /\busual\b/i.test(l));
const heavyLines = (text: string) => lines(text).filter((l) => /heavy days/i.test(l));

/* ================= A. which dates are ranked ================= */

describe("questionPeriod", () => {
  const period = (q: string) => {
    assert.equal(typeof (historyRange as any).questionPeriod, "function", "history-range.ts exports questionPeriod");
    return (historyRange as any).questionPeriod(q, TODAY);
  };

  it("returns the same range as questionRange for a period in the question", () => {
    for (const q of ["How was this month?", "What about this year?", "And the last 3 weeks?", "What happened in the past two months?"]) {
      assert.deepEqual(period(q), historyRange.questionRange(q, TODAY), q);
    }
    assert.deepEqual(period("How was this month?"), { start: "2026-11-01", end: TODAY });
    assert.deepEqual(period("What about this year?"), { start: "2026-01-01", end: TODAY });
  });

  it("returns \"all\" for all-history wording, in any case", () => {
    for (const q of [
      "What is my worst day of all time?", "Which meetings cost me the most, all time?", "ALL TIME please",
      "Have I ever had a worse week?", "Worst day ever?", "Ever had a day like that?",
      "Show me a day of all time", "Look at all my history", "Compare with all history", "Since the beginning, which person costs me most?",
    ]) {
      assert.equal(period(q), "all", q);
    }
  });

  it("does not count every, never, however, forever, whatever or ever since", () => {
    for (const q of [
      "Every day is full, why?",
      "I never sleep well after calls",
      "However, which meetings cost me the most?",
      "Forever busy, who is in the calls?",
      "Whatever the cause, which day was worst?",
      "How have I slept ever since March?",
      "Everything about Tuesdays",
    ]) {
      assert.equal(period(q), null, q);
    }
  });

  it("lets all time win when a period and all time are both in the question", () => {
    assert.equal(period("Compare this month with all time"), "all");
    assert.equal(period("Is the last 3 weeks the worst of all time?"), "all");
  });

  it("is null with no period at all", () => {
    assert.equal(period(Q), null);
    assert.equal(period(""), null);
  });

  it("leaves questionRange as it was: a period or null, never \"all\"", () => {
    assert.equal(historyRange.questionRange("What is my worst day of all time?", TODAY), null);
    assert.equal(historyRange.questionRange("Worst day ever?", TODAY), null);
    assert.deepEqual(historyRange.questionRange("this month and all time", TODAY), { start: "2026-11-01", end: TODAY });
    assert.equal(historyRange.questionRange(Q, TODAY), null);
  });
});

describe("Ask ranked dates: precedence", () => {
  const history = (...turns: Array<["user" | "assistant", string]>) => turns.map(([role, content]) => ({ role, content }));
  const TAB = { start: "2026-10-01", end: "2026-10-14" };

  it("step 1: a period in the question beats allTime, an earlier turn and the tab", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubJson();
    const r = await post(env, {
      question: "How was this month?", allTime: true, ...TAB,
      history: history(["user", "And the last 2 weeks?"], ["assistant", "Fine."]),
    });
    assert.equal(r.status, 200);
    assert.deepEqual({ start: r.body.start, end: r.body.end, rangeSource: r.body.rangeSource }, { ...MONTH, rangeSource: "question" });
    assert.equal(r.body.baselineStart, BASELINE.baselineStart);
    assert.equal(r.body.baselineEnd, BASELINE.baselineEnd);
  });

  it("step 1: all-history wording in the question ranks all history, and wins over a period in the same question", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubJson();
    for (const question of ["Compare this month with all time", "Worst day ever?", "Was it ever this bad?"]) {
      const r = await post(env, { question, ...TAB });
      assert.equal(r.status, 200, question);
      assert.deepEqual(
        { start: r.body.start, end: r.body.end, rangeSource: r.body.rangeSource },
        { start: BASELINE.baselineStart, end: TODAY, rangeSource: "question" },
        question,
      );
    }
  });

  it("step 1: every, never and however are not all-history wording, so the tab still applies", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubJson();
    for (const question of ["Every meeting felt long", "I never sleep well after calls", "However, which day was worst?", "How have I slept ever since March?"]) {
      const r = await post(env, { question, ...TAB });
      assert.equal(r.body.rangeSource, "tab", question);
      assert.equal(r.body.start, TAB.start, question);
    }
  });

  it("step 2: allTime true ranks all history, beating an earlier turn and the tab, even a bad tab", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubJson();
    const r = await post(env, {
      question: Q, allTime: true, ...TAB, history: history(["user", "How was this month?"], ["assistant", "Fine."]),
    });
    assert.equal(r.status, 200);
    assert.deepEqual(
      { start: r.body.start, end: r.body.end, rangeSource: r.body.rangeSource },
      { start: BASELINE.baselineStart, end: TODAY, rangeSource: "allTime" },
    );
    const bad = await post(env, { question: Q, allTime: true, start: "garbage", end: "2026-10-14" });
    assert.equal(bad.status, 200, "a bad tab range is ignored when step 2 applies");
    assert.equal(bad.body.rangeSource, "allTime");
  });

  it("step 2: only boolean true counts as allTime", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubJson();
    for (const allTime of ["true", 1, "yes", null, false, {}]) {
      const r = await post(env, { question: Q, allTime, ...TAB });
      assert.equal(r.body.rangeSource, "tab", JSON.stringify(allTime));
    }
  });

  it("step 3: the newest earlier user turn with a period sets the range", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubJson();
    const r = await post(env, {
      question: "And which day was the worst?",
      ...TAB,
      history: history(
        ["user", "How was this year?"], ["assistant", "Busy."],
        ["user", "What about the last 2 weeks?"], ["assistant", "Calmer."],
        ["user", "Who was in the calls?"], ["assistant", "Pat."],
      ),
    });
    assert.equal(r.status, 200);
    const expected = historyRange.questionRange("the last 2 weeks", TODAY)!;
    assert.deepEqual({ start: r.body.start, end: r.body.end, rangeSource: r.body.rangeSource }, { ...expected, rangeSource: "followUp" });
  });

  it("step 3: a bad tab range is ignored when an earlier turn applies", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubJson();
    const r = await post(env, {
      question: "And the worst day?", start: "nonsense", end: "2026-10-14",
      history: history(["user", "How was this month?"], ["assistant", "Busy."]),
    });
    assert.equal(r.status, 200);
    assert.equal(r.body.rangeSource, "followUp");
    assert.equal(r.body.start, "2026-11-01");
  });

  it("step 3 does not apply when the history was dropped for a changed source setting", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubJson();
    const r = await post(env, {
      question: Q, ...TAB, sourceDisplay: { oura: false, whoop: true },
      history: history(["user", "How was this month?"], ["assistant", "Busy."]),
    });
    assert.equal(r.status, 200);
    assert.equal(r.body.rangeSource, "tab");
    assert.equal(r.body.start, TAB.start);
  });

  it("step 4: the tab range applies with no other period, and a bad one is still a 400", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubJson();
    const ok = await post(env, { question: Q, ...TAB });
    assert.deepEqual({ start: ok.body.start, end: ok.body.end, rangeSource: ok.body.rangeSource }, { ...TAB, rangeSource: "tab" });

    for (const bad of [{ start: "2026-10-14", end: "2026-10-01" }, { start: "garbage", end: "2026-10-14" }, { start: "2026-10-01", end: "2026-13-45" }]) {
      const r = await post(env, { question: Q, ...bad });
      assert.equal(r.status, 400, JSON.stringify(bad));
      assert.ok(r.body.error);
      const s = await stream(env, { question: Q, ...bad });
      assert.equal(s.status, 400, `stream ${JSON.stringify(bad)}`);
    }
  });

  it("step 5: nothing else ranks all history, from the first stored day to today", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubJson();
    const r = await post(env, { question: Q });
    assert.deepEqual(
      { start: r.body.start, end: r.body.end, rangeSource: r.body.rangeSource, ...BASELINE },
      { start: BASELINE.baselineStart, end: TODAY, rangeSource: "history", ...BASELINE },
    );
  });

  it("an older phone's body (no allTime, no ignorePeriod) still works", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubJson();
    const r = await post(env, { question: Q, ...TAB, history: [] });
    assert.equal(r.status, 200);
    assert.equal(r.body.rangeSource, "tab");
  });

  it("ignorePeriod true skips steps 1 and 3 but not step 2", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubJson();
    // Step 1 skipped: "this month" in the question does not win; allTime does.
    const a = await post(env, { question: "How was this month?", allTime: true, ignorePeriod: true, ...TAB });
    assert.deepEqual(
      { start: a.body.start, end: a.body.end, rangeSource: a.body.rangeSource },
      { start: BASELINE.baselineStart, end: TODAY, rangeSource: "allTime" },
    );
    // Step 1 skipped, no allTime: the tab applies.
    const b = await post(env, { question: "How was this month?", ignorePeriod: true, ...TAB });
    assert.deepEqual({ start: b.body.start, end: b.body.end, rangeSource: b.body.rangeSource }, { ...TAB, rangeSource: "tab" });
    // Step 1 skipped, nothing else: all history.
    const c = await post(env, { question: "How was this month?", ignorePeriod: true });
    assert.deepEqual(
      { start: c.body.start, end: c.body.end, rangeSource: c.body.rangeSource },
      { start: BASELINE.baselineStart, end: TODAY, rangeSource: "history" },
    );
    // All-history wording in the question is part of step 1, so it is skipped too.
    const d = await post(env, { question: "What about all time?", ignorePeriod: true, ...TAB });
    assert.equal(d.body.rangeSource, "tab");
    // Step 3 skipped.
    const e = await post(env, {
      question: Q, ignorePeriod: true, ...TAB, history: history(["user", "How was this month?"], ["assistant", "Busy."]),
    });
    assert.equal(e.body.rangeSource, "tab");
    assert.equal(e.body.start, TAB.start);
  });

  it("ignorePeriod true with the tab applying still 400s on a bad tab; other values do not skip", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubJson();
    const bad = await post(env, { question: "How was this month?", ignorePeriod: true, start: "2026-10-14", end: "2026-10-01" });
    assert.equal(bad.status, 400);
    for (const ignorePeriod of ["true", 1, "yes", false, null]) {
      const r = await post(env, { question: "How was this month?", ignorePeriod, ...TAB });
      assert.equal(r.body.rangeSource, "question", JSON.stringify(ignorePeriod));
    }
  });

  it("the stream uses the same precedence", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubStream(messageEvents(["ok"]));
    const s = await stream(env, { question: Q, allTime: true, start: "2026-10-01", end: "2026-10-14" });
    assert.equal(s.status, 200);
    const range = s.events.find((e) => e.event === "range")!;
    assert.equal(range.data.rangeSource, "allTime");
    assert.equal(range.data.start, BASELINE.baselineStart);
  });
});

/* ================= C. what comes back ================= */

describe("Ask: what comes back", () => {
  it("POST /api/ask returns baselineStart, baselineEnd and rangeSource beside start and end", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubJson();
    const r = await post(env, { question: "How was this month?" });
    assert.equal(r.status, 200);
    assert.equal(r.body.ok, true);
    assert.equal(typeof r.body.answer, "string");
    assert.equal(r.body.truncated, false);
    assert.equal(r.body.model, "claude-opus-5-5");
    assert.deepEqual(
      { start: r.body.start, end: r.body.end, baselineStart: r.body.baselineStart, baselineEnd: r.body.baselineEnd, rangeSource: r.body.rangeSource },
      { ...MONTH, ...BASELINE, rangeSource: "question" },
    );
  });

  it("the baseline is history start to today whatever is ranked, over the displayed sources", async () => {
    const { db } = await bigWorld();
    stubJson();
    // WHOOP only: WHOOP's first score is 2026-03-02.
    let r = await post(await makeEnv(db, { oura: false }), { question: "How was this month?", sourceDisplay: { oura: false, whoop: true } });
    assert.equal(r.body.baselineStart, "2026-03-02");
    // Oura only (WHOOP is the configured wearable but not displayed): Oura's first score is 2026-04-01.
    r = await post(await makeEnv(db, { whoop: false }), { question: "How was this month?", sourceDisplay: { oura: true, whoop: false } });
    assert.equal(r.body.baselineStart, "2026-04-01");
    assert.equal(r.body.baselineEnd, TODAY);
    // Neither: the first meeting's day.
    r = await post(await makeEnv(db, { oura: false, whoop: false }), { question: Q, sourceDisplay: { oura: false, whoop: false } });
    assert.equal(r.body.baselineStart, FIRST_MEETING);
  });

  it("sends a range event once, before the first step, with all five fields", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubStream(messageEvents(["Nov 10 ", "cost you the most."]));
    const { status, events } = await stream(env, { question: "How was this month?" });
    assert.equal(status, 200);
    const names = events.map((e) => e.event);
    assert.equal(names.filter((n) => n === "range").length, 1);
    assert.equal(names[0], "range", `events: ${names.join(",")}`);
    assert.ok(names.indexOf("range") < names.indexOf("step"));
    assert.deepEqual(events[0].data, { ...MONTH, ...BASELINE, rangeSource: "question" });
    // The rest of the stream is unchanged.
    assert.equal(names.at(-1), "done");
    assert.deepEqual(events.filter((e) => e.event === "text").map((e) => e.data.delta), ["Nov 10 ", "cost you the most."]);
  });

  it("done carries baselineStart, baselineEnd and rangeSource beside the existing fields", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    stubStream(messageEvents(["Part"], "max_tokens"));
    const truncated = (await stream(env, { question: Q, start: "2026-10-01", end: "2026-10-14" })).events.at(-1)!;
    assert.equal(truncated.event, "done");
    assert.deepEqual(truncated.data, {
      truncated: true, model: "claude-opus-5-5", start: "2026-10-01", end: "2026-10-14", ...BASELINE, rangeSource: "tab",
    });

    stubStream(messageEvents([], "refusal"));
    const refused = (await stream(env, { question: Q, allTime: true })).events.at(-1)!;
    assert.equal(refused.data.refused, true);
    assert.equal(refused.data.rangeSource, "allTime");
    assert.equal(refused.data.baselineStart, BASELINE.baselineStart);
    assert.equal(refused.data.baselineEnd, BASELINE.baselineEnd);

    stubStream(messageEvents(["Cut"]).slice(0, 3));
    const cut = (await stream(env, { question: Q })).events.at(-1)!;
    assert.equal(cut.data.interrupted, true);
    assert.equal(cut.data.rangeSource, "history");
    assert.equal(cut.data.baselineStart, BASELINE.baselineStart);
  });

  it("a request that fails before streaming has no range event", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    const s = await stream(env, { question: Q, start: "2026-10-14", end: "2026-10-01" });
    assert.equal(s.status, 400);
    assert.match(s.res.headers.get("content-type") ?? "", /application\/json/);
  });

  it("the calendar step counts only meetings in the ranked dates", async () => {
    const { db, events } = await bigWorld();
    const env = await makeEnv(db);
    stubStream(messageEvents(["ok"]));
    const inMonth = events.filter((e) => e.day >= MONTH.start && e.day <= MONTH.end).length;
    assert.ok(inMonth > 0 && inMonth < events.length);
    const month = (await stream(env, { question: "How was this month?" })).events
      .filter((e) => e.event === "step" && e.data.id === "calendar" && e.data.status === "done");
    assert.equal(month[0].data.label, `Read ${inMonth} meetings from Nov 1 to Nov 25`);

    const all = (await stream(env, { question: "Worst day of all time?" })).events
      .filter((e) => e.event === "step" && e.data.id === "calendar" && e.data.status === "done");
    assert.equal(all[0].data.label, `Read ${events.length} meetings from ${shortDate("2026-03-02")} to Nov 25`);
  });
});

/* ================= B. baselines and the heavy-day comparison ================= */

describe("Ask data block: baselines over all history, per wearable", () => {
  it("says the usual and heavy-day numbers are over all history, and what is ranked", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    const { text } = await context(env, { question: "How was this month?" });
    assert.ok(text.includes("Usual (median over all history, 2026-03-02 to 2026-11-25)"), text.slice(0, 800));
    assert.match(text, /Heavy days \(4\+ hours or 5\+ meetings\) over all history, \d{4}-\d{2}-\d{2} to \d{4}-\d{2}-\d{2}/);
    assert.ok(
      text.includes("Ranking 2026-11-01 to 2026-11-25. Compare against the all-history numbers above."),
      "the ranking line is there when the ranked dates are smaller than all history",
    );
  });

  it("has no ranking line when the ranked dates already are all history", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    const { text } = await context(env, { question: "Worst day of all time?" });
    assert.ok(text.includes("Usual (median over all history, 2026-03-02 to 2026-11-25)"));
    assert.doesNotMatch(text, /^Ranking /m);
    assert.doesNotMatch(text, /Compare against the all-history numbers/);
  });

  it("each wearable has its own usual line, with its own first and last scored day", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    const { text } = await context(env, { question: "How was this month?" });
    const usual = usualLines(text);
    assert.equal(usual.length, 2, usual.join("\n"));
    const oura = usual.find((l) => /Oura/.test(l))!;
    const whoop = usual.find((l) => !/Oura/.test(l))!;
    assert.ok(oura && whoop, usual.join("\n"));

    assert.ok(whoop.includes("2026-03-02 to 2026-11-25"), whoop);
    assert.ok(oura.includes("2026-04-01") && oura.includes("2026-11-20"), oura);
    // WHOOP: recovery 82, sleep 77, HRV 61, RHR 49. Oura: readiness 67, sleep 70, HRV 45, RHR 48.
    for (const n of [82, 77, 61, 49]) assert.ok(numbers(whoop).includes(n), `WHOOP ${n}: ${whoop}`);
    for (const n of [67, 70, 45, 48]) assert.ok(numbers(oura).includes(n), `Oura ${n}: ${oura}`);
    for (const n of [67, 70, 45, 48, 100, 95]) assert.ok(!numbers(whoop).includes(n), `WHOOP line has ${n}: ${whoop}`);
    for (const n of [82, 77, 61, 49, 100, 95]) assert.ok(!numbers(oura).includes(n), `Oura line has ${n}: ${oura}`);
  });

  it("each wearable has its own heavy-day comparison over all history, never mixed", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    const { text } = await context(env, { question: "How was this month?" });
    const heavy = heavyLines(text);
    assert.equal(heavy.length, 2, heavy.join("\n"));
    const oura = heavy.find((l) => /Oura/.test(l))!;
    const whoop = heavy.find((l) => !/Oura/.test(l))!;
    assert.ok(oura && whoop, heavy.join("\n"));
    assert.match(whoop, /all history/);
    assert.match(oura, /all history/);
    // WHOOP: 4 heavy days, next-morning 41, then 173 other days at 82.
    assert.ok(subsequence(numbers(whoop), [4, 41, 173, 82]), `WHOOP: ${whoop}`);
    // Oura stops syncing on Nov 20, so it has 4 heavy days at 53 and 168 other days at 67.
    assert.ok(subsequence(numbers(oura), [4, 53, 168, 67]), `Oura: ${oura}`);
    for (const n of [53, 67, 168]) assert.ok(!numbers(whoop).includes(n), `WHOOP heavy line has ${n}: ${whoop}`);
    for (const n of [41, 82, 173]) assert.ok(!numbers(oura).includes(n), `Oura heavy line has ${n}: ${oura}`);
  });

  it("the baselines are the same whatever dates are ranked", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    const baseline = (text: string) => [...usualLines(text), ...heavyLines(text)].map((l) => l.replace(/\s+/g, " ")).join("\n");
    const all = await context(env, { question: "Worst day of all time?" });
    assert.equal([...usualLines(all.text), ...heavyLines(all.text)].length, 4);
    for (const body of [
      { question: "How was this month?" },
      { question: Q, start: "2026-10-01", end: "2026-10-14" },
      { question: "And the last 2 weeks?" },
      { question: Q, start: "2026-06-01", end: "2026-06-30" },
    ]) {
      const got = await context(env, body);
      assert.equal(baseline(got.text), baseline(all.text), JSON.stringify(body));
    }
  });

  it("sends day and meeting detail only for the ranked dates", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    const { text } = await context(env, { question: "How was this month?" });
    const shown = dayLines(text);
    assert.ok(shown.length > 15, `day lines: ${shown.length}`);
    assert.ok(shown.every((d) => d >= "2026-11-01" && d <= TODAY), shown.join(" "));
    assert.match(text, /Offsite Nov 10/);
    assert.match(text, /Offsite today/);
    assert.doesNotMatch(text, /Offsite Jun 2|Offsite Jul 7|Offsite Oct 13/);
    assert.doesNotMatch(text, /Monthly totals/, "a small ranked range needs no monthly roll-up");

    const tab = await context(env, { question: Q, start: "2026-10-12", end: "2026-10-14" });
    assert.deepEqual(dayLines(tab.text), ["2026-10-12", "2026-10-13", "2026-10-14"]);
    assert.match(tab.text, /Offsite Oct 13/);
    assert.doesNotMatch(tab.text, /Offsite Nov 10/);
  });

  it("covers every day when all history is ranked", async () => {
    const { db, events } = await bigWorld();
    const env = await makeEnv(db);
    const { text } = await context(env, { question: "Worst day of all time?" });
    const shown = dayLines(text);
    assert.equal(shown[0], "2026-03-02");
    assert.ok(shown.includes("2026-06-02") && shown.includes(TODAY));
    for (const title of Object.values(HEAVY_TITLES)) assert.ok(text.includes(title), title);
    assert.ok(events.length > 100);
  });

  it("does not count days before the first meeting, today, or a future score as finished days", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    const { text } = await context(env, { question: "How was this month?" });
    const whoop = heavyLines(text).find((l) => !/Oura/.test(l))!;
    // Pre-meeting days score 100 and today (a 5 hour meeting) has a tomorrow score of 20: either would move these.
    assert.ok(subsequence(numbers(whoop), [4, 41, 173, 82]), whoop);
    // The future score is not in the baseline either: the last scored day is today.
    assert.ok(text.includes("2026-03-02 to 2026-11-25)"));
  });

  it("weekday meeting hours skip the days before the first meeting", async () => {
    const hours: Record<string, number> = {};
    for (const d of ["2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19", "2026-11-20", "2026-11-23", "2026-11-24"]) hours[d] = 2;
    const env = await makeEnv(tinyWorld(hours), { oura: false });
    const { text } = await context(env, { question: "How was this month?", sourceDisplay: { oura: false, whoop: true } });
    // Weekdays from Oct 1 to Nov 13 have no meetings only because the calendar was not connected.
    assert.match(text, /Usual \(median over all history[^\n]*weekday meeting hours 2\.0/);
  });

  it("weekday meeting hours leave out today, and count quiet days after the first meeting", async () => {
    const hours: Record<string, number> = { "2026-11-16": 4, "2026-11-18": 4, "2026-11-23": 4, [TODAY]: 9 };
    const env = await makeEnv(tinyWorld(hours), { oura: false });
    const { text } = await context(env, { question: "How was this month?", sourceDisplay: { oura: false, whoop: true } });
    // Finished weekdays from Nov 16: 4, 0, 4, 0, 0, 4, 0 hours. The median is 0.0. Counting today's 9 hours would make it 2.0.
    assert.match(text, /Usual \(median over all history[^\n]*weekday meeting hours 0\.0/);
  });

  it("with only one wearable shown there is one usual line, one heavy line and no mention of the other", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db, { oura: false });
    const { text } = await context(env, { question: "How was this month?", sourceDisplay: { oura: false, whoop: true } });
    assert.equal(usualLines(text).length, 1);
    assert.equal(heavyLines(text).length, 1);
    assert.doesNotMatch(text, /Oura/);
    for (const n of [67, 70, 53]) assert.ok(!numbers([...usualLines(text), ...heavyLines(text)].join(" ")).includes(n));

    const oura = await makeEnv(db, { whoop: false });
    const o = await context(oura, { question: "How was this month?", sourceDisplay: { oura: true, whoop: false } });
    assert.ok(o.text.includes("Usual (median over all history, 2026-04-01 to 2026-11-20)"), o.text.slice(0, 600));
    assert.doesNotMatch(o.text, /WHOOP/);
    assert.ok(subsequence(numbers(heavyLines(o.text)[0]), [4, 53, 168, 67]), heavyLines(o.text)[0]);
  });

  it("with both wearables off there are no baselines, and no wearable is named", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db, { oura: false, whoop: false });
    const { text } = await context(env, { question: "How was this month?", sourceDisplay: { oura: false, whoop: false } });
    assert.match(text, /Wearable display is off/);
    assert.doesNotMatch(text, /Usual|Heavy days|WHOOP|Oura|woke/);
    assert.match(text, /Offsite Nov 10/);
  });

  it("an empty database still answers, with no NaN in the data", async () => {
    const { db } = sqliteD1();
    const env = await makeEnv(db);
    const { text, res } = await context(env, { question: Q });
    assert.equal(res.body.baselineStart, TODAY);
    assert.equal(res.body.baselineEnd, TODAY);
    assert.equal(res.body.rangeSource, "history");
    assert.doesNotMatch(text, /NaN|undefined|null/);
  });

  it("a ranked range that starts before the stored history still loads from there", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    const { text, res } = await context(env, { question: Q, start: "2026-01-01", end: TODAY });
    assert.equal(res.body.start, "2026-01-01");
    assert.equal(res.body.baselineStart, "2026-03-02", "the baseline stays history start to today");
    assert.ok(text.includes("Usual (median over all history, 2026-03-02 to 2026-11-25)"));
  });

  it("the system prompt tells Claude to rank only the ranked dates, compare with all-history baselines, and keep tables narrow", () => {
    assert.match(ASK_SYSTEM_PROMPT, /ranked/i);
    assert.match(ASK_SYSTEM_PROMPT, /all[- ]history/i);
    assert.match(ASK_SYSTEM_PROMPT, /baseline/i);
    assert.match(ASK_SYSTEM_PROMPT, /(at most|no more than|up to) (3|three) columns/i);
    assert.match(ASK_SYSTEM_PROMPT, /short/i);
    // The other rules stay.
    assert.match(ASK_SYSTEM_PROMPT, /Do not give medical advice/);
    assert.match(ASK_SYSTEM_PROMPT, /No em dashes/);
    assert.match(ASK_SYSTEM_PROMPT, /Under 150 words/);
    assert.ok(!ASK_SYSTEM_PROMPT.includes("—"), "no em dash in the prompt");
  });
});

describe("Ask data block: nothing new is sent", () => {
  it("has no heart-rate samples, emails or transcripts, even for a day the baseline reads", async () => {
    const { db } = await bigWorld();
    const env = await makeEnv(db);
    for (const body of [{ question: "How was this month?" }, { question: "Worst day of all time?" }]) {
      const { text } = await context(env, body);
      assert.doesNotMatch(text, /@/, "no email addresses");
      assert.doesNotMatch(text, /transcript/i);
      assert.doesNotMatch(text, /\b191\b/, "the cached meeting heart-rate sample");
      assert.doesNotMatch(text, /\b187\b|\b137\b/, "the day's average and max heart rate");
      assert.match(text, /Pat Reyes/, "names are still sent");
    }
  });
});

describe("Ask loads history once", () => {
  function recording(db: D1Database) {
    const log: Array<{ sql: string; args: unknown[] }> = [];
    const wrapped = {
      prepare(sql: string) {
        const stmt = db.prepare(sql);
        const entry = { sql, args: [] as unknown[] };
        log.push(entry);
        const w = {
          bind: (...a: unknown[]) => ((entry.args = a), stmt.bind(...a), w),
          first: () => stmt.first(),
          all: () => stmt.all(),
          run: () => stmt.run(),
        };
        return w;
      },
      batch: (stmts: Array<{ all: () => Promise<unknown> }>) => Promise.all(stmts.map((s) => s.all())),
    };
    return { db: wrapped as unknown as D1Database, log };
  }
  const eventLoads = (log: Array<{ sql: string }>) => log.filter((l) => /SELECT id, source, day, start_utc[\s\S]*FROM calendar_event\s+WHERE start_utc >= \?/.test(l.sql));
  const sliceLoads = (log: Array<{ sql: string }>, table: string) =>
    log.filter((l) => new RegExp(`FROM ${table}\\b`).test(l.sql) && /day >= \?/.test(l.sql));

  it("reads events once and each wearable's slices once, for the widest dates, with no per-day queries", async () => {
    const { db } = await bigWorld();
    const rec = recording(db);
    const env = await makeEnv(rec.db);
    stubJson();
    const r = await post(env, { question: "How was this month?" });
    assert.equal(r.status, 200);

    const events = eventLoads(rec.log);
    assert.equal(events.length, 1, "one load of events");
    const bounds = events[0].args as string[];
    assert.ok(bounds[0] >= "2026-03-01" && bounds[0] <= "2026-03-03", `events from ${bounds[0]}`);
    assert.ok(bounds[1] >= "2026-11-26", `events to ${bounds[1]}`);

    for (const table of ["daily_readiness", "daily_sleep", "daily_stress"]) {
      const loads = sliceLoads(rec.log, table);
      assert.equal(loads.length, 2, `${table}: one load per wearable`);
      assert.deepEqual(loads.map((l) => l.args[0]).sort(), ["oura", "whoop"], table);
      for (const l of loads) {
        assert.equal(l.args[1], "2026-03-02", `${table} from the history start`);
        assert.ok((l.args[2] as string) >= TODAY, `${table} to today`);
      }
    }
    assert.ok(rec.log.length <= 40, `${rec.log.length} statements for one question`);
  });

  it("widens the single load when the ranked dates start before the history does", async () => {
    const { db } = await bigWorld();
    const rec = recording(db);
    const env = await makeEnv(rec.db);
    stubJson();
    const r = await post(env, { question: Q, start: "2026-01-01", end: TODAY });
    assert.equal(r.status, 200);
    const events = eventLoads(rec.log);
    assert.equal(events.length, 1);
    assert.ok((events[0].args[0] as string) <= "2026-01-02", `events from ${events[0].args[0]}`);
    const readiness = sliceLoads(rec.log, "daily_readiness");
    assert.equal(readiness.length, 2);
    for (const l of readiness) assert.ok((l.args[1] as string) <= "2026-01-01", `slices from ${l.args[1]}`);
  });

  it("the stream does the same single load", async () => {
    const { db } = await bigWorld();
    const rec = recording(db);
    const env = await makeEnv(rec.db);
    stubStream(messageEvents(["ok"]));
    const s = await stream(env, { question: "How was this month?" });
    assert.equal(s.status, 200);
    assert.equal(eventLoads(rec.log).length, 1);
    assert.equal(sliceLoads(rec.log, "daily_readiness").length, 2);
    assert.ok(rec.log.length <= 40, `${rec.log.length} statements`);
  });
});

/* ================= must not break: the view's numbers ================= */

describe("buildUsual and heavyEffect for other callers", () => {
  const TZ = "America/New_York";
  const slice = (day: string, readiness: number): OuraDaySlice => ({
    day, sleepScore: 80, readinessScore: readiness, avgHrv: 40, lowestHr: 58, totalSleepS: 28000,
    stressHighS: null, recoveryHighS: null, stressSummary: null,
  });
  const event = (id: string, day: string, hours: number) => ({
    id, source: "google", day, start_utc: `${day}T15:00:00.000Z`,
    end_utc: new Date(Date.parse(`${day}T15:00:00.000Z`) + hours * 3_600_000).toISOString(),
    start_local: null, end_local: null, tz_offset_min: -300, duration_s: hours * 3600, title: id, kind: "client",
    client_key: null, project_key: null, attendee_count: 0, attendees_json: "[]", after_hours: 0, location: null,
  }) as unknown as CalendarEventRow;

  it("still use every row they are given: the first row's day, the last row's day, days before any meeting as light days", () => {
    const events = [event("a", "2026-11-02", 5), event("b", "2026-11-03", 1)];
    const byDay = new Map(days("2026-10-26", "2026-11-06").map((d) => [d, slice(d, d === "2026-11-03" ? 40 : 90)]));
    const rows = buildDayRows(events, byDay, "2026-10-26", "2026-11-05", TZ);
    const usual = buildUsual(rows);
    assert.equal(usual.from, "2026-10-26");
    assert.equal(usual.to, "2026-11-05");
    assert.equal(usual.days, 11);
    assert.equal(usual.recovery, 90);
    assert.equal(usual.meetingHours, 0);
    const effect = heavyEffect(rows);
    assert.deepEqual(effect.heavy, { days: 1, nextRecovery: 40 });
    assert.deepEqual(effect.lighter, { days: 10, nextRecovery: 90 });
    assert.equal(effect.cost, 50);
  });
});
