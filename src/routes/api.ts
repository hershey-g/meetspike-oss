import { Hono } from "hono";
import { history } from "./history.ts";
import type { Env } from "../env.ts";
import { displayTitle, sandboxMode } from "../env.ts";
import { getGoogleTokens, getOuraTokens, getWhoopTokens } from "../lib/tokens.ts";
import { activeWearableInfo, wearableChoice, wearableInfo, whoopWebHrActive } from "../lib/wearable.ts";
import { displayedSources, displayWearableInfo, loadSourceDisplay, type DisplayWearableInfo, type SourceDisplay } from "../lib/source-display.ts";
import { ingestWhoopFixtures } from "../sources/whoop/ingest.ts";
import { WHOOP_START_PATH } from "../sources/whoop/endpoints.ts";
import { whoopCallback } from "./whoop.ts";
import { setupStatus } from "./setup.ts";
import { loadTimeZone, upsertCalendarEvent } from "../lib/db.ts";
import { SOURCE_GOOGLE, SOURCE_OURA, SOURCE_WHOOP, type CalendarEventRow } from "../types.ts";
import { ingestFixtures } from "../sources/oura/ingest.ts";
import { addUtcDays, formatUtcDay } from "../sources/oura/endpoints.ts";
import { calendarDayInZone, DEFAULT_TIME_ZONE, addCalendarDays, localDayRangeUtc, weekBoundsMonday } from "../lib/time.ts";
import { applyOverrides, exclusionClause, loadExclusionRules, openRangeOverrides, overrideJson, overridesAround, type OverrideScopeHandle } from "../lib/meeting-override.ts";
import { ingestCalendarFixtures, syncCalendarIncremental, syncCalendarWindow } from "../sources/calendar/ingest.ts";
import { calendars } from "./calendars.ts";
import { GoogleAuthError } from "../sources/calendar/client.ts";
import {
  loadAttendeeDisplayName,
  loadCalendarEvents,
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
} from "../sources/calendar/meetings.ts";
import { parseDayRange, queryDailyMetrics } from "../lib/daily-metrics.ts";
import { isDateRangeError, isValidDay, parseDateRange, validateDateRange } from "../lib/date-range.ts";
import { buildRangeBriefing } from "../sources/calendar/range.ts";
import { joinMeetings, type OuraDaySlice } from "../sources/calendar/join.ts";
import {
  INSIGHTS_DEFAULT_DAYS,
  INSIGHTS_HIT_LIMIT,
  buildBaseline,
  parseInsightsDays,
  rankHits,
  toInsightMeeting,
} from "../lib/insights.ts";
import { HR_METHOD_NOTE, type MeetingHrStress } from "../lib/heartrate.ts";
import { loadDayHrSeries } from "../lib/heartrate-archive.ts";
import { getRawJson } from "../lib/r2.ts";
import { extractAttendees, normalizeEmail, parseAttendeesJson, pickPersonName, summarizePerson } from "../lib/people.ts";
import { readAdminSecret, timingSafeEqual } from "../lib/secret.ts";
import { extractPlaudSpeakers, planPlaudIngest } from "../sources/plaud/project.ts";
import { cacheNames, matchSpeakersToAttendees, resolvePayloadNames, type PlaudSpeaker } from "../lib/person-names.ts";
import type { Attendee } from "../lib/people.ts";
import { loadHistoryStart, parseHistoryRange } from "../lib/history-range.ts";
import { loadPeopleHistory } from "../lib/people-history.ts";
import { searchPeople } from "../lib/people-search.ts";
import { ask } from "./ask.ts";
import { meetingLive, whoopWeb } from "./whoop-web.ts";
import { MANUAL_MIN_INTERVAL_MS, syncRecentWhoop } from "../sources/whoop/recent.ts";
import { meetingHrDetail, toInput, type EventRow } from "../sources/whoop-web/fill.ts";
import { loadOuraMeetingHr, loadSelectedMeetingHr, saveMeetingHrSources, selectMeetingHr, hasFullMeetingHr, DUAL_HR_NOTE } from "../lib/meeting-hr.ts";
import { fetchWindow, meetingLimitS } from "../sources/whoop-web/meeting-hr.ts";
import { loadWearableStatuses } from "../lib/wearable-status.ts";
import { syncRecentOura } from "../sources/oura/recent.ts";
import { buildDayRows, buildUsual, costliestDays, heavyEffect, peopleOnHeavyDays } from "../lib/usual.ts";
import { sourceDisplay } from "./source-display.ts";
import { downsampleSeries } from "../lib/downsample.ts";
import { loadCompanyContext, resolvePayloadCompanies } from "../lib/companies.ts";
import { companyRoutes, personMeetingRow } from "./companies.ts";
import { overrideRoute } from "./override.ts";

export const api = new Hono<{ Bindings: Env }>();

