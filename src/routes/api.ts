import { Hono } from "hono";
import type { Env } from "../env.ts";
import { displayTitle, sandboxMode } from "../env.ts";
import { getGoogleTokens, getOuraTokens, getWhoopTokens } from "../lib/tokens.ts";
import { activeWearableInfo, wearableChoice, type WearableInfo } from "../lib/wearable.ts";
import { ingestWhoopFixtures } from "../sources/whoop/ingest.ts";
import { WHOOP_START_PATH } from "../sources/whoop/endpoints.ts";
import { whoopCallback } from "./whoop.ts";
import { setupStatus } from "./setup.ts";
import { loadTimeZone, upsertCalendarEvent } from "../lib/db.ts";
import { SOURCE_OURA, SOURCE_WHOOP } from "../types.ts";
import { ingestFixtures } from "../sources/oura/ingest.ts";
import { addUtcDays, formatUtcDay } from "../sources/oura/endpoints.ts";
import { calendarDayInZone, DEFAULT_TIME_ZONE, addCalendarDays, weekBoundsMonday } from "../lib/time.ts";
import { ingestCalendarFixtures, syncPrimaryCalendar } from "../sources/calendar/ingest.ts";
import {
  loadAttendeeDisplayName,
  loadJoinedMeetings,
  loadJoinedMeetingsByAttendee,
  loadOuraSlices,
  sliceForDay,
} from "../sources/calendar/query.ts";
import {
  buildDayBriefing,
  grainNote,
  type BriefingLabels,
  buildWeekBriefing,
  rankSleepImpactMeetings,
  rankStressedMeetings,
  stressScore,
  toMeetingJson,
  toPersonMeetingJson,
} from "../sources/calendar/meetings.ts";
import { parseDayRange, queryDailyMetrics } from "../lib/daily-metrics.ts";
import { isDateRangeError, isValidDay, parseDateRange, validateDateRange } from "../lib/date-range.ts";
import { buildRangeBriefing } from "../sources/calendar/range.ts";
import type { JoinedMeeting } from "../sources/calendar/join.ts";
import {
  INSIGHTS_DEFAULT_DAYS,
  INSIGHTS_HIT_LIMIT,
  buildBaseline,
  parseInsightsDays,
  rankHits,
  toInsightMeeting,
} from "../lib/insights.ts";
import { HR_METHOD_NOTE, type MeetingHrStress } from "../lib/heartrate.ts";
import { loadDayHrSeries, loadMeetingHrMap } from "../lib/heartrate-archive.ts";
import { getRawJson } from "../lib/r2.ts";
import { extractAttendees, normalizeEmail, parseAttendeesJson, pickPersonName, summarizePerson } from "../lib/people.ts";
import { readAdminSecret, timingSafeEqual } from "../lib/secret.ts";
import { planPlaudIngest } from "../sources/plaud/project.ts";
import { ask } from "./ask.ts";
import { buildDayRows, buildUsual, costliestDays, heavyEffect, peopleOnHeavyDays } from "../lib/usual.ts";

export const api = new Hono<{ Bindings: Env }>();

// Chat with your data, with the user's own Claude API key.
api.route("/ask", ask);

function hrInputs(joined: JoinedMeeting[]) {
  return joined.map((j) => ({
    id: j.event.id,
    startUtc: j.event.start_utc,
    endUtc: j.event.end_utc,
    day: j.event.day,
  }));
}

/** The words briefing and insight copy need, taken from the active wearable. */
function labelsFor(w: WearableInfo): BriefingLabels {
  return {
    provider: w.label,
    readiness: w.readinessLabel.toLowerCase(),
    strain: w.strainLabel ? w.strainLabel.toLowerCase() : null,
    intradayHr: w.hasIntradayHr,
  };
}

/** What the "how this was measured" line says for the active wearable. */
function methodNoteFor(w: WearableInfo): string {
  return w.hasIntradayHr ? HR_METHOD_NOTE : w.note;
}

/**
 * Heart-rate inside each meeting window. A wearable that only reports day
 * totals has nothing to slice, so nothing is read and nothing is invented.
 */
async function meetingHrMap(
  env: Env,
  w: WearableInfo,
  joined: JoinedMeeting[],
  lowestHr: Map<string, number | null>,
  tz: string,
): Promise<Map<string, MeetingHrStress>> {
  if (!w.hasIntradayHr) return new Map();
  return loadMeetingHrMap(env, hrInputs(joined), lowestHr, tz);
}

