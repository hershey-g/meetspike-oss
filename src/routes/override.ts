import { Hono, type Context } from "hono";
import { bodyLimit } from "hono/body-limit";
import type { Env } from "../env.ts";
import { loadTimeZone } from "../lib/db.ts";
import { calendarDayInZone, DEFAULT_TIME_ZONE } from "../lib/time.ts";
import { whoopWebHrActive } from "../lib/wearable.ts";
import {
  clearOwnLinked,
  eventKey,
  loadOverridesForIds,
  loadSeriesOverrides,
  MAX_EARLY_START_MS,
  MAX_LATE_END_MS,
  MAX_WINDOW_MS,
  normalizeIso,
  OVERRIDE_STATES,
  overrideJson,
  saveOverride,
  seriesIdOf,
  seriesInstances,
  seenTimeFits,
  seriesKey,
  type OverridePatch,
  type OverrideRow,
  type OverrideSet,
  type OverrideState,
} from "../lib/meeting-override.ts";
import { reprojectMeeting } from "../sources/whoop-web/raw.ts";

/**
 * PUT /api/meetings/:id/override: the owner's choice for one meeting or for
 * every meeting in its series. See src/lib/meeting-override.ts.
 */
export const overrideRoute = new Hono<{ Bindings: Env }>();

const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,9})?)?(?:Z|[+-]\d{2}:?\d{2})$/;

/** A full ISO 8601 date and time with a zone, as UTC ISO text. Null for anything else. */
export function parseIsoInstant(value: unknown): string | null {
  return typeof value === "string" && ISO.test(value) ? normalizeIso(value) : null;
}

type CalendarTimes = { start_utc: string; end_utc: string };

export async function calendarTimesOf(db: D1Database, id: string): Promise<CalendarTimes | null> {
  return db.prepare(`SELECT start_utc, end_utc FROM calendar_event WHERE id = ? AND deleted_at IS NULL ORDER BY source LIMIT 1`)
    .bind(id).first<CalendarTimes>();
}

/** Run later when the platform allows it; otherwise now. Never throws. */
export function runAfterResponse(c: Context<{ Bindings: Env }>, work: Promise<unknown>): Promise<unknown> | void {
  const safe = work.catch((error) => {
    console.error(JSON.stringify({ event: "override_background_failed", error: String(error) }));
  });
  try {
    c.executionCtx.waitUntil(safe);
  } catch {
    return safe;
  }
}

/** Most instances of a series that are projected again when the series comes back. */
export const SERIES_REPROJECT_LIMIT = 60;

/**
 * After a change, project the meeting's stored raw heart rate again when its
 * effective times moved, or when it was left out and is included again (the
 * readings stored while it was out were never cut for it). A meeting that is
 * still left out is not touched. The user's change is already saved; a failure
 * here only leaves the old series, which the stale check retries.
 */
export function reprojectIfMoved(
  c: Context<{ Bindings: Env }>,
  id: string,
  calendar: CalendarTimes,
  before: OverrideSet,
  after: OverrideSet,
): Promise<unknown> | void {
  if (after.isExcluded(id) || !whoopWebHrActive(c.env)) return;
  const was = before.effective(id, calendar.start_utc, calendar.end_utc);
  const now = after.effective(id, calendar.start_utc, calendar.end_utc);
  const [wasStart, wasEnd] = [was?.startUtc ?? calendar.start_utc, was?.endUtc ?? calendar.end_utc];
  const [start, end] = [now?.startUtc ?? calendar.start_utc, now?.endUtc ?? calendar.end_utc];
  const cameBack = before.isExcluded(id);
  if (wasStart === start && wasEnd === end && !cameBack) return;
  return runAfterResponse(c, (async () => {
    const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
    await reprojectMeeting(c.env.DB, { id, startUtc: start, endUtc: end, day: calendarDayInZone(start, tz) },
      { startUtc: calendar.start_utc, endUtc: calendar.end_utc }, Date.now());
  })());
}

