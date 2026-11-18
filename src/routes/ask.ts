/**
 * "Ask your data": chat with your meetings and recovery using your own
 * Claude API key. The key is stored encrypted (see lib/ai-key.ts) and is only
 * ever used server-side; the browser sees its last four characters.
 */
import { Hono } from "hono";
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
import { activeWearableInfo } from "../lib/wearable.ts";
import { isDateRangeError, parseDateRange } from "../lib/date-range.ts";
import { loadJoinedMeetings, loadOuraSlices } from "../sources/calendar/query.ts";
import { buildDayRows, buildUsual, heavyEffect } from "../lib/usual.ts";

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
/** Days of history sent with a question when no range is selected. */
const DEFAULT_ASK_DAYS = 60;
const MAX_QUESTION_CHARS = 2000;
const MAX_HISTORY_TURNS = 12;

ask.get("/status", async (c) => {
  const info = await aiKeyInfo(c.env);
  return c.json({
    ok: true,
    // false: the Worker has no AI_KEY_SECRET, so a key cannot be stored yet.
    available: canStoreAiKey(c.env),
    connected: Boolean(info),
    tail: info?.tail ?? null,
    savedAt: info?.savedAt ?? null,
    model: ASK_MODEL,
  });
});

ask.put("/key", async (c) => {
  if (!canStoreAiKey(c.env)) {
    return c.json({ error: "This Worker has no AI_KEY_SECRET yet. Set it with: wrangler secret put AI_KEY_SECRET" }, 503);
  }
  const body = (await c.req.json().catch(() => null)) as { key?: unknown } | null;
  const key = typeof body?.key === "string" ? body.key.trim() : "";
  if (!looksLikeAnthropicKey(key)) {
    return c.json({ error: "That does not look like a Claude API key. It starts with sk-ant-." }, 400);
  }
  // A cheap authenticated call proves the key works before it is stored.
  const Anthropic = await loadSdk();
  try {
    await new Anthropic({ apiKey: key, maxRetries: 1 }).models.retrieve(ASK_MODEL);
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
    .map((t) => ({ role: t.role, content: t.content.slice(0, 8000) }))
    .slice(-MAX_HISTORY_TURNS);
  // The conversation must start with the user.
  while (turns.length && turns[0].role !== "user") turns.shift();
  return turns;
}

ask.post("/", async (c) => {
  const env = c.env;
  const body = (await c.req.json().catch(() => null)) as
    | { question?: unknown; start?: unknown; end?: unknown; history?: unknown }
    | null;
  const question = typeof body?.question === "string" ? body.question.trim().slice(0, MAX_QUESTION_CHARS) : "";
  if (!question) return c.json({ error: "Ask a question first." }, 400);

  const apiKey = await loadAiKey(env);
  if (!apiKey) return c.json({ error: "Add your Claude API key in More, then ask again.", needsKey: true }, 409);

  const tz = await loadTimeZone(env.DB).catch(() => DEFAULT_TIME_ZONE);
  const today = calendarDayInZone(new Date().toISOString(), tz);
  const hasRange = typeof body?.start === "string" || typeof body?.end === "string";
  const range = hasRange
    ? parseDateRange({ start: body?.start as string, end: body?.end as string }, { today })
    : { start: addCalendarDays(today, -(DEFAULT_ASK_DAYS - 1)), end: today, spanDays: DEFAULT_ASK_DAYS };
  if (isDateRangeError(range)) return c.json({ error: range.error }, 400);

  const w = activeWearableInfo(env);
  const [joined, slices] = await Promise.all([
    loadJoinedMeetings(env.DB, range.start, range.end, tz, w.source),
    loadOuraSlices(env.DB, range.start, addCalendarDays(range.end, 1), w.source),
  ]);
  const events = joined.map((j) => j.event);
  const rows = buildDayRows(events, slices.byDay, range.start, range.end, tz);
  const data = buildAskContext({
    rows,
    events,
    usual: buildUsual(rows),
    effect: heavyEffect(rows),
    labels: {
      wearable: w.label,
      readiness: w.readinessLabel.toLowerCase(),
      strain: w.strainLabel ? w.strainLabel.toLowerCase() : null,
    },
    timeZone: tz,
    today,
  });

  const Anthropic = await loadSdk();
  const client = new Anthropic({ apiKey, maxRetries: 1 });
  try {
    const response = await client.beta.messages.create({
      model: ASK_MODEL,
      max_tokens: 16000,
      // Short factual answers over a small table: medium effort is enough.
      output_config: { effort: "medium" },
      // On a policy decline, Anthropic re-runs the request on a fallback model.
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      system: [
        { type: "text", text: ASK_SYSTEM_PROMPT },
        // Follow-up questions within a few minutes reuse this block from cache.
        { type: "text", text: `<data>\n${data}\n</data>`, cache_control: { type: "ephemeral" } },
      ],
      messages: [...cleanHistory(body?.history), { role: "user", content: question }],
    });
    if (response.stop_reason === "refusal") {
      return c.json({ ok: true, answer: "Claude declined to answer that one. Try asking it a different way.", refused: true });
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
      start: range.start,
      end: range.end,
    });
  } catch (err) {
    if (err instanceof Anthropic.AuthenticationError) {
      return c.json({ error: "Anthropic no longer accepts the saved key. Replace it in More.", needsKey: true }, 400);
    }
    if (err instanceof Anthropic.RateLimitError) {
      return c.json({ error: "Your Anthropic account is rate limited right now. Try again in a minute." }, 429);
    }
    if (err instanceof Anthropic.APIError) {
      return c.json({ error: `Anthropic returned an error (${err.status}). Try again.` }, 502);
    }
    return c.json({ error: "Could not reach Anthropic. Try again." }, 502);
  }
});