api.route("/meetings", meetingLive);
api.route("/meetings", overrideRoute);
api.route("/history", history);
api.route("/settings/source-display", sourceDisplay);
// Google accounts and the calendars chosen in each (multi-account calendar sync).
api.route("/calendars", calendars);

/** GET routes whose JSON carries attendees or people. */
const NAMED_ROUTES = /\/(view|meetings|briefing|people|companies|insights)(\/|$)/;
const DISPLAY_ROUTES = /\/(view|meetings|briefing|people|companies|insights|metrics|sleep|health)(\/|$)/;

/**
 * Show names, not addresses: after a meetings/people route answers, fill every
 * empty attendee `name` from other meetings or the person_name cache (see
 * src/lib/person-names.ts for the order). Then tag every `attendees` list
 * with its `companies` (src/lib/companies.ts). Never fails the response.
 */
api.use("*", async (c, next) => {
  if (c.req.method === "GET" && DISPLAY_ROUTES.test(c.req.path)) c.header("Cache-Control", "private, no-store");
  await next();
  if (c.req.method !== "GET" || !NAMED_ROUTES.test(c.req.path) || c.res.status !== 200 || /\/(people|companies)\/search$/.test(c.req.path)) return;
  if (!(c.res.headers.get("content-type") ?? "").includes("application/json")) return;
  try {
    const payload = (await c.res.clone().json()) as unknown;
    const filled = await resolvePayloadNames(c.env.DB, payload).catch(() => 0);
    const tagged = await resolvePayloadCompanies(c.env.DB, payload).catch(() => 0);
    if (!filled && !tagged) return;
    const headers = new Headers(c.res.headers);
    headers.delete("content-length");
    c.res = new Response(JSON.stringify(payload), { status: c.res.status, headers });
  } catch {
    /* keep the original response */
  }
});

// Chat with your data, with the user's own Claude API key.
api.route("/ask", ask);

// WHOOP web heart rate: status, pasted token, backfill (WHOOP_WEB_HR).
api.route("/whoop-web", whoopWeb);

async function dashboardWearable(env: Env, display?: SourceDisplay): Promise<DisplayWearableInfo> {
  display ??= await loadSourceDisplay(env);
  const [source] = displayedSources(env, display);
  if (!source) return displayWearableInfo(null);
  const whoopWebHr = display.whoop && whoopWebHrActive(env);
  const primary = wearableInfo(source, { whoopWebHr });
  const ouraHr = display.oura && (primary.ouraHr || activeWearableInfo(env).ouraHr || Boolean(
    await env.DB.prepare("SELECT 1 FROM raw_object WHERE source = 'oura' AND endpoint = 'heartrate' LIMIT 1").first(),
  ));
  return {
    ...primary, ouraHr, whoopWebHr, hasIntradayHr: ouraHr || whoopWebHr,
    hrSource: whoopWebHr ? "whoop_web" : ouraHr ? "oura_ring" : null,
  };
}

/** The words briefing and insight copy need, taken from the active wearable. */
function labelsFor(w: DisplayWearableInfo): BriefingLabels {
  return {
    provider: w.label,
    readiness: w.readinessLabel.toLowerCase(),
    strain: w.strainLabel ? w.strainLabel.toLowerCase() : null,
    intradayHr: w.hasIntradayHr,
    hrProvider: w.whoopWebHr ? (w.ouraHr ? "WHOOP or Oura" : "WHOOP") : w.ouraHr ? "Oura" : null,
  };
}

function methodNoteFor(w: DisplayWearableInfo): string {
  if (w.whoopWebHr && w.ouraHr) return DUAL_HR_NOTE;
  return w.ouraHr ? HR_METHOD_NOTE : w.note;
}

async function meetingHrMap(
  env: Env, w: DisplayWearableInfo, events: CalendarEventRow[], tz: string, overrides?: OverrideScopeHandle,
) {
  const inputs = events.map((event) => ({
    id: event.id,
    startUtc: event.start_utc,
    endUtc: event.end_utc,
    day: event.day,
    ...(event.override?.timesChanged ? { effective: true as const } : {}),
  }));
  const set = overrides && w.whoopWebHr ? await overrides.ready : null;
  return loadSelectedMeetingHr(env, w, inputs, tz, set?.size ? (id) => set.isExcluded(id) : undefined);
}

/** Per-meeting detail uses the same source selection as the list views. */
/** Most points the meeting detail answers with, however many were recorded. */
const SERIES_MAX = 600;

