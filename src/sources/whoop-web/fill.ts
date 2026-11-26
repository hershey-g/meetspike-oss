import { whoopWebWorkerLoginFlag, type Env } from "../../env.ts";
import { whoopWebHrActive } from "../../lib/wearable.ts";
import { writeSyncLog } from "../../lib/synclog.ts";
import { loadTimeZone } from "../../lib/db.ts";
import { addCalendarDays, calendarDayInZone, DEFAULT_TIME_ZONE } from "../../lib/time.ts";
import { SOURCE_WHOOP } from "../../types.ts";
import {
  applyOverrides,
  loadOverridesForIds,
  overridesAround,
  type OverrideSet,
  type ResolvedOverride,
} from "../../lib/meeting-override.ts";
import type { MeetingHrStress } from "../../lib/heartrate.ts";
import { fetchHeartRate, fetchStressDay, WhoopWebAuthError, webApiCanAuth, type WhoopWebDeps, type WhoopWebResult } from "./web-api/index.ts";
import type { ParsedHr, ParsedStressDay } from "./parse.ts";
import {
  BACKFILL_MAX_DAYS,
  CRON_LOOKBACK_DAYS,
  REQUEST_PACING_MS,
  RUN_REQUEST_BUDGET,
  SOURCE_WHOOP_WEB,
  WHOOP_WEB_BACKFILL_KEY,
} from "./constants.ts";
import {
  BASELINE_DAYS,
  baselineWindows,
  buildMeetingDetail,
  fetchWindow,
  isStale,
  MAX_MEETING_S,
  meetingLimitS,
  meetingDays,
  scoreWhoopWebMeeting,
  stressDayWindow,
  whoopWebNoHr,
  type FillOutcome,
  type MeetingHrDetail,
  type MeetingInput,
} from "./meeting-hr.ts";
import {
  getCachedHr,
  getCachedStressDays,
  getDetailHr,
  listCachedHrMetadata,
  listScoringHr,
  putCachedHr,
  putCachedStressDay,
  type CachedHrWindow,
} from "./store.ts";

export type FillEnv = Pick<
  Env,
    | "DB"
  | "TOKENS"
  | "WHOOP_WEB_EMAIL"
  | "WHOOP_WEB_PASSWORD"
  | "WHOOP_WEB_HR"
  | "WHOOP_WEB_WORKER_LOGIN"
  | "WEARABLE"
  | "OURA_CLIENT_ID"
  | "WHOOP_CLIENT_ID"
>;

/** The Worker's own deps: no password login unless WHOOP_WEB_WORKER_LOGIN is on (or a caller says otherwise). */
function workerDeps(env: FillEnv, deps: WhoopWebDeps): WhoopWebDeps {
  return { ...deps, passwordLogin: deps.passwordLogin ?? whoopWebWorkerLoginFlag(env) };
}

function nowOf(deps: WhoopWebDeps): number {
  return deps.now ? deps.now() : Date.now();
}

export async function logRun(
  env: Pick<Env, "DB">,
  row: { trigger: string; endpoint: string; status: "ok" | "partial" | "error"; written?: number; skipped?: number; errorText?: string | null; eventId?: string | null; windowStart?: string | null; windowEnd?: string | null },
): Promise<void> {
  await writeSyncLog(env as Env, {
    trigger: row.trigger,
    source: SOURCE_WHOOP_WEB,
    endpoint: row.endpoint,
    status: row.status,
    rowsWritten: row.written ?? 0,
    rowsSkipped: row.skipped ?? 0,
    errorText: row.errorText ?? null,
    eventId: row.eventId ?? null,
    windowStart: row.windowStart ?? null,
    windowEnd: row.windowEnd ?? null,
  }).catch(() => {});
}

/** True when there is a stored session or a way to log in; otherwise a run would only log noise. */
function canAuth(env: FillEnv, deps: WhoopWebDeps): Promise<boolean> {
  return webApiCanAuth(env, deps);
}