/**
 * A series choice that brings instances back: project the stored raw heart
 * rate of every instance that was out and is in now, newest first, at most
 * SERIES_REPROJECT_LIMIT. An instance with neither raw rows nor a stored row
 * writes nothing. One that has a stored row keeps all its points; when its
 * window differs from the row's and some points are not raw rows, it is marked
 * "not fetched for this window" and WHOOP is asked again (see raw.ts).
 */
export function reprojectSeriesBack(
  c: Context<{ Bindings: Env }>,
  seriesId: string,
  before: OverrideSet,
  after: OverrideSet,
): Promise<unknown> | void {
  if (!whoopWebHrActive(c.env)) return;
  return runAfterResponse(c, (async () => {
    const now = Date.now();
    const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
    const seen = new Set<string>();
    const back = (await seriesInstances(c.env.DB, seriesId, new Date(now).toISOString()))
      .filter((row) => !seen.has(row.id) && seen.add(row.id) && before.isExcluded(row.id) && !after.isExcluded(row.id))
      .slice(0, SERIES_REPROJECT_LIMIT);
    for (const row of back) {
      const found = after.effective(row.id, row.start_utc, row.end_utc);
      const [start, end] = [found?.startUtc ?? row.start_utc, found?.endUtc ?? row.end_utc];
      await reprojectMeeting(c.env.DB, { id: row.id, startUtc: start, endUtc: end, day: calendarDayInZone(start, tz) },
        { startUtc: row.start_utc, endUtc: row.end_utc }, now);
    }
  })());
}

const HOURS = (ms: number) => ms / 3600_000;

/**
 * The limits on a meeting's times, tested on what the meeting will count for
 * after this change: the times sent, else the ones already saved (the owner's,
 * then the Mac's), else the calendar's. Returns a short message, or null.
 */
export function timesProblem(
  calendar: CalendarTimes, own: OverrideRow | undefined, patch: OverridePatch,
): string | null {
  const calStart = Date.parse(calendar.start_utc);
  const calEnd = Date.parse(calendar.end_utc);
  const sent = (field: "startUtc" | "endUtc") => (field in patch ? patch[field] ?? null : undefined);
  const sentStart = sent("startUtc");
  const sentEnd = sent("endUtc");
  if (sentStart && Date.parse(sentStart) < calStart - MAX_EARLY_START_MS) {
    return `The start can be at most ${HOURS(MAX_EARLY_START_MS)} hours before the calendar start.`;
  }
  if (sentEnd && Date.parse(sentEnd) > calEnd + MAX_LATE_END_MS) {
    return `The end can be at most ${HOURS(MAX_LATE_END_MS)} hours after the calendar end.`;
  }
  if (!sentStart && !sentEnd) return null;
  const seenStart = own?.seen_start_utc && seenTimeFits({ startUtc: calendar.start_utc, endUtc: calendar.end_utc }, own.seen_start_utc) ? own.seen_start_utc : null;
  const seenEnd = own?.seen_end_utc && seenTimeFits({ startUtc: calendar.start_utc, endUtc: calendar.end_utc }, own.seen_end_utc) ? own.seen_end_utc : null;
  const start = Date.parse((sentStart !== undefined ? sentStart : own?.start_utc) ?? seenStart ?? calendar.start_utc);
  const end = Date.parse((sentEnd !== undefined ? sentEnd : own?.end_utc) ?? seenEnd ?? calendar.end_utc);
  if (!(end > start)) return "The end has to be after the start.";
  if (end - start > MAX_WINDOW_MS) return `A meeting can last at most ${HOURS(MAX_WINDOW_MS)} hours.`;
  return null;
}