// WHOOP sends the browser back here after the user approves access.
api.get("/whoop/callback", whoopCallback);

/** First-run setup page data: redirect addresses, which keys exist, what is connected. */
api.get("/setup/status", async (c) => c.json(await setupStatus(c.env, c.req.url)));

/** True when the request names an explicit start/end span (not the legacy single-value params). */
function hasSpanQuery(start: string | undefined, end: string | undefined): boolean {
  return Boolean(start?.trim() || end?.trim());
}

api.get("/health", async (c) => {
  const tables = [
    "daily_sleep",
    "daily_readiness",
    "daily_activity",
    "daily_stress",
    "sleep_periods",
    "workouts",
    "sessions",
    "tags",
    "raw_object",
    "calendar_event",
  ] as const;
  const w = activeWearableInfo(c.env);
  // One D1 round trip for every count, the last sync and the date span, run
  // alongside the token reads, instead of ~14 queries one after another.
  const db = c.env.DB;
  const [batch, strainCount, tokens, google] = await Promise.all([
    db.batch([
      ...tables.map((t) => db.prepare(`SELECT COUNT(*) AS n FROM ${t}`)),
      db.prepare(`SELECT created_at, status, trigger FROM sync_log ORDER BY created_at DESC LIMIT 1`),
      db.prepare(`SELECT MIN(day) AS min, MAX(day) AS max FROM daily_sleep WHERE source = ?`).bind(w.source),
    ]),
    // Arrives with migration 0008. Absent is reported as absent, not as a failure.
    w.strainLabel
      ? db
          .prepare(`SELECT COUNT(*) AS n FROM daily_strain`)
          .first<{ n: number }>()
          .then((row) => row?.n ?? 0)
          .catch(() => 0)
      : Promise.resolve(null),
    w.source === SOURCE_WHOOP ? getWhoopTokens(c.env) : getOuraTokens(c.env),
    getGoogleTokens(c.env),
  ]);
  const counts: Record<string, number> = {};
  tables.forEach((t, i) => {
    counts[t] = (batch[i].results?.[0] as { n?: number } | undefined)?.n ?? 0;
  });
  if (strainCount != null) counts.daily_strain = strainCount;
  const last = (batch[tables.length].results?.[0] ?? null) as { created_at: string; status: string; trigger: string } | null;
  const range = (batch[tables.length + 1].results?.[0] ?? null) as { min: string | null; max: string | null } | null;
  return c.json({
    ok: true,
    brand: "meetspike",
    displayTitle: displayTitle(c.env),
    // Only Oura has a sandbox; WHOOP is always live data (or fixtures).
    sandbox: w.source === SOURCE_OURA && sandboxMode(c.env),
    wearable: { ...w, chosenBy: wearableChoice(c.env).reason },
    timeZone: "America/New_York",
    lastSync: last ?? null,
    counts,
    range: range ?? { min: null, max: null },
    token: {
      present: Boolean(tokens),
      expiresAt: tokens?.expires_at ?? null,
    },
    google: {
      present: Boolean(google),
      expiresAt: google?.expires_at ?? null,
    },
  });
});

api.get("/sleep", async (c) => {
  const limit = Math.min(Number(c.req.query("limit") ?? "30"), 90);
  const rows = await c.env.DB.prepare(
    `SELECT * FROM daily_sleep WHERE source = ? ORDER BY day DESC LIMIT ?`,
  )
    .bind(activeWearableInfo(c.env).source, limit)
    .all();
  return c.json(rows.results);
});

type BackfillMode = "fixtures" | "sandbox" | "production";