/**
 * Store one meeting's heart-rate answer as its whoop_web_hr row: ok / empty /
 * error, samples clipped to the window, earlier good samples kept when this
 * answer failed. Used by the Worker's direct WHOOP fetch. Returns the row with the
 * status that was stored (not the status of the answer), so counters match the table.
 */
export async function storeMeetingHr(
  env: Pick<Env, "DB">,
  meeting: MeetingInput,
  res: WhoopWebResult<ParsedHr>,
  fetchedAt: string,
): Promise<CachedHrWindow> {
  const win = fetchWindow(meeting.startUtc, meeting.endUtc);
  const row: CachedHrWindow = res.ok
    ? {
        eventId: meeting.id,
        windowStartUtc: win.startUtc,
        windowEndUtc: win.endUtc,
        status: "ok",
        points: res.value.points.filter(([t]) => t >= win.startMs && t <= win.endMs),
        errorText: null,
        fetchedAt,
      }
    : {
        eventId: meeting.id,
        windowStartUtc: win.startUtc,
        windowEndUtc: win.endUtc,
        status: "error",
        points: [],
        errorText: res.reason,
        fetchedAt,
      };
  if (row.status === "ok" && !row.points.length) row.status = "empty";
  // Keep good samples we already have if this attempt failed. Either way a failed attempt is written as
  // `failed`: a row marked "not fetched for this window" stays marked (raw.ts), so it is asked again.
  const prev = row.status === "error" ? await getCachedHr(env.DB, meeting.id) : null;
  if (prev && prev.status === "ok" && prev.windowStartUtc === win.startUtc && prev.windowEndUtc === win.endUtc) {
    const kept = { ...prev, fetchedAt };
    return { ...kept, status: await putCachedHr(env.DB, kept, true) };
  }
  // The status the row ended with (stored points inside the window can make an empty answer 'ok').
  return { ...row, status: await putCachedHr(env.DB, row, !res.ok) };
}

/** One heart-rate request for one meeting; stores ok / empty / error. Auth errors throw. */
export async function fillMeetingHr(
  env: FillEnv,
  meeting: MeetingInput,
  trigger: string,
  deps: WhoopWebDeps = {},
): Promise<{ outcome: "fetched" | "empty" | "error"; status: number }> {
  const win = fetchWindow(meeting.startUtc, meeting.endUtc);
  const res = await fetchHeartRate(env, win.startMs, win.endMs, deps);
  const row = await storeMeetingHr(env, meeting, res, new Date(nowOf(deps)).toISOString());
  if (!res.ok) {
    await logRun(env, {
      trigger,
      endpoint: "metrics/heart_rate",
      status: "error",
      errorText: res.reason,
      eventId: meeting.id,
      windowStart: win.startUtc,
      windowEnd: win.endUtc,
    });
    return { outcome: "error", status: res.status };
  }
  return { outcome: row.status === "ok" ? "fetched" : "empty", status: 200 };
}

/** Store one day's Stress Monitor answer, keeping an earlier good day when this one failed. Shared with ingest. */
export async function storeStressDay(
  env: Pick<Env, "DB">,
  day: string,
  res: WhoopWebResult<ParsedStressDay>,
  fetchedAt: string,
): Promise<"fetched" | "empty" | "error"> {
  if (!res.ok) {
    const prev = (await getCachedStressDays(env.DB, [day])).get(day);
    if (prev && prev.status === "ok") await putCachedStressDay(env.DB, { ...prev, fetchedAt });
    else {
      await putCachedStressDay(env.DB, {
        day,
        status: "error",
        points: [],
        currentLevel: null,
        peakLevel: null,
        minLevel: null,
        errorText: res.reason,
        fetchedAt,
      });
    }
    return "error";
  }
  const v = res.value;
  await putCachedStressDay(env.DB, {
    day,
    status: v.points.length || v.currentLevel != null ? "ok" : "empty",
    points: v.points,
    currentLevel: v.currentLevel,
    peakLevel: v.peakLevel,
    minLevel: v.minLevel,
    errorText: null,
    fetchedAt,
  });
  return v.points.length ? "fetched" : "empty";
}