api.get("/meetings/:id/hr", async (c) => {
  const env = c.env;
  const w = await dashboardWearable(env);
  if (!w.hasIntradayHr) return c.json({ error: "per-meeting detail is unavailable", enabled: false }, 404);
  const id = c.req.param("id");
  const calendarEvent = await env.DB.prepare(
    "SELECT id, start_utc, end_utc, duration_s, title FROM calendar_event WHERE id = ? AND deleted_at IS NULL",
  ).bind(id).first<EventRow>();
  if (!calendarEvent) return c.json({ error: "meeting not found" }, 404);
  const overrides = await overridesAround(env.DB, calendarEvent.start_utc);
  const [event] = applyOverrides([calendarEvent], overrides, { includeExcluded: true });
  // A meeting the owner left out has no chart and no score. The override says how to undo it.
  if (event.override?.excluded) return c.json({ error: "meeting is left out", excluded: true, override: overrideJson(event.override) }, 404);
  const whoop = w.whoopWebHr ? await meetingHrDetail(env, id, { fill: c.req.query("fill") !== "0", overrides }) : null;
  const tz = whoop?.timeZone ?? await loadTimeZone(env.DB).catch(() => DEFAULT_TIME_ZONE);
  const meeting = toInput(event, tz);
  const canScore = event.duration_s > 0 && event.duration_s <= meetingLimitS(event.override?.timesChanged);
  const oura = w.ouraHr && canScore && !hasFullMeetingHr(whoop?.hrStress)
    ? (await loadOuraMeetingHr(env, [meeting], tz)).get(id) : undefined;
  const hr = selectMeetingHr(meeting, whoop?.hrStress, oura);
  await saveMeetingHrSources(env.DB, [meeting], new Map([[id, hr]]));
  const win = fetchWindow(meeting.startUtc, meeting.endUtc);
  const detail = {
    ok: true,
    enabled: true,
    meetingId: id,
    title: event.title,
    timeZone: tz,
    window: { startUtc: meeting.startUtc, endUtc: meeting.endUtc, fetchStartUtc: win.startUtc, fetchEndUtc: win.endUtc },
    ...(event.override ? { override: overrideJson(event.override) } : {}),
    ...whoop,
    hrStress: hr,
    // The chart never needs more than SERIES_MAX points. The scoring numbers
    // above were computed from the full data. WHOOP points carry no `source`,
    // so the meeting's provider decides where a gap splits the line.
    series: downsampleSeries(hr.source === "WHOOP" ? whoop?.series ?? hr.series : hr.series, SERIES_MAX, {
      fallbackSource: hr.source,
    }),
    baseline: hr.source === "WHOOP" ? whoop?.baseline ?? null : null,
    stress: whoop?.stress ?? null,
    message: hr.coverage === "ok" ? null : w.ouraHr ? "No heart rate for this meeting." : whoop?.message,
  };
  return c.json(detail);
});

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
  const display = await loadSourceDisplay(c.env);
  const w = await dashboardWearable(c.env, display);
  // One D1 round trip for every count, the last sync and the date span, run
  // alongside the token reads, instead of ~14 queries one after another.
  const db = c.env.DB;
  const [batch, strainCount, wearables, google] = await Promise.all([
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
    loadWearableStatuses(c.env, display),
    getGoogleTokens(c.env),
  ]);
  const counts: Record<string, number> = {};
  tables.forEach((t, i) => {
    counts[t] = (batch[i].results?.[0] as { n?: number } | undefined)?.n ?? 0;
  });
  if (strainCount != null) counts.daily_strain = strainCount;
  const last = (batch[tables.length].results?.[0] ?? null) as { created_at: string; status: string; trigger: string } | null;
  const range = (batch[tables.length + 1].results?.[0] ?? null) as { min: string | null; max: string | null } | null;
  const primary = wearables.find((entry) => entry.source === (w.source ?? wearableChoice(c.env).source));
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
    wearables,
    sourceDisplay: display,
    token: { present: primary?.connected ?? false, expiresAt: primary?.expiresAt ?? null },
    google: {
      present: Boolean(google),
      expiresAt: google?.expires_at ?? null,
    },
  });
});

api.get("/sleep", async (c) => {
  const [source] = displayedSources(c.env, await loadSourceDisplay(c.env));
  if (!source) return c.json([]);
  const limit = Math.min(Number(c.req.query("limit") ?? "30"), 90);
  const rows = await c.env.DB.prepare(
    `SELECT * FROM daily_sleep WHERE source = ? ORDER BY day DESC LIMIT ?`,
  )
    .bind(source, limit)
    .all();
  return c.json(rows.results);
});

type BackfillMode = "fixtures" | "sandbox" | "production";

