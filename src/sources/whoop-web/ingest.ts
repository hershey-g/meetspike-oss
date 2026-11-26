import type { Env } from "../../env.ts";
import { loadTimeZone } from "../../lib/db.ts";
import { calendarDayInZone, DEFAULT_TIME_ZONE } from "../../lib/time.ts";
import { BACKFILL_MAX_DAYS, WINDOW_PAD_MIN } from "./constants.ts";
import { logRun, storeStressDay, toInput, type EventRow } from "./fill.ts";
import { fetchWindow, isStale, MAX_MEETING_S, MAX_MOVED_MEETING_S, meetingLimitS, stressDayWindow } from "./meeting-hr.ts";
import { INGEST_VERSION, type HrSpan, type WhoopWebIngestSource } from "./ingest-payload.ts";
import { parseHeartRate, parseStressDay, type HrPoint } from "./parse.ts";
import { projectRawHr, storeRawHr } from "./raw.ts";
import { getCachedStressDays } from "./store.ts";
import { applyOverrides, loadOverridesInRange, type ResolvedOverride } from "../../lib/meeting-override.ts";

/**
 * POST /api/whoop-web/ingest stores raw samples from Codebox and BLE, then
 * projects them onto calendar meetings.
 *
 * Body, version 1 (WhoopWebIngestPayload in ingest-payload.ts):
 *   {
 *     version: 1,
 *     source?: "codebox" | "ble",              // defaults to "codebox"
 *     fetchedAt: ISO,                          // time of the fetch or BLE snapshot
 *     hr: { spans: [{ startMs, endMs }], points: [[unix_ms, bpm], ...] },
 *     stress?: [{ day: "YYYY-MM-DD", body: <stress-bff JSON> } | { day, error }],
 *     errors?: [string],                       // non-auth fetch trouble, short
 *     authError?: { code, message }            // the job could not sign in
 *   }
 * `spans` describe the fetch coverage, including windows with no samples.
 * Every sample is stored, including points outside the declared spans.
 */
/** Hard caps so a bad client cannot make the Worker do unbounded work. */
const MAX_SPAN_MS = (BACKFILL_MAX_DAYS + 2) * 86_400_000;
const MAX_POINTS = 24 * 60 * (BACKFILL_MAX_DAYS + 2) * 2;
const MAX_SPANS = 200;
const MAX_STRESS_DAYS = BACKFILL_MAX_DAYS + 2;
const MAX_TEXT = 300;

export type IngestResult = {
  ok: true;
  rawStored: true;
  timeZone: string;
  meetings: { written: number; empty: number; unchanged: number; uncovered: number };
  stress: { written: number; empty: number; errors: number; unchanged: number };
  authError: string | null;
};

export type ParsedIngest =
  | { ok: true; source: WhoopWebIngestSource; fetchedAtMs: number; spans: HrSpan[]; points: HrPoint[]; stress: Array<{ day: string; body?: unknown; error?: string }>; errors: string[]; authError: string | null }
  | { ok: false; error: string };

function isRecord(v: unknown): v is Record<string, unknown> {
  return Boolean(v) && typeof v === "object" && !Array.isArray(v);
}

/** One line, printable characters only, bounded. What goes into sync_log.error_text. */
function shortText(v: unknown): string {
  return String(v ?? "")
    .replace(/[^\x20-\x7e]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, MAX_TEXT);
}