/** One stress-bff request for one local day. Auth errors throw. */
export async function fillStressDay(
  env: FillEnv,
  day: string,
  timeZone: string,
  trigger: string,
  deps: WhoopWebDeps = {},
): Promise<{ outcome: "fetched" | "empty" | "error"; status: number }> {
  const res = await fetchStressDay(env, day, timeZone, deps);
  const outcome = await storeStressDay(env, day, res, new Date(nowOf(deps)).toISOString());
  if (!res.ok) {
    await logRun(env, { trigger, endpoint: "stress-bff", status: "error", errorText: res.reason, windowStart: day, windowEnd: day });
    return { outcome, status: res.status };
  }
  return { outcome, status: 200 };
}

export type EventRow = {
  id: string; start_utc: string; end_utc: string; duration_s: number; title: string | null;
  /** Set when the owner or the Mac changed this meeting (src/lib/meeting-override.ts). start_utc/end_utc are then the effective times. */
  override?: ResolvedOverride;
};

export function toInput(e: EventRow, timeZone: string): MeetingInput {
  return {
    id: e.id, startUtc: e.start_utc, endUtc: e.end_utc, day: calendarDayInZone(e.start_utc, timeZone),
    ...(e.override?.timesChanged ? { effective: true as const } : {}),
  };
}

/** Meetings that ended in the window. Ones the owner left out are skipped; changed times are the effective ones. */
export async function meetingsEndedBetween(db: D1Database, fromUtc: string, toUtc: string): Promise<EventRow[]> {
  const res = await db
    .prepare(
      `SELECT id, start_utc, end_utc, duration_s, title FROM calendar_event
       WHERE end_utc >= ? AND end_utc <= ? AND deleted_at IS NULL AND duration_s > 0 AND duration_s <= ?
       ORDER BY end_utc DESC`,
    )
    .bind(fromUtc, toUtc, MAX_MEETING_S)
    .all<EventRow>();
  const rows = res.results ?? [];
  if (!rows.length) return rows;
  return applyOverrides(rows, await loadOverridesForIds(db, rows.map((row) => row.id)))
    .filter((row) => row.duration_s > 0 && row.duration_s <= meetingLimitS(row.override?.timesChanged));
}

export type WhoopWebBackfill = { fromDay: string; requestedAt: string };

export async function readBackfill(env: Pick<Env, "TOKENS">): Promise<WhoopWebBackfill | null> {
  const raw = await env.TOKENS.get(WHOOP_WEB_BACKFILL_KEY);
  if (!raw) return null;
  try {
    const v = JSON.parse(raw) as WhoopWebBackfill;
    return /^\d{4}-\d{2}-\d{2}$/.test(v?.fromDay ?? "") ? v : null;
  } catch {
    return null;
  }
}

export type FillRunResult =
  | { skipped: "disabled" | "not_connected" }
  | {
      requests: number;
      hrFetched: number;
      hrEmpty: number;
      stressFetched: number;
      errors: number;
      remaining: number;
      stoppedBy: "done" | "budget" | "auth" | "rate_limited";
      backfillFromDay: string | null;
      authError?: string;
    };

/**
 * Fill meetings that ended in the last two days (or since an active
 * backfill's start day), newest first. At most `budget` WHOOP requests,
 * `pacingMs` apart. Stops on auth trouble or a 429. Never throws.
 */