api.post("/backfill", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    mode?: BackfillMode;
    startDay?: string;
    endDay?: string;
  };
  if (activeWearableInfo(c.env).source === SOURCE_WHOOP) {
    const mode: BackfillMode = body.mode ?? "production";
    if (mode === "fixtures") {
      const tally = await ingestWhoopFixtures(c.env, 21);
      return c.json({ mode, wearable: SOURCE_WHOOP, ...tally });
    }
    if (mode === "sandbox") {
      return c.json({ error: "WHOOP has no sandbox — use mode \"fixtures\" for sample data or \"production\" for your own" }, 400);
    }
    if (!(await getWhoopTokens(c.env))) {
      return c.json({ error: `no whoop tokens — connect WHOOP at ${WHOOP_START_PATH}` }, 401);
    }
    const endDay = body.endDay ?? formatUtcDay(new Date());
    const startDay = body.startDay ?? addUtcDays(endDay, -30);
    const instance = await c.env.BACKFILL.create({
      id: `backfill-whoop-${startDay}-${endDay}-${Date.now()}`,
      params: { mode, startDay, endDay, trigger: "manual" },
    });
    return c.json({ mode, wearable: SOURCE_WHOOP, workflowId: instance.id, startDay, endDay });
  }
  const mode: BackfillMode = body.mode ?? (sandboxMode(c.env) ? "sandbox" : "production");
  if (mode === "fixtures") {
    const tally = await ingestFixtures(c.env, 21);
    return c.json({ mode, ...tally });
  }
  if (mode === "production" && sandboxMode(c.env)) {
    return c.json({ error: "OURA_SANDBOX is true — refuse production backfill" }, 400);
  }
  const endDay = body.endDay ?? formatUtcDay(new Date());
  const startDay = body.startDay ?? addUtcDays(endDay, -30);
  const id = `backfill-${mode}-${startDay}-${endDay}-${Date.now()}`;
  const instance = await c.env.BACKFILL.create({
    id,
    params: { mode, startDay, endDay, trigger: "manual" },
  });
  return c.json({ mode, workflowId: instance.id, startDay, endDay });
});

api.post("/calendar/sync", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    mode?: "live" | "fixtures";
    startDay?: string;
    endDay?: string;
  };
  const mode = body.mode ?? "live";
  if (mode === "fixtures") {
    const tally = await ingestCalendarFixtures(c.env);
    return c.json({ mode, ...tally });
  }
  const google = await getGoogleTokens(c.env);
  if (!google) {
    return c.json({ error: "no google tokens — complete OAuth at /auth/google/start" }, 401);
  }
  const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
  const today = calendarDayInZone(new Date().toISOString(), tz);
  const endDay = body.endDay ?? today;
  const startDay = body.startDay ?? addCalendarDays(endDay, -14);
  const tally = await syncPrimaryCalendar(c.env, { start: startDay, end: endDay }, "manual");
  return c.json({ mode, startDay, endDay, ...tally });
});

api.get("/meetings/stressed", async (c) => {
  const limit = Math.min(Number(c.req.query("limit") ?? "20"), 90);
  const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
  const today = calendarDayInZone(new Date().toISOString(), tz);
  const range = validateDateRange(
    c.req.query("start") ?? c.req.query("from") ?? addCalendarDays(today, -7),
    c.req.query("end") ?? c.req.query("to") ?? addCalendarDays(today, 14),
  );
  if (isDateRangeError(range)) return c.json({ error: range.error }, 400);
  const { start: from, end: to } = range;
  const w = activeWearableInfo(c.env);
  const joined = await loadJoinedMeetings(c.env.DB, from, to, tz, w.source);
  const { byDay } = await loadOuraSlices(c.env.DB, from, to, w.source);
  const lowestHr = new Map([...byDay.entries()].map(([d, s]) => [d, s.lowestHr]));
  const hrByMeetingId = await meetingHrMap(c.env, w, joined, lowestHr, tz);
  return c.json({
    ok: true,
    from,
    to,
    timeZone: tz,
    wearable: w,
    grain: grainNote(labelsFor(w)),
    meetings: rankStressedMeetings(joined, limit, hrByMeetingId),
  });
});

api.get("/meetings/sleep-impact", async (c) => {
  const limit = Math.min(Number(c.req.query("limit") ?? "20"), 90);
  const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
  const today = calendarDayInZone(new Date().toISOString(), tz);
  const range = validateDateRange(
    c.req.query("start") ?? c.req.query("from") ?? addCalendarDays(today, -21),
    c.req.query("end") ?? c.req.query("to") ?? today,
  );
  if (isDateRangeError(range)) return c.json({ error: range.error }, 400);
  const { start: from, end: to } = range;
  const w = activeWearableInfo(c.env);
  const joined = await loadJoinedMeetings(c.env.DB, from, to, tz, w.source);
  return c.json({
    ok: true,
    from,
    to,
    timeZone: tz,
    wearable: w,
    grain: grainNote(labelsFor(w)),
    meetings: rankSleepImpactMeetings(joined, limit),
  });
});