/** Validate an ingest body. Never throws; anything off is a 400 with a reason. */
export function parseIngestPayload(body: unknown, now: number): ParsedIngest {
  if (!isRecord(body)) return { ok: false, error: "JSON object body required" };
  if (body.version !== INGEST_VERSION) return { ok: false, error: `version must be ${INGEST_VERSION}` };
  const source = body.source === undefined ? "codebox" : body.source;
  if (source !== "codebox" && source !== "ble") return { ok: false, error: 'source must be "codebox" or "ble"' };
  const fetchedAt = typeof body.fetchedAt === "string" ? Date.parse(body.fetchedAt) : NaN;
  if (!Number.isFinite(fetchedAt)) return { ok: false, error: "fetchedAt must be an ISO time" };
  // A skewed clock on the box must not mark rows as fetched in the future.
  const fetchedAtMs = Math.min(fetchedAt, now);
  if (now - fetchedAtMs > 86_400_000) return { ok: false, error: "fetchedAt is more than a day old" };

  let authError: string | null = null;
  if (body.authError !== undefined) {
    if (!isRecord(body.authError)) return { ok: false, error: "authError must be an object" };
    authError = `${shortText(body.authError.code) || "auth"}: ${shortText(body.authError.message)}`;
  }

  const hr = isRecord(body.hr) ? body.hr : authError ? { spans: [], points: [] } : null;
  if (!hr) return { ok: false, error: "hr { spans, points } required" };
  if (!Array.isArray(hr.spans) || hr.spans.length > MAX_SPANS) return { ok: false, error: "hr.spans must be a list" };
  const spans: HrSpan[] = [];
  for (const s of hr.spans) {
    if (!isRecord(s)) return { ok: false, error: "bad hr span" };
    const startMs = Number(s.startMs);
    const endMs = Number(s.endMs);
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs <= startMs) return { ok: false, error: "bad hr span" };
    if (!Number.isSafeInteger(startMs) || !Number.isSafeInteger(endMs) || startMs < 0 ||
        endMs > now + 60_000 || endMs - startMs > MAX_SPAN_MS ||
        (source === "codebox" && now - startMs > MAX_SPAN_MS)) {
      return { ok: false, error: "hr span outside the allowed range" };
    }
    spans.push({ startMs, endMs });
  }
  if (!Array.isArray(hr.points) || hr.points.length > MAX_POINTS) return { ok: false, error: "hr.points must be a list" };
  // Same parser as the Worker's own fetch: drops junk, dedupes, sorts.
  const parsed = parseHeartRate(hr.points);
  if (!parsed.recognized || parsed.points.some(([t]) => !Number.isSafeInteger(t) || t < 0 || t > 8.64e15)) {
    return { ok: false, error: "hr.points are not [unix_ms, bpm] pairs" };
  }

  const stress: Array<{ day: string; body?: unknown; error?: string }> = [];
  if (body.stress !== undefined) {
    if (!Array.isArray(body.stress) || body.stress.length > MAX_STRESS_DAYS) return { ok: false, error: "stress must be a list" };
    for (const s of body.stress) {
      if (!isRecord(s) || typeof s.day !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(s.day)) return { ok: false, error: "bad stress day" };
      if (typeof s.error === "string") stress.push({ day: s.day, error: shortText(s.error) });
      else stress.push({ day: s.day, body: s.body });
    }
  }
  const errors = Array.isArray(body.errors) ? body.errors.slice(0, 20).map(shortText).filter(Boolean) : [];
  return { ok: true, source, fetchedAtMs, spans, points: parsed.points, stress, errors, authError };
}

/** Merge overlapping or touching spans. */
export function mergeSpans(spans: HrSpan[]): HrSpan[] {
  const sorted = [...spans].sort((a, b) => a.startMs - b.startMs);
  const out: HrSpan[] = [];
  for (const s of sorted) {
    const last = out[out.length - 1];
    if (last && s.startMs <= last.endMs) last.endMs = Math.max(last.endMs, s.endMs);
    else out.push({ ...s });
  }
  return out;
}

/** Milliseconds of [startMs, min(endMs, fetchedAtMs)] that the (merged) spans cover. */
export function coveredMs(spans: HrSpan[], range: { startMs: number; endMs: number }, fetchedAtMs: number): number {
  const end = Math.min(range.endMs, fetchedAtMs);
  let total = 0;
  for (const s of spans) total += Math.max(0, Math.min(s.endMs, end) - Math.max(s.startMs, range.startMs));
  return total;
}

/** A sorted batch can contain a single point or readings with no declared spans. */
function hasPoint(points: HrPoint[], fromMs: number, toMs: number): boolean {
  let lo = 0;
  let hi = points.length;
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    if (points[mid][0] < fromMs) lo = mid + 1;
    else hi = mid;
  }
  return lo < points.length && points[lo][0] <= toMs;
}

type IngestEnv = Pick<Env, "DB">;
type ProjectionCandidate = EventRow & { override?: ResolvedOverride; window_start_utc: string | null; window_end_utc: string | null };