export async function runWhoopWebFill(
  env: FillEnv,
  opts: { trigger: string; budget?: number; pacingMs?: number; lookbackDays?: number } = { trigger: "cron" },
  depsIn: WhoopWebDeps = {},
): Promise<FillRunResult> {
  const deps = workerDeps(env, depsIn);
  if (!whoopWebHrActive(env)) return { skipped: "disabled" };
  if (!(await canAuth(env, deps))) return { skipped: "not_connected" };
  const budget = opts.budget ?? RUN_REQUEST_BUDGET;
  const pacingMs = opts.pacingMs ?? REQUEST_PACING_MS;
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const now = nowOf(deps);
  const tz = await loadTimeZone(env.DB).catch(() => DEFAULT_TIME_ZONE);
  const today = calendarDayInZone(new Date(now).toISOString(), tz);
  const backfill = await readBackfill(env);
  let fromMs = now - (opts.lookbackDays ?? CRON_LOOKBACK_DAYS) * 86_400_000;
  if (backfill) fromMs = Math.min(fromMs, Date.parse(`${backfill.fromDay}T00:00:00Z`) - 86_400_000);

  const events = await meetingsEndedBetween(env.DB, new Date(fromMs).toISOString(), new Date(now).toISOString());
  const inputs = events.map((e) => toInput(e, tz));
  const cached = new Map(
    (await listCachedHrMetadata(env.DB, new Date(fromMs - 2 * 86_400_000).toISOString(), new Date(now + 60_000).toISOString())).map((r) => [r.eventId, r]),
  );
  const pending = inputs.filter((m) => isStale(cached.get(m.id) ?? null, fetchWindow(m.startUtc, m.endUtc), now));
  const days = [...new Set(pending.flatMap((m) => meetingDays(m.startUtc, m.endUtc, tz)))];
  const stressCached = await getCachedStressDays(env.DB, days);
  const stressDone = new Set<string>();

  let requests = 0;
  let hrFetched = 0;
  let hrEmpty = 0;
  let stressFetched = 0;
  let errors = 0;
  let done = 0;
  let stoppedBy: "done" | "budget" | "auth" | "rate_limited" = "done";
  let authError: string | undefined;
  const pace = async () => {
    if (requests > 0 && pacingMs > 0) await sleep(pacingMs);
  };

  try {
    outer: for (const m of pending) {
      for (const day of meetingDays(m.startUtc, m.endUtc, tz)) {
        if (stressDone.has(day) || day > today) continue;
        stressDone.add(day);
        if (!isStale(stressCached.get(day) ?? null, stressDayWindow(day, tz), now)) continue;
        if (requests >= budget) {
          stoppedBy = "budget";
          break outer;
        }
        await pace();
        requests += 1;
        const s = await fillStressDay(env, day, tz, opts.trigger, deps);
        if (s.outcome === "error") errors += 1;
        else if (s.outcome === "fetched") stressFetched += 1;
        if (s.status === 429) {
          stoppedBy = "rate_limited";
          break outer;
        }
      }
      if (requests >= budget) {
        stoppedBy = "budget";
        break;
      }
      await pace();
      requests += 1;
      const r = await fillMeetingHr(env, m, opts.trigger, deps);
      done += 1;
      if (r.outcome === "fetched") hrFetched += 1;
      else if (r.outcome === "empty") hrEmpty += 1;
      else errors += 1;
      if (r.status === 429) {
        stoppedBy = "rate_limited";
        break;
      }
    }
  } catch (err) {
    if (!(err instanceof WhoopWebAuthError)) throw err;
    stoppedBy = "auth";
    authError = err.message;
  }

  const remaining = pending.length - done;
  if (backfill && stoppedBy === "done") await env.TOKENS.delete(WHOOP_WEB_BACKFILL_KEY);
  await logRun(env, {
    trigger: opts.trigger,
    endpoint: "fill",
    status: stoppedBy === "auth" ? "error" : errors || remaining ? "partial" : "ok",
    written: hrFetched + stressFetched,
    skipped: hrEmpty,
    errorText: authError ?? (stoppedBy === "rate_limited" ? "WHOOP answered 429; stopped this run" : null),
    windowStart: new Date(fromMs).toISOString(),
    windowEnd: new Date(now).toISOString(),
  });
  return {
    requests,
    hrFetched,
    hrEmpty,
    stressFetched,
    errors,
    remaining,
    stoppedBy,
    backfillFromDay: backfill && stoppedBy !== "done" ? backfill.fromDay : null,
    ...(authError ? { authError } : {}),
  };
}