api.get("/metrics/daily", async (c) => {
  const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
  const today = calendarDayInZone(new Date().toISOString(), tz);
  const parsed = parseDayRange(c.req.query("start"), c.req.query("end"), today);
  if ("error" in parsed) return c.json({ error: parsed.error }, 400);

  const w = activeWearableInfo(c.env);
  const days = await queryDailyMetrics(c.env.DB, parsed.start, parsed.end, w.source, {
    strain: w.strainLabel != null,
  });
  return c.json({
    ok: true,
    start: parsed.start,
    end: parsed.end,
    timeZone: tz,
    wearable: w,
    grain: grainNote(labelsFor(w)),
    days,
  });
});

api.get("/insights/hits", async (c) => {
  const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
  const today = calendarDayInZone(new Date().toISOString(), tz);
  let windowDays = parseInsightsDays(c.req.query("days"));
  let to = today;
  let from = addCalendarDays(to, -(windowDays - 1));
  // Explicit start/end replaces the rolling "last N days" window.
  const spanned = hasSpanQuery(c.req.query("start"), c.req.query("end"));
  if (spanned) {
    const range = parseDateRange({ start: c.req.query("start"), end: c.req.query("end") }, { today });
    if (isDateRangeError(range)) return c.json({ error: range.error }, 400);
    ({ start: from, end: to, spanDays: windowDays } = range);
  }
  return c.json(await insightsJson(c.env, from, to, windowDays, spanned, tz));
});

async function insightsJson(env: Env, from: string, to: string, windowDays: number, spanned: boolean, tz: string) {
  const w = activeWearableInfo(env);
  const labels = labelsFor(w);
  const [metricDays, joined] = await Promise.all([
    queryDailyMetrics(env.DB, from, addCalendarDays(to, 1), w.source),
    loadJoinedMeetings(env.DB, from, to, tz, w.source),
  ]);
  const baseline = buildBaseline(metricDays, windowDays, spanned ? { from, to } : undefined, labels);
  const lowestHr = new Map(metricDays.map((d) => [d.day, d.lowestHr]));
  const hrByMeetingId = await meetingHrMap(env, w, joined, lowestHr, tz);
  const hits = rankHits({
    days: metricDays,
    meetings: joined.map((j) => toInsightMeeting(j.event)),
    baseline,
    from,
    to,
    limit: INSIGHTS_HIT_LIMIT,
    hrByMeetingId,
    labels,
  });
  return {
    ok: true as const,
    from,
    to,
    timeZone: tz,
    wearable: w,
    grain: grainNote(labels),
    baseline,
    hits,
    defaultDays: INSIGHTS_DEFAULT_DAYS,
  };
}

async function dayBriefingJson(env: Env, date: string, tz: string) {
  const w = activeWearableInfo(env);
  const [joined, { byDay }] = await Promise.all([
    loadJoinedMeetings(env.DB, date, date, tz, w.source),
    loadOuraSlices(env.DB, date, addCalendarDays(date, 1), w.source),
  ]);
  const lowestHr = new Map<string, number | null>();
  const prior = sliceForDay(byDay, date);
  if (prior) lowestHr.set(date, prior.lowestHr);
  // No day strip without intraday heart-rate: `hr` comes back null and the UI shows day totals instead.
  const [hrByMeetingId, hrSeries] = await Promise.all([
    meetingHrMap(
      env,
      w,
      joined.filter((j) => calendarDayInZone(j.event.start_utc, tz) === date),
      lowestHr,
      tz,
    ),
    w.hasIntradayHr ? loadDayHrSeries(env, date, tz) : Promise.resolve(undefined),
  ]);
  const briefing = buildDayBriefing({
    date,
    timeZone: tz,
    joined,
    priorNight: prior,
    nextMorning: sliceForDay(byDay, addCalendarDays(date, 1)),
    hrByMeetingId,
    hrSeries,
    hrMethodNote: HR_METHOD_NOTE,
    labels: labelsFor(w),
  });
  return { ...briefing, wearable: w, methodNote: methodNoteFor(w) };
}