export async function applyWhoopWebIngest(env: IngestEnv, p: Extract<ParsedIngest, { ok: true }>, now: number): Promise<IngestResult> {
  await storeRawHr(env.DB, p.source, p.points, now);
  const tz = await loadTimeZone(env.DB).catch(() => DEFAULT_TIME_ZONE);
  const result: IngestResult = {
    ok: true,
    rawStored: true,
    timeZone: tz,
    meetings: { written: 0, empty: 0, unchanged: 0, uncovered: 0 },
    stress: { written: 0, empty: 0, errors: 0, unchanged: 0 },
    authError: p.authError,
  };
  const fetchedAt = new Date(p.fetchedAtMs).toISOString();

  if (p.authError) {
    await logRun(env, { trigger: p.source, endpoint: "ingest", status: "error", errorText: p.authError });
    return result;
  }

  const spans = mergeSpans(p.spans);
  const fromMs = Math.min(spans[0]?.startMs ?? Infinity, p.points[0]?.[0] ?? Infinity);
  const toMs = Math.max(spans.at(-1)?.endMs ?? -Infinity, p.points.at(-1)?.[0] ?? -Infinity);
  if (Number.isFinite(fromMs) && fromMs <= now + WINDOW_PAD_MIN * 60_000) {
    const padMs = WINDOW_PAD_MIN * 60_000;
    // Calendar meetings last up to 8 h; a meeting the owner moved up to 12 h, so those are read from further back.
    const startFrom = new Date(fromMs - MAX_MEETING_S * 1000 - padMs).toISOString();
    const movedStartFrom = new Date(fromMs - MAX_MOVED_MEETING_S * 1000 - padMs).toISOString();
    const startTo = new Date(Math.min(now, toMs + padMs)).toISOString();
    const endFrom = new Date(fromMs - padMs).toISOString();
    const candidates = (extra: boolean) => env.DB.prepare(
      `SELECT e.id, e.start_utc, e.end_utc, e.duration_s, e.title, h.window_start_utc, h.window_end_utc
       FROM calendar_event e LEFT JOIN whoop_web_hr h ON h.event_id = e.id
       WHERE ${extra
         ? "e.id IN (SELECT value FROM json_each(?)) AND e.deleted_at IS NULL"
         : `e.start_utc BETWEEN ? AND ? AND e.end_utc >= ?
         AND e.deleted_at IS NULL AND e.duration_s > 0 AND e.duration_s <= ?`}`,
    );
    // Meetings whose times were changed (by the owner or the Mac) are matched on their effective times,
    // so the calendar rows near the window are read with those overrides, and the original tests run again on them.
    const [base, overrides] = await Promise.all([
      candidates(false).bind(startFrom, startTo, endFrom, MAX_MEETING_S).all<ProjectionCandidate>(),
      loadOverridesInRange(env.DB, {
        startUtc: new Date(Date.parse(movedStartFrom) - 16 * 3600_000).toISOString(),
        endUtcExclusive: new Date(Date.parse(startTo) + 3 * 3600_000).toISOString(),
      }),
    ]);
    let events = base.results ?? [];
    if (overrides.size) {
      const shifted = overrides.shiftedEventIds();
      if (shifted.length) {
        const have = new Set(events.map((e) => e.id));
        const more = await candidates(true).bind(JSON.stringify(shifted)).all<ProjectionCandidate>();
        events = [...events, ...(more.results ?? []).filter((e) => !have.has(e.id))];
      }
      events = applyOverrides(events, overrides).filter((e) =>
        e.start_utc >= (e.override?.timesChanged ? movedStartFrom : startFrom) && e.start_utc <= startTo && e.end_utc >= endFrom &&
        e.duration_s > 0 && e.duration_s <= meetingLimitS(e.override?.timesChanged));
    }
    const projections: Parameters<typeof projectRawHr>[1] = [];
    for (const e of events) {
      const meeting = toInput(e, tz);
      const win = fetchWindow(meeting.startUtc, meeting.endUtc);
      // Ingest starts a row when samples or reported coverage reach the meeting.
      // Once a row exists, uploads during either pad can extend it.
      const sameWindow = e.window_start_utc === win.startUtc && e.window_end_utc === win.endUtc;
      const range = sameWindow ? win : { startMs: Date.parse(e.start_utc), endMs: Date.parse(e.end_utc) };
      const allowEmpty = coveredMs(spans, range, p.fetchedAtMs) > 0;
      if (allowEmpty || hasPoint(p.points, range.startMs, range.endMs)) {
        projections.push({
          meeting,
          allowEmpty,
          ...(e.override?.timesChanged ? { calendar: { startUtc: e.override.calendarStartUtc, endUtc: e.override.calendarEndUtc } } : {}),
        });
      }
      else result.meetings.uncovered += 1;
    }
    Object.assign(result.meetings, await projectRawHr(env.DB, projections, fetchedAt));
  }

  const today = calendarDayInZone(new Date(now).toISOString(), tz);
  const days = [...new Set(p.stress.map((s) => s.day))].filter((d) => d <= today);
  const stressCached = await getCachedStressDays(env.DB, days);
  const seen = new Set<string>();
  for (const s of p.stress) {
    if (s.day > today || seen.has(s.day)) continue;
    seen.add(s.day);
    if (!isStale(stressCached.get(s.day) ?? null, stressDayWindow(s.day, tz), now)) {
      result.stress.unchanged += 1;
      continue;
    }
    let res: Parameters<typeof storeStressDay>[2];
    if (s.error !== undefined) res = { ok: false, status: 0, reason: s.error };
    else {
      const v = parseStressDay(s.body, s.day, tz);
      res = v.recognized ? { ok: true, value: v } : { ok: false, status: 200, reason: "stress response in an unknown shape" };
    }
    const outcome = await storeStressDay(env, s.day, res, fetchedAt);
    if (outcome === "error") result.stress.errors += 1;
    else if (outcome === "fetched") result.stress.written += 1;
    else result.stress.empty += 1;
  }

  const problems = [...p.errors, ...(result.stress.errors ? [`${result.stress.errors} stress day(s) failed`] : [])];
  await logRun(env, {
    trigger: p.source,
    endpoint: "ingest",
    status: spans.length === 0 && p.errors.length ? "error" : problems.length ? "partial" : "ok",
    written: result.meetings.written + result.stress.written,
    skipped: result.meetings.empty + result.meetings.unchanged + result.stress.unchanged,
    errorText: problems.length ? shortText(problems.join("; ")) : null,
    windowStart: Number.isFinite(fromMs) ? new Date(fromMs).toISOString() : null,
    windowEnd: Number.isFinite(toMs) ? new Date(toMs).toISOString() : null,
  });
  return result;
}
