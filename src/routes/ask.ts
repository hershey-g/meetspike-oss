/**
 * "Ask your data": chat with your meetings and recovery using your own
 * Claude API key. The key is stored encrypted (see lib/ai-key.ts) and is only
 * ever used server-side; the browser sees its last four characters.
 */
import { Hono } from "hono";
import { streamSSE } from "hono/streaming";
import type AnthropicClient from "@anthropic-ai/sdk";
import type { Env } from "../env.ts";
import {
  aiKeyInfo,
  canStoreAiKey,
  deleteAiKey,
  loadAiKey,
  looksLikeAnthropicKey,
  saveAiKey,
} from "../lib/ai-key.ts";
import { ASK_SYSTEM_PROMPT, buildAskContext } from "../lib/ask-context.ts";
import { loadTimeZone } from "../lib/db.ts";
import { addCalendarDays, calendarDayInZone, DEFAULT_TIME_ZONE } from "../lib/time.ts";
import { wearableInfo } from "../lib/wearable.ts";
import { displayedSources, loadSourceDisplay, type SourceDisplay } from "../lib/source-display.ts";
import { isDateRangeError, parseDateRange } from "../lib/date-range.ts";
import { loadHistoryStart, questionPeriod } from "../lib/history-range.ts";
import { loadCalendarEvents, loadOuraSlices } from "../sources/calendar/query.ts";
import { buildAllHistoryBaseline, buildDayRows } from "../lib/usual.ts";

export const ask = new Hono<{ Bindings: Env }>();

/**
 * The SDK is only needed when someone saves a key or asks a question, so it is
 * loaded then, not on every request the Worker serves.
 */
let sdkPromise: Promise<typeof AnthropicClient> | null = null;
function loadSdk(): Promise<typeof AnthropicClient> {
  sdkPromise ??= import("@anthropic-ai/sdk").then((m) => m.default);
  return sdkPromise;
}

export const ASK_MODEL = "claude-opus-5-5";
const MAX_QUESTION_CHARS = 2000;
const MAX_HISTORY_TURNS = 12;
const MAX_TURN_CHARS = 8000;
/**
 * Largest question body read, in bytes. A full request (a 2,000-character
 * question and 12 turns of 8,000 characters, at up to 3 UTF-8 bytes each)
 * stays well under this; anything bigger is refused before it is parsed.
 */
export const MAX_ASK_BODY_BYTES = 512 * 1024;
const MAX_KEY_BODY_BYTES = 16 * 1024;

/**
 * The SDK's own diagnostics can print raw stream data, which may hold answer
 * text. Every client here is silent; the routes log only safe metadata.
 */
const SILENT_LOGGER = { error() {}, warn() {}, info() {}, debug() {} };
function newClient(Anthropic: typeof AnthropicClient, apiKey: string) {
  return new Anthropic({ apiKey, maxRetries: 1, logLevel: "off", logger: SILENT_LOGGER });
}

/** Error name and HTTP status only: never the message, body or stack. */
export function safeErrorMeta(err: unknown): { name: string; status?: number } {
  const name = err instanceof Error ? err.name : typeof err;
  const status = (err as { status?: unknown } | null)?.status;
  return typeof status === "number" ? { name, status } : { name };
}

type JsonBody = { ok: true; value: unknown } | { ok: false; tooLarge: true };

/**
 * Reads a JSON body, stopping at maxBytes. Bodies over the limit are refused
 * without being buffered in full or parsed; unparseable JSON comes back as null.
 */
export async function readJsonLimited(req: Request, maxBytes: number): Promise<JsonBody> {
  const declared = Number(req.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) return { ok: false, tooLarge: true };
  if (!req.body) return { ok: true, value: null };
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) {
      await reader.cancel().catch(() => {});
      return { ok: false, tooLarge: true };
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    bytes.set(c, at);
    at += c.byteLength;
  }
  try {
    return { ok: true, value: JSON.parse(new TextDecoder().decode(bytes)) };
  } catch {
    return { ok: true, value: null };
  }
}