async function rangeBriefingJson(env: Env, start: string, end: string, tz: string) {
  const w = activeWearableInfo(env);
  // Mornings start..end+1: the last day's "night after" lands on end+1.
  const [joined, { byDay }] = await Promise.all([
    loadJoinedMeetings(env.DB, start, end, tz, w.source),
    loadOuraSlices(env.DB, start, addCalendarDays(end, 1), w.source),
  ]);
  const lowestHr = new Map([...byDay.entries()].map(([d, s]) => [d, s.lowestHr]));
  const hrByMeetingId = await meetingHrMap(env, w, joined, lowestHr, tz);
  return {
    ...buildRangeBriefing({
      start,
      end,
      timeZone: tz,
      joined,
      recoveryByDay: byDay,
      hrByMeetingId,
      intradayHr: w.hasIntradayHr,
    }),
    wearable: w,
    grain: grainNote(labelsFor(w)),
    methodNote: methodNoteFor(w),
  };
}

/**
 * Single day: `?date=D` (or `?start=D&end=D`) keeps the day-briefing shape.
 * A multi-day `start`/`end` returns the same aggregate as /briefing/range.
 */
api.get("/briefing/day", async (c) => {
  const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
  const today = calendarDayInZone(new Date().toISOString(), tz);
  const range = parseDateRange(
    { date: c.req.query("date"), start: c.req.query("start"), end: c.req.query("end") },
    { today },
  );
  if (isDateRangeError(range)) return c.json({ error: range.error }, 400);
  if (range.spanDays === 1) return c.json(await dayBriefingJson(c.env, range.start, tz));
  return c.json(await rangeBriefingJson(c.env, range.start, range.end, tz));
});

/** Aggregate over an inclusive span. `?date=D` or `start=end` is a one-day range. */
api.get("/briefing/range", async (c) => {
  const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
  const today = calendarDayInZone(new Date().toISOString(), tz);
  const range = parseDateRange(
    { date: c.req.query("date"), start: c.req.query("start"), end: c.req.query("end") },
    { today },
  );
  if (isDateRangeError(range)) return c.json({ error: range.error }, 400);
  return c.json(await rangeBriefingJson(c.env, range.start, range.end, tz));
});

/**
 * Everything one screen needs, in one request: the day or range briefing,
 * "your usual" over the 28 days ending on the last selected day, the
 * heavy-day comparison, the costliest days and people, a per-day series for
 * the chart, connection status, and (for a wearable with heart-rate inside
 * meetings) the ranked meeting hits. The parts load in parallel.
 */
api.get("/view", async (c) => {
  const env = c.env;
  const tz = await loadTimeZone(env.DB).catch(() => DEFAULT_TIME_ZONE);
  const today = calendarDayInZone(new Date().toISOString(), tz);
  const range = parseDateRange(
    { date: c.req.query("date"), start: c.req.query("start"), end: c.req.query("end") },
    { today },
  );
  if (isDateRangeError(range)) return c.json({ error: range.error }, 400);
  const { start, end, spanDays } = range;
  const w = activeWearableInfo(env);
  const usualFrom = addCalendarDays(end, -(USUAL_WINDOW_DAYS - 1));
  const windowFrom = start < usualFrom ? start : usualFrom;
  const single = spanDays === 1;

  const [main, joined, slices, hits, status] = await Promise.all([
    single ? dayBriefingJson(env, start, tz) : rangeBriefingJson(env, start, end, tz),
    loadJoinedMeetings(env.DB, windowFrom, end, tz, w.source),
    loadOuraSlices(env.DB, windowFrom, addCalendarDays(end, 1), w.source),
    // Ranking meetings by heart-rate only means something with heart-rate inside meetings.
    w.hasIntradayHr
      ? single
        ? insightsJson(env, addCalendarDays(today, -(INSIGHTS_DEFAULT_DAYS - 1)), today, INSIGHTS_DEFAULT_DAYS, false, tz)
        : insightsJson(env, start, end, spanDays, true, tz)
      : Promise.resolve(null),
    viewStatus(env, w),
  ]);

  const rows = buildDayRows(
    joined.map((j) => j.event),
    slices.byDay,
    windowFrom,
    end,
    tz,
  );
  const usualRows = rows.filter((r) => r.day >= usualFrom);
  const selected = rows.filter((r) => r.day >= start);
  // A single day is too few to compare, so the day view compares over the usual window.
  const basis = single ? usualRows : selected;

  return c.json(
    {
      ok: true,
      today,
      start,
      end,
      spanDays,
      timeZone: tz,
      wearable: w,
      status,
      day: single ? main : null,
      range: single ? null : main,
      usual: buildUsual(usualRows),
      effect: { ...heavyEffect(basis), from: basis[0]?.day ?? start, to: end },
      costly: costliestDays(basis),
      people: peopleOnHeavyDays(basis),
      series: selected.map((r) => ({
        day: r.day,
        meetingCount: r.meetingCount,
        meetingHours: Math.round((r.meetingS / 3600) * 10) / 10,
        afterHours: r.afterHours,
        recovery: r.morning?.readinessScore ?? null,
        sleep: r.morning?.sleepScore ?? null,
        strain: r.morning?.strain ?? null,
        nextRecovery: r.next?.readinessScore ?? null,
      })),
      hits: hits?.hits ?? null,
      baselineNote: hits?.baseline.note ?? null,
    },
    { headers: { "Cache-Control": "private, max-age=30, stale-while-revalidate=300" } },
  );
});