/** Admin: remember a backfill start day; the cron then widens its lookback until everything since is filled. */
export async function startBackfill(env: Pick<Env, "TOKENS">, days: number, now = Date.now(), timeZone = DEFAULT_TIME_ZONE): Promise<WhoopWebBackfill> {
  const n = Math.max(1, Math.min(BACKFILL_MAX_DAYS, Math.floor(days)));
  const today = calendarDayInZone(new Date(now).toISOString(), timeZone);
  const v: WhoopWebBackfill = { fromDay: addCalendarDays(today, -(n - 1)), requestedAt: new Date(now).toISOString() };
  await env.TOKENS.put(WHOOP_WEB_BACKFILL_KEY, JSON.stringify(v));
  return v;
}

/**
 * Per-meeting readings for list views, from the cache only (a page view
 * never calls WHOOP). Reads 14 extra days before the first meeting for
 * the baseline.
 */
export async function loadWhoopWebMeetingHrMap(
  env: Pick<Env, "DB">,
  meetings: MeetingInput[],
  restingByDay: Map<string, number | null>,
  /** Meetings the owner left out never count toward anyone's baseline. */
  isExcluded?: (eventId: string) => boolean,
): Promise<Map<string, MeetingHrStress>> {
  if (!meetings.length) return new Map();
  const starts = meetings.map((m) => Date.parse(m.startUtc)).filter(Number.isFinite);
  const from = Math.min(...starts) - (BASELINE_DAYS + 1) * 86_400_000;
  const to = Math.max(...starts) + 86_400_000;
  const stored = await listCachedHrMetadata(env.DB, new Date(from).toISOString(), new Date(to).toISOString());
  // The pool is read from whoop_web_hr alone (no calendar join), so left-out meetings are dropped by id here.
  const metadata = isExcluded ? stored.filter((r) => !isExcluded(r.eventId)) : stored;
  const anchors = meetingAnchors(meetings);
  const candidates = new Map(metadata.filter((r) => r.status === "ok" && r.sampleCount > 0).map((r) => [r.eventId, r]));
  const baselineByMeeting = new Map<string, string[]>();
  const needed = new Set<string>();
  for (const meeting of meetings) {
    if (!candidates.has(meeting.id)) continue;
    const ids = baselineWindows(meeting, metadata).map((r) => r.eventId);
    baselineByMeeting.set(meeting.id, ids);
    needed.add(meeting.id);
    for (const id of ids) needed.add(id);
  }
  const rows = new Map((await listScoringHr(env.DB, [...needed], anchors)).map((r) => [r.eventId, r]));
  const out = new Map<string, MeetingHrStress>();
  for (const meeting of meetings) {
    const row = rows.get(meeting.id);
    if (!row) {
      out.set(meeting.id, whoopWebNoHr());
      continue;
    }
    const baselines = (baselineByMeeting.get(meeting.id) ?? []).flatMap((id) => rows.get(id) ?? []);
    out.set(meeting.id, scoreWhoopWebMeeting(meeting, row, baselines, restingByDay.get(meeting.day) ?? null).hr);
  }
  return out;
}

/** Where minute buckets anchor for meetings whose times were changed. Empty (so the SQL is unchanged) when none were. */
export function meetingAnchors(meetings: MeetingInput[]): Map<string, { startUtc: string; endUtc: string }> {
  return new Map(meetings.filter((m) => m.effective).map((m) => [m.id, { startUtc: m.startUtc, endUtc: m.endUtc }]));
}

async function restingFor(db: D1Database, day: string): Promise<number | null> {
  try {
    const r = await db
      .prepare(`SELECT lowest_hr FROM daily_sleep WHERE source = ? AND day = ? AND deleted_at IS NULL`)
      .bind(SOURCE_WHOOP, day)
      .first<{ lowest_hr: number | null }>();
    return r?.lowest_hr ?? null;
  } catch {
    return null;
  }
}

/**
 * The meeting page. Reads the cache; with `fill`, fetches what is missing
 * or stale for this one meeting (one heart-rate call, at most one stress
 * call per day it touches). WHOOP trouble never fails the response.
 */