overrideRoute.put("/:id/override", async (c, next) => {
  c.header("Cache-Control", "private, no-store");
  await next();
}, bodyLimit({ maxSize: 2048, onError: (c) => c.json({ error: "That request is too big." }, 413) }), async (c) => {
  const id = c.req.param("id") ?? "";
  if (!/^application\/json\s*(;|$)/i.test(c.req.header("content-type") ?? "")) {
    return c.json({ error: "Send JSON." }, 415);
  }
  const body = (await c.req.json().catch(() => null)) as Record<string, unknown> | null;
  if (!body || typeof body !== "object" || Array.isArray(body)) return c.json({ error: "Send a JSON object." }, 400);
  const scope = body.scope;
  if (scope !== "event" && scope !== "series") return c.json({ error: "Say whether this is for the event or the series." }, 400);

  const patch: OverridePatch = {};
  if ("state" in body) {
    if (body.state !== null && !OVERRIDE_STATES.includes(body.state as OverrideState)) {
      return c.json({ error: "State is not_joined, unlinked, linked or null." }, 400);
    }
    patch.state = body.state as OverrideState | null;
  }
  for (const field of ["startUtc", "endUtc"] as const) {
    if (!(field in body)) continue;
    if (scope === "series") return c.json({ error: "Times are for one meeting, not a series." }, 400);
    if (body[field] === null) {
      patch[field] = null;
      continue;
    }
    const iso = parseIsoInstant(body[field]);
    if (!iso) return c.json({ error: `${field} is a date and time like 2026-11-12T19:45:00Z, or null.` }, 400);
    patch[field] = iso;
  }
  if (!Object.keys(patch).length) return c.json({ error: "Send a state or times." }, 400);
  if (patch.startUtc && patch.endUtc && Date.parse(patch.endUtc) <= Date.parse(patch.startUtc)) {
    return c.json({ error: "The end has to be after the start." }, 400);
  }

  const calendar = await calendarTimesOf(c.env.DB, id);
  if (!calendar) return c.json({ error: "No meeting with that id." }, 404);
  const series = seriesIdOf(id);
  if (scope === "series" && !series) return c.json({ error: "That meeting is not part of a series." }, 400);

  const before = scope === "series" ? await loadSeriesOverrides(c.env.DB, series!) : await loadOverridesForIds(c.env.DB, [id]);
  if (!before.available) return c.json({ error: "Meeting choices need the database update first." }, 503);
  const problem = timesProblem(calendar, before.rows.get(eventKey(id)), patch);
  if (problem) return c.json({ error: problem }, 400);
  const key = scope === "series" ? seriesKey(series!) : eventKey(id);
  if (!(await saveOverride(c.env.DB, key, patch))) {
    return c.json({ error: "Meeting choices need the database update first." }, 503);
  }
  // "All of them" on a meeting that says `linked` for itself leaves the tapped meeting out too: its own
  // `linked` would beat the series. Only an exclusion clears it; times and sightings on the row stay.
  if (scope === "series" && (patch.state === "not_joined" || patch.state === "unlinked")
    && before.rows.get(eventKey(id))?.state === "linked") {
    try {
      await clearOwnLinked(c.env.DB, id);
    } catch (error) {
      console.error(JSON.stringify({ event: "override_clear_linked_failed", meetingId: id, error: String(error) }));
      return c.json({ error: "Could not save. Try again." }, 500);
    }
  }
  const after = scope === "series" ? await loadSeriesOverrides(c.env.DB, series!) : await loadOverridesForIds(c.env.DB, [id]);
  const done = after.effective(id, calendar.start_utc, calendar.end_utc);
  const pending = scope === "series" ? reprojectSeriesBack(c, series!, before, after) : reprojectIfMoved(c, id, calendar, before, after);
  if (pending) await pending;
  console.log(JSON.stringify({ event: "meeting_override", meetingId: id, scope, fields: Object.keys(patch) }));
  return c.json({
    ok: true,
    id,
    scope,
    override: overrideJson(done?.override),
    startUtc: done?.startUtc ?? calendar.start_utc,
    endUtc: done?.endUtc ?? calendar.end_utc,
    excluded: done?.override.excluded ?? false,
  });
});