const TOO_LARGE = { error: "That question is too long to send. Start a new chat and try again." };

ask.get("/status", async (c) => {
  c.header("Cache-Control", "private, no-store");
  const [info, sourceDisplay] = await Promise.all([aiKeyInfo(c.env), loadSourceDisplay(c.env)]);
  return c.json({
    ok: true,
    // false: the Worker has no AI_KEY_SECRET, so a key cannot be stored yet.
    available: canStoreAiKey(c.env),
    connected: Boolean(info),
    tail: info?.tail ?? null,
    savedAt: info?.savedAt ?? null,
    model: ASK_MODEL,
    sourceDisplay,
  });
});

ask.put("/key", async (c) => {
  if (!canStoreAiKey(c.env)) {
    return c.json({ error: "This Worker has no AI_KEY_SECRET yet. Set it with: wrangler secret put AI_KEY_SECRET" }, 503);
  }
  const read = await readJsonLimited(c.req.raw, MAX_KEY_BODY_BYTES);
  if (!read.ok) return c.json({ error: "That does not look like a Claude API key." }, 413);
  const body = read.value as { key?: unknown } | null;
  const key = typeof body?.key === "string" ? body.key.trim() : "";
  if (!looksLikeAnthropicKey(key)) {
    return c.json({ error: "That does not look like a Claude API key. It starts with sk-ant-." }, 400);
  }
  // A cheap authenticated call proves the key works before it is stored.
  const Anthropic = await loadSdk();
  try {
    await newClient(Anthropic, key).models.retrieve(ASK_MODEL);
  } catch (err) {
    if (err instanceof Anthropic.AuthenticationError) return c.json({ error: "Anthropic rejected that key." }, 400);
    if (err instanceof Anthropic.PermissionDeniedError) {
      return c.json({ error: `That key cannot use ${ASK_MODEL}.` }, 400);
    }
    if (err instanceof Anthropic.APIError) {
      return c.json({ error: `Could not check the key right now (Anthropic returned ${err.status}). Try again.` }, 502);
    }
    return c.json({ error: "Could not reach Anthropic to check the key. Try again." }, 502);
  }
  const saved = await saveAiKey(c.env, key);
  return c.json({ ok: true, connected: true, ...saved });
});

ask.delete("/key", async (c) => {
  await deleteAiKey(c.env);
  return c.json({ ok: true, connected: false });
});

type Turn = { role: "user" | "assistant"; content: string };

function cleanHistory(raw: unknown): Turn[] {
  if (!Array.isArray(raw)) return [];
  const turns = raw
    .filter(
      (t): t is Turn =>
        Boolean(t) &&
        typeof t === "object" &&
        ((t as Turn).role === "user" || (t as Turn).role === "assistant") &&
        typeof (t as Turn).content === "string" &&
        (t as Turn).content.trim().length > 0,
    )
    .map((t) => ({ role: t.role, content: t.content.slice(0, MAX_TURN_CHARS) }))
    .slice(-MAX_HISTORY_TURNS);
  // The conversation must start with the user.
  while (turns.length && turns[0].role !== "user") turns.shift();
  return turns;
}

type AskBody = {
  question?: unknown; start?: unknown; end?: unknown; history?: unknown; sourceDisplay?: SourceDisplay;
  allTime?: unknown; ignorePeriod?: unknown;
} | null;

/** Where the ranked dates came from, in the order they are tried. */
export type RangeSource = "question" | "allTime" | "followUp" | "tab" | "history";

type Dates = { start: string; end: string };

type AskRequest = {
  question: string;
  apiKey: string;
  history: Turn[];
  /** The dates ranked and described to Claude. */
  range: Dates;
  rangeSource: RangeSource;
  /** All history, history start to today. Baselines always cover it. */
  baseline: Dates;
  tz: string;
  today: string;
  display: SourceDisplay;
};