api.post("/backfill", async (c) => {
  const body = ((await c.req.json().catch(() => null)) ?? {}) as {
    mode?: BackfillMode;
    source?: string;
    startDay?: string;
    endDay?: string;
  };
  if (body.source != null && body.source !== SOURCE_WHOOP && body.source !== SOURCE_OURA) {
    return c.json({ error: "source must be oura or whoop" }, 400);
  }
  const source = body.source ?? activeWearableInfo(c.env).source;
  if (body.mode != null && !["fixtures", "sandbox", "production"].includes(body.mode)) {
    return c.json({ error: "invalid backfill mode" }, 400);
  }
  const whoop = source === SOURCE_WHOOP;
  const mode = body.mode ?? (whoop || !sandboxMode(c.env) ? "production" : "sandbox");
  if (mode === "fixtures") {
    const tally = whoop ? await ingestWhoopFixtures(c.env, 21) : await ingestFixtures(c.env, 21);
    return c.json({ mode, ...(whoop ? { wearable: source } : {}), ...tally });
  }
  const endDay = body.endDay ?? formatUtcDay(new Date());
  if (!isValidDay(endDay)) return c.json({ error: "endDay must be a valid YYYY-MM-DD date" }, 400);
  const earliest = addUtcDays(endDay, -30);
  const startDay = body.startDay ?? earliest;
  if (!isValidDay(startDay) || startDay > endDay || startDay < earliest) {
    return c.json({ error: "Use a window of 31 days or fewer. Full history is available at /api/history/backfill." }, 400);
  }
  if (whoop) {
    if (mode === "sandbox") return c.json({ error: 'WHOOP has no sandbox. Use mode "fixtures" or "production".' }, 400);
    if (!(await getWhoopTokens(c.env))) return c.json({ error: `no whoop tokens — connect WHOOP at ${WHOOP_START_PATH}` }, 401);
  } else if ((mode === "sandbox") !== sandboxMode(c.env)) {
    return c.json({ error: "Backfill mode must match OURA_SANDBOX" }, 400);
  }
  const instance = await c.env.BACKFILL.create({
    id: `backfill-${whoop ? source : mode}-${startDay}-${endDay}-${Date.now()}`,
    params: { source, mode, startDay, endDay, trigger: "manual" },
  });
  return c.json({ mode, ...(whoop ? { wearable: source } : {}), workflowId: instance.id, startDay, endDay });
});

api.post("/calendar/sync", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    mode?: "live" | "fixtures";
    startDay?: string;
    endDay?: string;
    /** Ignore the stored sync token and re-list the whole window. */
    full?: boolean;
  };
  const mode = body.mode ?? "live";
  if (mode === "fixtures") {
    const tally = await ingestCalendarFixtures(c.env);
    return c.json({ mode, ...tally });
  }
  const google = await getGoogleTokens(c.env);
  if (!google) {
    // Not 401: the app reads 401 as "Cloudflare Access sign-in needed".
    return c.json(
      { error: "Google Calendar is not connected — connect it at /auth/google/start", needsGoogle: true },
      409,
    );
  }
  try {
    if (body.startDay || body.endDay) {
      // An explicit window: re-list exactly those days (backfill / repair).
      const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
      const today = calendarDayInZone(new Date().toISOString(), tz);
      const endDay = body.endDay ?? today;
      const startDay = body.startDay ?? addCalendarDays(endDay, -14);
      const tally = await syncCalendarWindow(c.env, { start: startDay, end: endDay }, "manual");
      return c.json({ mode, sync: "window", startDay, endDay, ...tally, syncedAt: new Date().toISOString() });
    }
    const r = await syncCalendarIncremental(c.env, "manual", { force: body.full === true });
    const { mode: sync, ...rest } = r;
    return c.json({ mode, sync, ...rest });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    if (err instanceof GoogleAuthError || /no google tokens|refresh failed|no refresh_token/.test(message)) {
      return c.json({ error: "Google sign-in expired — reconnect Google Calendar in Setup.", needsGoogle: true }, 409);
    }
    return c.json({ error: `Google Calendar sync failed: ${message}` }, 502);
  }
});

type RefreshPart = { ok: boolean; error?: string; [k: string]: unknown };

/** Calendar part of a refresh. Same rules and messages as POST /calendar/sync. */
async function refreshCalendar(env: Env, full: boolean): Promise<RefreshPart> {
  if (!(await getGoogleTokens(env))) {
    return { ok: false, needsGoogle: true, error: "Google Calendar is not connected" };
  }
  try {
    const { mode: sync, ...rest } = await syncCalendarIncremental(env, "manual", { force: full });
    return { ok: true, sync, ...rest };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    if (err instanceof GoogleAuthError || /no google tokens|refresh failed|no refresh_token/.test(message)) {
      return { ok: false, needsGoogle: true, error: "Google sign-in expired. Reconnect Google Calendar in Setup." };
    }
    return { ok: false, error: `Google Calendar sync failed: ${message}` };
  }
}

/** "whoop 401: {...}" becomes "WHOOP answered HTTP 401": the app needs the status, not WHOOP's body. */
function shortWhoopError(message: string): string {
  const m = /^whoop (?:refresh failed )?(\d{3})/.exec(message);
  if (m) return `WHOOP answered HTTP ${m[1]}`;
  return message.length > 160 ? `${message.slice(0, 157)}...` : message;
}