const USUAL_WINDOW_DAYS = 28;

/** What the menu and banners need: connections and the last sync. No table counts. */
async function viewStatus(env: Env, w: WearableInfo) {
  const [tokens, google, last] = await Promise.all([
    w.source === SOURCE_WHOOP ? getWhoopTokens(env) : getOuraTokens(env),
    getGoogleTokens(env),
    env.DB.prepare(`SELECT created_at, status FROM sync_log ORDER BY created_at DESC LIMIT 1`)
      .first<{ created_at: string; status: string }>()
      .catch(() => null),
  ]);
  return {
    displayTitle: displayTitle(env),
    sandbox: w.source === SOURCE_OURA && sandboxMode(env),
    wearableConnected: Boolean(tokens),
    googleConnected: Boolean(google),
    lastSync: last ?? null,
  };
}

api.get("/briefing/week", async (c) => {
  const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
  const date = c.req.query("date") ?? calendarDayInZone(new Date().toISOString(), tz);
  if (!isValidDay(date)) return c.json({ error: "date must be a valid YYYY-MM-DD date" }, 400);
  const { start, end } = weekBoundsMonday(date);
  const w = activeWearableInfo(c.env);
  const joined = await loadJoinedMeetings(c.env.DB, start, end, tz, w.source);
  const { byDay } = await loadOuraSlices(c.env.DB, start, addCalendarDays(end, 1), w.source);
  const lowestHr = new Map([...byDay.entries()].map(([d, s]) => [d, s.lowestHr]));
  const hrByMeetingId = await meetingHrMap(c.env, w, joined, lowestHr, tz);
  return c.json({
    ...buildWeekBriefing({
      date,
      timeZone: tz,
      weekStart: start,
      weekEnd: end,
      joined,
      hrByMeetingId,
      intradayHr: w.hasIntradayHr,
    }),
    wearable: w,
  });
});

api.post("/plaud/ingest", async (c) => {
  const expected = c.env.INGEST_ADMIN_SECRET?.trim() ?? "";
  if (!expected) return c.json({ error: "INGEST_ADMIN_SECRET is not set" }, 503);
  const got = readAdminSecret(c.req.header("x-admin-secret"), c.req.header("authorization"));
  if (!got || !timingSafeEqual(got, expected)) return c.json({ error: "unauthorized" }, 401);

  const body = await c.req.json().catch(() => null);
  const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
  const now = new Date().toISOString();
  const planned = planPlaudIngest(body, { timeZone: tz, now });
  let written = 0;
  let skipped = 0;
  const results: Array<{
    plaud_file_id: string | null;
    status: "written" | "skipped" | "rejected";
    reason?: string;
    source_type?: string;
  }> = planned.reject.map((r) => ({
    plaud_file_id: r.plaud_file_id,
    status: "rejected" as const,
    reason: r.reason,
  }));
  for (const row of planned.accept) {
    const status = await upsertCalendarEvent(c.env.DB, row);
    if (status === "written") written += 1;
    else skipped += 1;
    results.push({
      plaud_file_id: row.plaud_file_id ?? row.id,
      status,
      source_type: row.source_type,
    });
  }
  return c.json({
    ok: true,
    written,
    skipped,
    rejected: planned.reject.length,
    truncated: planned.truncated,
    timeZone: tz,
    results,
  });
});