type AskInvalid = { error: string; status: 400 | 409; needsKey?: boolean };

/**
 * Checks a question before any data is loaded or anything is streamed:
 * a question, a saved key and a valid range. Failures come back as the same
 * JSON errors on both /api/ask and /api/ask/stream.
 */
async function parseAsk(env: Env, body: AskBody): Promise<AskRequest | AskInvalid> {
  const question = typeof body?.question === "string" ? body.question.trim().slice(0, MAX_QUESTION_CHARS) : "";
  if (!question) return { error: "Ask a question first.", status: 400 };

  const apiKey = await loadAiKey(env);
  if (!apiKey) return { error: "Add your Claude API key in More, then ask again.", status: 409, needsKey: true };

  const tz = await loadTimeZone(env.DB).catch(() => DEFAULT_TIME_ZONE);
  const today = calendarDayInZone(new Date().toISOString(), tz);
  const display = await loadSourceDisplay(env);
  const history = body?.sourceDisplay?.oura === display.oura && body.sourceDisplay.whoop === display.whoop
    ? cleanHistory(body.history) : [];
  const [primary, secondary] = displayedSources(env, display);
  const baseline = { start: await loadHistoryStart(env.DB, primary ?? null, tz, today, secondary ?? null), end: today };

  // Which dates are ranked, first that applies: a period in the question, the All time switch,
  // the newest earlier question with a period, the tab's dates, then all history.
  const ignorePeriod = body?.ignorePeriod === true;
  const pick = (period: Dates | "all" | null, source: RangeSource): { dates: Dates; source: RangeSource } | null =>
    period ? { dates: period === "all" ? baseline : period, source } : null;
  const earlier = history.filter((turn) => turn.role === "user").reverse()
    .map((turn) => questionPeriod(turn.content, today)).find(Boolean) ?? null;
  const tab = {
    start: typeof body?.start === "string" ? body.start : undefined,
    end: typeof body?.end === "string" ? body.end : undefined,
  };
  const chosen =
    (ignorePeriod ? null : pick(questionPeriod(question, today), "question")) ??
    pick(body?.allTime === true ? "all" : null, "allTime") ??
    (ignorePeriod ? null : pick(earlier, "followUp")) ??
    (tab.start?.trim() || tab.end?.trim() ? { dates: tab as Dates, source: "tab" as const } : null) ??
    { dates: baseline, source: "history" as const };
  const range = parseDateRange(chosen.dates, { today });
  if (isDateRangeError(range)) return { error: range.error, status: 400 };

  return {
    question, apiKey, history, range: { start: range.start, end: range.end },
    rangeSource: chosen.source, baseline, tz, today, display,
  };
}

function isInvalid(r: AskRequest | AskInvalid): r is AskInvalid {
  return "error" in r;
}

/**
 * Meetings and scores for the ranked dates and for all history, joined to scores. Step one of answering.
 * One load of events and one load of each wearable's scores, over the widest dates needed:
 * the ranked dates only decide what is sent in detail, the baselines always cover all history.
 */
async function loadAskMeetings(env: Env, req: AskRequest) {
  const [primarySource, secondarySource] = displayedSources(env, req.display);
  const w = primarySource ? wearableInfo(primarySource) : null;
  const secondary = secondarySource ? wearableInfo(secondarySource) : null;
  const from = req.range.start < req.baseline.start ? req.range.start : req.baseline.start;
  const to = req.range.end > req.baseline.end ? req.range.end : req.baseline.end;
  const next = addCalendarDays(to, 1);
  const [all, slices, other] = await Promise.all([
    loadCalendarEvents(env.DB, from, to, req.tz),
    loadOuraSlices(env.DB, from, next, primarySource ?? null),
    loadOuraSlices(env.DB, from, next, secondarySource ?? null),
  ]);
  const events = all.filter((e) => {
    const day = calendarDayInZone(e.start_utc, req.tz);
    return day >= req.range.start && day <= req.range.end;
  });
  return { w, events, allEvents: all, byDay: slices.byDay, secondary, other: other.byDay };
}