/** WHOOP part: today's sleep, recovery and strain from the developer API. */
async function refreshWhoop(env: Env): Promise<RefreshPart> {
  const r = await syncRecentWhoop(env, { trigger: "manual", minIntervalMs: MANUAL_MIN_INTERVAL_MS });
  if (!r.ok) return { ok: false, error: shortWhoopError(r.error) };
  if ("skipped" in r) return { ok: true, skipped: r.skipped };
  return { ok: true, written: r.written, unchanged: r.unchanged, window: r.window };
}

/** Longest a refresh waits on one source before answering without it. */
const REFRESH_PART_TIMEOUT_MS = 15_000;

/**
 * Run one part of a refresh. The work is handed to waitUntil, so closing the
 * app mid-pull cannot cut it off between WHOOP rotating a token and the new
 * one being stored. The answer only waits so long; slow work still finishes.
 */
function refreshPart(c: { executionCtx: { waitUntil(p: Promise<unknown>): void } }, work: Promise<RefreshPart>): Promise<RefreshPart> {
  const safe = work.catch((err) => ({ ok: false, error: err instanceof Error ? err.message : String(err) }) as RefreshPart);
  try {
    c.executionCtx.waitUntil(safe);
  } catch {
    /* no execution context (tests): just await it */
  }
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<RefreshPart>((resolve) => {
    // Not a failure: the work carries on under waitUntil and lands on the next redraw.
    timer = setTimeout(() => resolve({ ok: true, pending: true }), REFRESH_PART_TIMEOUT_MS);
  });
  return Promise.race([safe, timeout]).finally(() => {
    if (timer !== undefined) clearTimeout(timer);
  });
}

/**
 * Sync calendar and connected wearables independently. An explicit full
 * refresh re-lists the calendar window. A redraw reads the stored meeting HR.
 */
api.post("/refresh", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as { full?: unknown };
  const [calendar, whoop, oura] = await Promise.all([
    refreshPart(c, refreshCalendar(c.env, body.full === true)),
    refreshPart(c, refreshWhoop(c.env)),
    refreshPart(c, syncRecentOura(c.env, "manual")),
  ]);
  return c.json({ calendar, whoop, oura, syncedAt: new Date().toISOString() }, { headers: { "Cache-Control": "no-store" } });
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
  const overrides = openRangeOverrides(c.env.DB, from, to, tz);
  const w = await dashboardWearable(c.env);
  const joined = await loadJoinedMeetings(c.env.DB, from, to, tz, w.source, { overrides });
  const hrByMeetingId = await meetingHrMap(c.env, w, joined.map(({ event }) => event), tz, overrides);
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
  const w = await dashboardWearable(c.env);
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

  const requested = c.req.query("source");
  if (requested != null && requested !== SOURCE_WHOOP && requested !== SOURCE_OURA) {
    return c.json({ error: "source must be oura or whoop" }, 400);
  }
  const display = await loadSourceDisplay(c.env);
  const w = requested ? displayWearableInfo(display[requested] ? requested : null) : await dashboardWearable(c.env, display);
  const days = w.source ? await queryDailyMetrics(c.env.DB, parsed.start, parsed.end, w.source, {
    strain: w.strainLabel != null,
  }) : [];
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
  const start = c.req.query("start");
  const end = c.req.query("end");
  const days = c.req.query("days");
  const all = days === "all" && !hasSpanQuery(start, end);
  const w = await dashboardWearable(c.env);
  const from = all ? await loadHistoryStart(c.env.DB, w.source, tz, today) : start;
  const range = parseHistoryRange({ start: from, end: all ? today : end }, today, parseInsightsDays(days));
  if (isDateRangeError(range)) return c.json({ error: range.error }, 400);
  return c.json(await insightsJson(c.env, w, range.start, range.end, range.spanDays, all || hasSpanQuery(start, end), tz));
});