api.get("/people/:email/meetings", async (c) => {
  const email = normalizeEmail(decodeURIComponent(c.req.param("email") ?? ""));
  if (!email) return c.json({ error: "email is required" }, 400);
  const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
  const today = calendarDayInZone(new Date().toISOString(), tz);
  const windowDays = parseInsightsDays(c.req.query("days") ?? "60");
  let to = today;
  let from = addCalendarDays(to, -(windowDays - 1));
  if (hasSpanQuery(c.req.query("start"), c.req.query("end"))) {
    const range = parseDateRange({ start: c.req.query("start"), end: c.req.query("end") }, { today });
    if (isDateRangeError(range)) return c.json({ error: range.error }, 400);
    ({ start: from, end: to } = range);
  }
  const w = activeWearableInfo(c.env);
  const { joined, byDay } = await loadJoinedMeetingsByAttendee(c.env.DB, email, from, to, tz, w.source);
  const name = await resolvePersonName(c.env, email, joined);
  const lowestHr = new Map([...byDay.entries()].map(([d, s]) => [d, s.lowestHr]));
  const hrByMeetingId = await meetingHrMap(c.env, w, joined, lowestHr, tz);
  const meetings = joined
    .map((row) => {
      const json = toMeetingJson(row, stressScore(row), hrByMeetingId.get(row.event.id) ?? null);
      return toPersonMeetingJson(json, json.signals.nextSleepScore, json.signals.nextReadinessScore);
    })
    .sort((a, b) => b.startUtc.localeCompare(a.startUtc));
  const trend = summarizePerson(meetings);
  return c.json(
    {
      ok: true,
      email,
      name,
      from,
      to,
      timeZone: tz,
      wearable: w,
      grain: grainNote(labelsFor(w)),
      methodNote: methodNoteFor(w),
      trend,
      meetings,
    },
    { headers: { "Cache-Control": "private, max-age=30, stale-while-revalidate=120" } },
  );
});

async function resolvePersonName(
  env: Env,
  email: string,
  joined: Array<{ event: { attendees_json: string | null; raw_id: number | null } }>,
): Promise<string | null> {
  const fromJson = pickPersonName(
    email,
    joined.map((row) => parseAttendeesJson(row.event.attendees_json)),
  );
  if (fromJson) return fromJson;
  const fromIndex = await loadAttendeeDisplayName(env.DB, email);
  if (fromIndex) return fromIndex;
  for (const row of joined.slice(0, 2)) {
    if (row.event.raw_id == null) continue;
    const obj = await env.DB.prepare(`SELECT r2_key FROM raw_object WHERE id = ? LIMIT 1`)
      .bind(row.event.raw_id)
      .first<{ r2_key: string }>();
    if (!obj?.r2_key) continue;
    const body = await getRawJson(env, obj.r2_key);
    if (!body) continue;
    try {
      const name = pickPersonName(email, [extractAttendees(JSON.parse(body) as Parameters<typeof extractAttendees>[0])]);
      if (!name) continue;
      await env.DB.prepare(
        `UPDATE calendar_attendee SET display_name = ?
         WHERE email = ? AND (display_name IS NULL OR trim(display_name) = '')`,
      )
        .bind(name, email)
        .run();
      return name;
    } catch {
      continue;
    }
  }
  return null;
}

api.get("/meetings/by-attendee", async (c) => {
  const email = normalizeEmail(c.req.query("email") ?? "");
  if (!email) return c.json({ error: "email is required" }, 400);
  const path = `/api/people/${encodeURIComponent(email)}/meetings`;
  const params = new URLSearchParams();
  for (const key of ["days", "start", "end"]) {
    const value = c.req.query(key);
    if (value) params.set(key, value);
  }
  const qs = params.size ? `?${params.toString()}` : "";
  return c.redirect(`${path}${qs}`, 307);
});

api.post("/reconcile", async (c) => {
  const instance = await c.env.RECONCILE.create({
    id: `reconcile-manual-${Date.now()}`,
    params: { trigger: "manual" },
  });
  return c.json({ workflowId: instance.id });
});