/** Day rows and the data block sent to Claude. Step two of answering. */
function buildAskData(req: AskRequest, loaded: Awaited<ReturnType<typeof loadAskMeetings>>) {
  const { w, events, allEvents, byDay, secondary, other } = loaded;
  const rows = buildDayRows(events, byDay, req.range.start, req.range.end, req.tz);
  const otherRows = other.size ? buildDayRows(events, other, req.range.start, req.range.end, req.tz) : [];

  // Baselines: every day from the history start to today, each wearable on its own scores.
  const firstMeeting = allEvents.map((e) => calendarDayInZone(e.start_utc, req.tz)).sort()[0] ?? null;
  const baselineFor = (scores: typeof byDay) =>
    buildAllHistoryBaseline(buildDayRows(allEvents, scores, req.baseline.start, req.baseline.end, req.tz), firstMeeting, req.today);
  const base = baselineFor(byDay);
  const otherBase = secondary && other.size ? baselineFor(other) : null;
  const otherData = secondary && otherBase ? {
    rows: otherRows,
    usual: otherBase.usual,
    effect: otherBase.effect,
    labels: {
      wearable: secondary.label,
      readiness: secondary.readinessLabel.toLowerCase(),
      strain: secondary.strainLabel?.toLowerCase() ?? null,
    },
  } : undefined;
  const data = buildAskContext({
    rows,
    events,
    usual: base.usual,
    effect: base.effect,
    labels: w ? {
      wearable: w.label,
      readiness: w.readinessLabel.toLowerCase(),
      strain: w.strainLabel ? w.strainLabel.toLowerCase() : null,
    } : null,
    timeZone: req.tz,
    today: req.today,
    range: req.range,
    baseline: req.baseline,
    secondary: otherData,
  });
  return { nights: countScoredNights([...rows, ...otherRows]), data };
}

/** Mornings with a score in the rows: each row's own morning, and the morning after its day. */
export function countScoredNights(rows: Array<{ day: string; morning: unknown; next: unknown }>): number {
  const days = new Set<string>();
  for (const r of rows) {
    if (r.morning) days.add(r.day);
    if (r.next) days.add(addCalendarDays(r.day, 1));
  }
  return days.size;
}