async function insightsJson(
  env: Env, w: DisplayWearableInfo, from: string, to: string, windowDays: number, spanned: boolean, tz: string,
  loaded?: Promise<{ events: CalendarEventRow[]; hr: Map<string, MeetingHrStress> }>,
  overrides?: OverrideScopeHandle,
) {
  const labels = labelsFor(w);
  const scope = loaded ? undefined : overrides ?? openRangeOverrides(env.DB, from, to, tz);
  const [metricDays, events] = await Promise.all([
    w.source ? queryDailyMetrics(env.DB, from, addCalendarDays(to, 1), w.source) : [],
    loaded ? loaded.then((data) => data.events) : loadCalendarEvents(env.DB, from, to, tz, { overrides: scope }),
  ]);
  const baseline = buildBaseline(metricDays, windowDays, spanned ? { from, to } : undefined, labels);
  const hrByMeetingId = loaded ? (await loaded).hr : await meetingHrMap(env, w, events, tz, scope);
  const hits = rankHits({
    days: metricDays,
    meetings: events.map(toInsightMeeting),
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

async function loadCalendarWindow(
  env: Env, w: DisplayWearableInfo, start: string, end: string, tz: string, overrides?: OverrideScopeHandle,
) {
  // The last day's next-morning score comes from the day after the range.
  const [all, slices] = await Promise.all([
    loadCalendarEvents(env.DB, start, end, tz, { overrides, includeExcluded: true }),
    loadOuraSlices(env.DB, start, addCalendarDays(end, 1), w.source),
  ]);
  // Meetings the owner left out stay out of every count and average. The day list still shows them so they can be undone.
  const events = all.filter((event) => !event.override?.excluded);
  const excluded = events.length === all.length ? [] : all.filter((event) => event.override?.excluded);
  return { events, excluded, ...slices };
}

async function dayBriefingJson(
  env: Env, w: DisplayWearableInfo, date: string, tz: string, overrides?: OverrideScopeHandle, listExcluded = false,
) {
  overrides ??= openRangeOverrides(env.DB, date, date, tz);
  const { events, excluded, byDay, contributors } = await loadCalendarWindow(env, w, date, date, tz, overrides);
  const joined = joinMeetings(events, byDay, contributors);
  const prior = sliceForDay(byDay, date);
  // No day strip without intraday heart-rate: `hr` comes back null and the UI shows day totals instead.
  const [hrByMeetingId, hrSeries] = await Promise.all([
    meetingHrMap(env, w, events, tz, overrides),
    w.ouraHr ? loadDayHrSeries(env, date, tz) : Promise.resolve(undefined),
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
    // Only the app's main view lists left-out meetings (so they can be undone). Every other briefing leaves them out.
    excluded: listExcluded ? excluded : undefined,
  });
  return { ...briefing, wearable: w, methodNote: methodNoteFor(w) };
}

async function rangeBriefingJson(env: Env, start: string, end: string, tz: string) {
  const w = await dashboardWearable(env);
  const overrides = openRangeOverrides(env.DB, start, end, tz);
  const { events, byDay, contributors } = await loadCalendarWindow(env, w, start, end, tz, overrides);
  const hr = await meetingHrMap(env, w, events, tz, overrides);
  return rangeJson(start, end, tz, w, { events, byDay, contributors, hr });
}

function rangeJson(start: string, end: string, tz: string, w: DisplayWearableInfo, data: {
  events: CalendarEventRow[];
  byDay: Map<string, OuraDaySlice>;
  contributors: Map<string, string | null>;
  hr: Map<string, MeetingHrStress>;
}) {
  return {
    ...buildRangeBriefing({
      start,
      end,
      timeZone: tz,
      joined: joinMeetings(data.events, data.byDay, data.contributors),
      recoveryByDay: data.byDay,
      hrByMeetingId: data.hr,
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
  if (range.spanDays === 1) return c.json(await dayBriefingJson(c.env, await dashboardWearable(c.env), range.start, tz));
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
  const display = await loadSourceDisplay(env);
  const w = await dashboardWearable(env, display);
  const usualFrom = addCalendarDays(end, -(USUAL_WINDOW_DAYS - 1));
  const windowFrom = start < usualFrom ? start : usualFrom;
  const single = spanDays === 1;

  const nextDay = addCalendarDays(end, 1);
  const [, otherSource] = displayedSources(env, display);
  // One read of the owner's meeting choices serves the window, the day list, the baselines and the hits.
  const hitsFrom = addCalendarDays(today, -(INSIGHTS_DEFAULT_DAYS - 1));
  const overrides = single
    ? openRangeOverrides(env.DB, hitsFrom < windowFrom ? hitsFrom : windowFrom, today > end ? today : end, tz)
    : openRangeOverrides(env.DB, windowFrom, end, tz);
  const window = loadCalendarWindow(env, w, windowFrom, end, tz, overrides);
  const selectedData = single ? undefined : window.then(async ({ events, byDay, contributors }) => {
    const selectedEvents = events.filter((event) => event.day >= start);
    const hr = await meetingHrMap(env, w, selectedEvents, tz, overrides);
    return { events: selectedEvents, byDay, contributors, hr };
  });
  const [main, primary, secondary, hits, status] = await Promise.all([
    selectedData ? selectedData.then((data) => rangeJson(start, end, tz, w, data)) : dayBriefingJson(env, w, start, tz, overrides, true),
    window,
    otherSource ? loadOuraSlices(env.DB, windowFrom, nextDay, otherSource) : null,
    // Ranking meetings by heart-rate only means something with heart-rate inside meetings.
    w.hasIntradayHr
      ? single
        ? insightsJson(env, w, hitsFrom, today, INSIGHTS_DEFAULT_DAYS, false, tz, undefined, overrides)
        : insightsJson(env, w, start, end, spanDays, true, tz, selectedData)
      : Promise.resolve(null),
    viewStatus(env, w, display),
  ]);

  const { events, byDay } = primary;
  const rows = buildDayRows(events, byDay, windowFrom, end, tz);
  const morningScores = [
    ...(w.source ? [{ source: w.source, rows, byDay }] : []),
    ...(otherSource && secondary ? [{
      source: otherSource,
      rows: buildDayRows(events, secondary.byDay, windowFrom, end, tz),
      byDay: secondary.byDay,
    }] : []),
  ].map((entry) => {
    const provider = wearableInfo(entry.source);
    const points = entry.rows.filter((r) => r.day >= start).flatMap((r) =>
      r.morning?.readinessScore == null ? [] : [r.morning.readinessScore],
    );
    return {
      source: entry.source,
      label: provider.label,
      readinessLabel: provider.readinessLabel,
      morning: entry.byDay.get(start)?.readinessScore ?? null,
      nextMorning: entry.byDay.get(nextDay)?.readinessScore ?? null,
      average: points.length ? Math.round(points.reduce((a, b) => a + b, 0) / points.length) : null,
      usual: buildUsual(entry.rows.filter((r) => r.day >= usualFrom)),
    };
  });
  const usualRows = rows.filter((r) => r.day >= usualFrom);
  const selected = rows.filter((r) => r.day >= start);
  // A single day is too few to compare, so the day view compares over the usual window.
  const basis = single ? usualRows : selected;

  return c.json({
    ok: true,
    today,
    start,
    end,
    spanDays,
    timeZone: tz,
    wearable: w,
    status,
    morningScores,
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
  });
});

const USUAL_WINDOW_DAYS = 28;

/** What the menu and banners need: connections and the last sync. No table counts. */
async function viewStatus(env: Env, w: DisplayWearableInfo, display: SourceDisplay) {
  const [wearables, google, last] = await Promise.all([
    loadWearableStatuses(env, display),
    getGoogleTokens(env),
    env.DB.prepare(`SELECT created_at, status FROM sync_log ORDER BY created_at DESC LIMIT 1`)
      .first<{ created_at: string; status: string }>()
      .catch(() => null),
  ]);
  return {
    displayTitle: displayTitle(env),
    sandbox: w.source === SOURCE_OURA && sandboxMode(env),
    wearables,
    sourceDisplay: display,
    wearableConnected: wearables.some((s) => s.connected),
    googleConnected: Boolean(google),
    lastSync: last ?? null,
  };
}

api.get("/briefing/week", async (c) => {
  const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
  const date = c.req.query("date") ?? calendarDayInZone(new Date().toISOString(), tz);
  if (!isValidDay(date)) return c.json({ error: "date must be a valid YYYY-MM-DD date" }, 400);
  const { start, end } = weekBoundsMonday(date);
  const overrides = openRangeOverrides(c.env.DB, start, end, tz);
  const w = await dashboardWearable(c.env);
  const joined = await loadJoinedMeetings(c.env.DB, start, end, tz, w.source, { overrides });
  const hrByMeetingId = await meetingHrMap(c.env, w, joined.map(({ event }) => event), tz, overrides);
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
  const namesLearned = await learnPlaudSpeakerNames(c.env.DB, planned.accept, extractPlaudSpeakers(body));
  return c.json({
    ok: true,
    written,
    skipped,
    namesLearned,
    rejected: planned.reject.length,
    truncated: planned.truncated,
    timeZone: tz,
    results,
  });
});

/**
 * (d) in the name order: when a Plaud recording overlaps Google meetings and
 * a speaker name maps cleanly onto one of their attendees, cache that name.
 */
async function learnPlaudSpeakerNames(
  db: D1Database,
  rows: Array<{ id: string; start_utc: string; end_utc: string }>,
  speakersById: Map<string, PlaudSpeaker[]>,
): Promise<number> {
  let learned = 0;
  for (const row of rows) {
    const speakers = speakersById.get(row.id);
    if (!speakers?.length) continue;
    const { results } = await db
      .prepare(
        `SELECT attendees_json FROM calendar_event
         WHERE source = ? AND deleted_at IS NULL AND start_utc < ? AND end_utc > ?`,
      )
      .bind(SOURCE_GOOGLE, row.end_utc, row.start_utc)
      .all<{ attendees_json: string | null }>();
    const byEmail = new Map<string, Attendee>();
    for (const r of results ?? []) {
      for (const a of parseAttendeesJson(r.attendees_json)) {
        const prev = byEmail.get(a.email);
        if (!prev || (!prev.name && a.name)) byEmail.set(a.email, a);
      }
    }
    const matched = matchSpeakersToAttendees([...byEmail.values()], speakers);
    if (matched.size) {
      learned += await cacheNames(
        db,
        [...matched].map(([email, name]) => ({ email, name })),
        "plaud",
      );
    }
  }
  return learned;
}

api.get("/people", async (c) => {
  const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
  const today = calendarDayInZone(new Date().toISOString(), tz);
  const range = parseHistoryRange({ start: c.req.query("start"), end: c.req.query("end") }, today, INSIGHTS_DEFAULT_DAYS);
  if (isDateRangeError(range)) return c.json({ error: range.error }, 400);
  const sourceDisplay = await loadSourceDisplay(c.env);
  const [source] = displayedSources(c.env, sourceDisplay);
  const wearable = displayWearableInfo(source ?? null);
  const summary = await loadPeopleHistory(c.env.DB, range.start, range.end, tz, wearable.source);
  return c.json({ ok: true, ...range, wearable, sourceDisplay, ...summary });
});

api.get("/people/search", async (c) => {
  const query = (c.req.query("q") ?? "").trim().slice(0, 120);
  try {
    const people = await searchPeople(c.env.DB, query, (candidates) => withoutLeftOut(c.env.DB, candidates));
    return c.json({ ok: true, people }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    if (error instanceof Error && /no such table: (?:people_search(?:_trigrams)?|people_directory)\b/.test(error.message)) {
      return c.json({ error: "People search is unavailable until the database is updated." }, 503);
    }
    throw error;
  }
});

/**
 * Keep the people met in at least one meeting that still counts. A person met
 * only in meetings the owner left out (or in a recording of one) is dropped.
 * Same list back, with no extra query, when nothing is left out.
 */
async function withoutLeftOut<T extends { email: string }>(db: D1Database, people: T[]): Promise<T[]> {
  const left = exclusionClause(await loadExclusionRules(db), "e", 2);
  if (!left || !people.length) return people;
  const { results } = await db.prepare(
    `SELECT DISTINCT a.email FROM calendar_attendee a JOIN calendar_event e ON e.id = a.event_id AND e.source = a.source
     WHERE a.self = 0 AND e.deleted_at IS NULL AND a.email IN (SELECT value FROM json_each(?1))${left.sql}`,
  ).bind(JSON.stringify(people.map((p) => p.email)), ...left.params).all<{ email: string }>();
  const kept = new Set((results ?? []).map((r) => r.email));
  return people.filter((p) => kept.has(p.email));
}

api.get("/people/:email/meetings", async (c) => {
  const email = normalizeEmail(c.req.param("email") ?? "");
  if (!email) return c.json({ error: "email is required" }, 400);
  const tz = await loadTimeZone(c.env.DB).catch(() => DEFAULT_TIME_ZONE);
  const today = calendarDayInZone(new Date().toISOString(), tz);
  const range = parseHistoryRange(
    { start: c.req.query("start"), end: c.req.query("end") }, today, parseInsightsDays(c.req.query("days")),
  );
  if (isDateRangeError(range)) return c.json({ error: range.error }, 400);
  const { start: from, end: to } = range;
  const sourceDisplay = await loadSourceDisplay(c.env);
  const overrides = openRangeOverrides(c.env.DB, from, to, tz);
  const w = await dashboardWearable(c.env, sourceDisplay);
  const { joined } = await loadJoinedMeetingsByAttendee(c.env.DB, email, from, to, tz, w.source, { overrides });
  const [name, hrByMeetingId, companyContext] = await Promise.all([
    resolvePersonName(c.env, email, joined),
    meetingHrMap(c.env, w, joined.map(({ event }) => event), tz, overrides),
    loadCompanyContext(c.env.DB),
  ]);
  const compact = c.req.query("compact") === "1";
  const meetings = joined
    .map((row) => personMeetingRow(row, hrByMeetingId.get(row.event.id) ?? null, compact, companyContext))
    .sort((a, b) => b.startUtc.localeCompare(a.startUtc));
  const trend = summarizePerson(meetings);
  const trendsByHrSource = (["WHOOP", "Oura", "WHOOP + Oura"] as const).flatMap((source) => {
    const sourced = meetings.filter((m) => m.hrStress?.source === source);
    return sourced.length ? [{ source, ...summarizePerson(sourced) }] : [];
  });
  return c.json(
    {
      ok: true,
      email,
      name,
      from,
      to,
      timeZone: tz,
      wearable: w,
      sourceDisplay,
      grain: grainNote(labelsFor(w)),
      methodNote: methodNoteFor(w),
      trend,
      trendsByHrSource,
      meetings,
    },
  );
});

// Companies: the same pages as people, grouped by email domain (src/routes/companies.ts).
api.route("/companies", companyRoutes({ dashboardWearable, meetingHrMap, labelsFor, methodNoteFor }));

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