export async function meetingHrDetail(
  env: FillEnv,
  eventId: string,
  opts: { fill: boolean; overrides?: OverrideSet },
  depsIn: WhoopWebDeps = {},
): Promise<MeetingHrDetail | null> {
  const deps = workerDeps(env, depsIn);
  const calendarEv = await env.DB.prepare(
    `SELECT id, start_utc, end_utc, duration_s, title FROM calendar_event WHERE id = ? AND deleted_at IS NULL`,
  )
    .bind(eventId)
    .first<EventRow>();
  if (!calendarEv) return null;
  // One small read: this meeting's overrides, its series, and everyone near it for the baseline.
  const overrides = opts.overrides ?? await overridesAround(env.DB, calendarEv.start_utc);
  const [ev] = applyOverrides([calendarEv], overrides);
  if (!ev) return null;
  const tz = await loadTimeZone(env.DB).catch(() => DEFAULT_TIME_ZONE);
  const meeting = toInput(ev, tz);
  const anchors = meetingAnchors([meeting]);
  const enabled = whoopWebHrActive(env);
  const now = nowOf(deps);
  const win = fetchWindow(meeting.startUtc, meeting.endUtc);
  const days = meetingDays(meeting.startUtc, meeting.endUtc, tz);
  const fill: { hr: FillOutcome; stress: FillOutcome } = { hr: enabled ? "cached" : "disabled", stress: enabled ? "cached" : "disabled" };

  let detailHr = await getDetailHr(env.DB, eventId, anchors);
  let stressDays = await getCachedStressDays(env.DB, days);
  const tooLong = ev.duration_s <= 0 || ev.duration_s > meetingLimitS(ev.override?.timesChanged);
  if (enabled && opts.fill && !tooLong) {
    const hrStale = isStale(detailHr?.raw ?? null, win, now);
    const stressStale = days.filter((d) => isStale(stressDays.get(d) ?? null, stressDayWindow(d, tz), now));
    if (now < Date.parse(win.startUtc)) {
      fill.hr = "pending";
      fill.stress = "pending";
    } else if ((hrStale || stressStale.length) && !(await canAuth(env, deps))) {
      fill.hr = detailHr ? "cached" : "skipped";
      fill.stress = stressDays.size ? "cached" : "skipped";
    } else {
      try {
        if (hrStale) {
          const r = await fillMeetingHr(env, meeting, "page", deps);
          fill.hr = r.outcome;
          detailHr = await getDetailHr(env.DB, eventId, anchors);
        }
        for (const d of stressStale) {
          const s = await fillStressDay(env, d, tz, "page", deps);
          fill.stress = s.outcome;
        }
        if (stressStale.length) stressDays = await getCachedStressDays(env.DB, days);
      } catch (err) {
        if (!(err instanceof WhoopWebAuthError)) throw err;
        if (fill.hr === "cached" && !detailHr) fill.hr = "error";
        if (fill.stress === "cached" && !stressDays.size) fill.stress = "error";
      }
    }
  } else if (enabled && tooLong) {
    fill.hr = "skipped";
    fill.stress = "skipped";
  }

  const start = Date.parse(meeting.startUtc);
  const metadata = detailHr?.scoring.minutePoints.length
    ? (await listCachedHrMetadata(
        env.DB,
        new Date(start - BASELINE_DAYS * 86_400_000).toISOString(),
        new Date(start + 86_400_000).toISOString(),
      )).filter((r) => !overrides.isExcluded(r.eventId))
    : [];
  const rows = await listScoringHr(env.DB, baselineWindows(meeting, metadata).map((r) => r.eventId));
  return buildMeetingDetail({
    enabled,
    meeting: { ...meeting, title: ev.title },
    timeZone: tz,
    row: detailHr?.raw ?? null,
    scoringRow: detailHr?.scoring ?? null,
    rows,
    stressDays: [...stressDays.values()],
    restingHint: await restingFor(env.DB, meeting.day),
    fill,
  });
}