/** "2026-09-22" → "Sep 22". */
export function shortDate(day: string): string {
  return new Date(`${day}T12:00:00.000Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
}

function messageParams(req: AskRequest, data: string) {
  return {
    model: ASK_MODEL,
    max_tokens: 16000,
    // Short factual answers over a small table: medium effort is enough.
    output_config: { effort: "medium" as const },
    // On a policy decline, Anthropic re-runs the request on a fallback model.
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default" as const,
    system: [
      { type: "text" as const, text: ASK_SYSTEM_PROMPT },
      // Follow-up questions within a few minutes reuse this block from cache.
      { type: "text" as const, text: `<data>\n${data}\n</data>`, cache_control: { type: "ephemeral" as const } },
    ],
    messages: [...req.history, { role: "user" as const, content: req.question }],
  };
}

/** What the answer ranked and what the baselines cover, on POST /api/ask and the stream's `done`. */
function rangeFields(req: AskRequest) {
  return {
    start: req.range.start,
    end: req.range.end,
    baselineStart: req.baseline.start,
    baselineEnd: req.baseline.end,
    rangeSource: req.rangeSource,
  };
}

const REFUSAL_TEXT = "Claude declined to answer that one. Try asking it a different way.";

/** The same plain sentences for Anthropic failures on both routes. */
function anthropicFailure(Anthropic: typeof AnthropicClient, err: unknown): { error: string; status: 400 | 429 | 502; needsKey?: boolean } {
  if (err instanceof Anthropic.AuthenticationError) {
    return { error: "Anthropic no longer accepts the saved key. Replace it in More.", status: 400, needsKey: true };
  }
  if (err instanceof Anthropic.RateLimitError) {
    return { error: "Your Anthropic account is rate limited right now. Try again in a minute.", status: 429 };
  }
  if (err instanceof Anthropic.APIError) {
    return { error: `Anthropic returned an error (${err.status}). Try again.`, status: 502 };
  }
  return { error: "Could not reach Anthropic. Try again.", status: 502 };
}

ask.post("/", async (c) => {
  const env = c.env;
  const read = await readJsonLimited(c.req.raw, MAX_ASK_BODY_BYTES);
  if (!read.ok) return c.json(TOO_LARGE, 413);
  const req = await parseAsk(env, read.value as AskBody);
  if (isInvalid(req)) return c.json(req.needsKey ? { error: req.error, needsKey: true } : { error: req.error }, req.status);

  const { data } = buildAskData(req, await loadAskMeetings(env, req));

  const Anthropic = await loadSdk();
  const client = newClient(Anthropic, req.apiKey);
  try {
    const response = await client.beta.messages.create(messageParams(req, data));
    if (response.stop_reason === "refusal") {
      return c.json({ ok: true, answer: REFUSAL_TEXT, refused: true });
    }
    const answer = response.content
      .filter((b): b is AnthropicClient.Beta.BetaTextBlock => b.type === "text")
      .map((b) => b.text)
      .join("\n")
      .trim();
    return c.json({
      ok: true,
      answer: answer || "No answer came back. Try again.",
      truncated: response.stop_reason === "max_tokens",
      model: response.model,
      ...rangeFields(req),
    });
  } catch (err) {
    console.error("ask failed", safeErrorMeta(err));
    const f = anthropicFailure(Anthropic, err);
    return c.json(f.needsKey ? { error: f.error, needsKey: true } : { error: f.error }, f.status);
  }
});

/** Keeps proxies from closing a quiet stream while Claude thinks. */
export const ASK_PING_MS = 15_000;

/**
 * The same question as POST /api/ask, answered as server-sent events so the
 * app can show real progress and stop mid-answer:
 *   range {start, end, baselineStart, baselineEnd, rangeSource}  once, first
 *   step  {id, label, status: "active"|"done"}  calendar → body → think → write
 *   text  {delta}
 *   done  {truncated, model, start, end, baselineStart, baselineEnd, rangeSource, refused?, interrupted?}
 *   error {error, needsKey?}
 * `interrupted: true` (with `truncated: true`) means Anthropic's stream closed
 * before message_stop: the text so far is partial. A response that ends with
 * neither done nor error was cut off too, and the app treats it the same way.
 * Problems found before streaming starts (body too large, no question, no key,
 * bad range) are plain JSON errors, as on /api/ask. Closing the request cancels
 * the Anthropic call.
 */
ask.post("/stream", async (c) => {
  const env = c.env;
  const read = await readJsonLimited(c.req.raw, MAX_ASK_BODY_BYTES);
  if (!read.ok) return c.json(TOO_LARGE, 413);
  const req = await parseAsk(env, read.value as AskBody);
  if (isInvalid(req)) return c.json(req.needsKey ? { error: req.error, needsKey: true } : { error: req.error }, req.status);

  const res = streamSSE(c, async (stream) => {
    const abort = new AbortController();
    const stop = () => abort.abort();
    stream.onAbort(stop);
    const reqSignal = c.req.raw.signal;
    if (reqSignal?.aborted) stop();
    reqSignal?.addEventListener?.("abort", stop);

    const send = async (event: string, payload: unknown) => {
      if (abort.signal.aborted) return;
      await stream.writeSSE({ event, data: JSON.stringify(payload) });
    };
    const step = (id: string, label: string, status: "active" | "done") => send("step", { id, label, status });
    const ping = setInterval(() => {
      if (!abort.signal.aborted) void stream.write(": ping\n\n");
    }, ASK_PING_MS);

    try {
      await send("range", rangeFields(req));
      await step("calendar", "Reading your calendar", "active");
      const loaded = await loadAskMeetings(env, req);
      await step(
        "calendar",
        `Read ${loaded.events.length} ${loaded.events.length === 1 ? "meeting" : "meetings"} from ${shortDate(req.range.start)} to ${shortDate(req.range.end)}`,
        "done",
      );

      await step("body", loaded.w ? "Lining up sleep and recovery" : "Preparing calendar history", "active");
      const { nights, data } = buildAskData(req, loaded);
      const wearables = [loaded.w?.label, loaded.other.size ? loaded.secondary?.label : null].filter(Boolean).join(" and ");
      await step("body", wearables
        ? `Lined up ${nights} ${nights === 1 ? "night" : "nights"} of ${wearables} scores`
        : "Prepared calendar history", "done");
      if (abort.signal.aborted) return;

      const Anthropic = await loadSdk();
      const client = newClient(Anthropic, req.apiKey);
      await step("think", "Thinking it through", "active");
      let wrote = false;
      let stopReason: string | null = null;
      let model: string = ASK_MODEL;
      let finished = false;
      try {
        const events = await client.beta.messages.create({ ...messageParams(req, data), stream: true }, { signal: abort.signal });
        for await (const ev of events) {
          if (abort.signal.aborted) break;
          if (ev.type === "message_start") model = ev.message.model || model;
          else if (ev.type === "message_delta") stopReason = ev.delta.stop_reason ?? stopReason;
          else if (ev.type === "message_stop") finished = true;
          else if (ev.type === "content_block_delta" && ev.delta.type === "text_delta" && ev.delta.text) {
            if (!wrote) {
              wrote = true;
              await step("think", "Thought it through", "done");
              await step("write", "Writing the answer", "active");
            }
            await send("text", { delta: ev.delta.text });
          }
        }
      } catch (err) {
        if (abort.signal.aborted || err instanceof Anthropic.APIUserAbortError) return;
        console.error("ask stream: anthropic failed", safeErrorMeta(err));
        const f = anthropicFailure(Anthropic, err);
        await send("error", f.needsKey ? { error: f.error, needsKey: true } : { error: f.error });
        return;
      }
      if (abort.signal.aborted) return;

      if (!finished) {
        // The connection closed mid-answer: keep what arrived, say it is partial.
        console.warn("ask stream: anthropic stream ended before message_stop", { wrote });
        await send("done", { truncated: true, interrupted: true, model, ...rangeFields(req) });
        return;
      }
      if (stopReason === "refusal") {
        if (!wrote) await step("think", "Thought it through", "done");
        await send("text", { delta: wrote ? `\n\n${REFUSAL_TEXT}` : REFUSAL_TEXT });
        await send("done", { truncated: false, model, ...rangeFields(req), refused: true });
        return;
      }
      if (!wrote) {
        await step("think", "Thought it through", "done");
        await send("text", { delta: "No answer came back. Try again." });
      } else {
        await step("write", "Wrote the answer", "done");
      }
      await send("done", { truncated: stopReason === "max_tokens", model, ...rangeFields(req) });
    } catch (err) {
      if (abort.signal.aborted) return;
      console.error("ask stream failed", safeErrorMeta(err));
      await send("error", { error: "Something went wrong reading your data. Try again." });
    } finally {
      clearInterval(ping);
      reqSignal?.removeEventListener?.("abort", stop);
    }
  });
  // Answers are private: no browser, proxy or edge cache may keep them.
  res.headers.set("Cache-Control", "private, no-store, no-transform");
  return res;
});
