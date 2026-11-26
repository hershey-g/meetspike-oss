import { scoreMeetingHr, noHrCoverage, meetingHrCoverage, type HrSample, type MeetingHrStress } from "../../lib/heartrate.ts";
import { calendarDayInZone, addCalendarDays, localMidnightUtcIso } from "../../lib/time.ts";
import { WINDOW_PAD_MIN } from "./constants.ts";
import type { CachedHrMetadata, CachedHrWindow, CachedStressDay, ScoringHrWindow } from "./store.ts";
import type { HrPoint, StressPoint } from "./parse.ts";

/** Per-meeting heart-rate readings from cached WHOOP web windows. Pure: no WHOOP calls here. */
export type MeetingInput = {
  id: string; startUtc: string; endUtc: string; day: string;
  /** startUtc/endUtc were changed by the owner or the Mac, so they differ from the calendar row's times. */
  effective?: true;
};

export const WHOOP_WEB_METHOD_NOTE =
  "Heart rate from your WHOOP strap during the meeting, minute by minute, compared with your usual heart rate in other meetings over the past two weeks.";
export const WHOOP_WEB_NO_HR = "No heart rate for this meeting";
const WHOOP_WEB_NO_HR_STORY = "WHOOP has no heart rate saved for this meeting yet.";
const USUAL_PHRASE = "your usual in meetings over the past two weeks";
/** Days of other meetings that make up the baseline. */
export const BASELINE_DAYS = 14;
/** Most other meetings the baseline reads. */
const BASELINE_MAX_WINDOWS = 40;
/** Fewer distinct baseline minutes than this and we also use the meeting's own padding. */
const BASELINE_MIN_MINUTES = 30;
/** Longer than this is not a meeting (all-day events are stored as 24 h). */
export const MAX_MEETING_S = 8 * 3600;
/** A window the owner (or the Mac) moved may last this long. Calendar times keep MAX_MEETING_S. */
export const MAX_MOVED_MEETING_S = 12 * 3600;
/** The longest a meeting may last: 12 h when its effective times come from an override, else 8 h. */
export const meetingLimitS = (moved: boolean | undefined): number => (moved ? MAX_MOVED_MEETING_S : MAX_MEETING_S);

/** The span we fetch: start-10 min to end+10 min. */
export function fetchWindow(startUtc: string, endUtc: string): { startMs: number; endMs: number; startUtc: string; endUtc: string } {
  const startMs = Date.parse(startUtc) - WINDOW_PAD_MIN * 60_000;
  const endMs = Date.parse(endUtc) + WINDOW_PAD_MIN * 60_000;
  return { startMs, endMs, startUtc: new Date(startMs).toISOString(), endUtc: new Date(endMs).toISOString() };
}

const SETTLED_MS = 6 * 3600 * 1000;
const RETRY_MS = 30 * 60 * 1000;

/**
 * A row can be marked "not fetched for this window": its fetched_at sits at the
 * window's own start (window_start_utc), or at most this far after it (a rewrite
 * of a marked row moves it forward 1 ms, never past this). A real fetch cannot
 * land there, because nothing is fetched before the window opens. The projection
 * in raw.ts writes the mark when a time change leaves a row holding stored points
 * that WHOOP would have to be asked about again, and a failed fetch keeps it.
 * Only a fetch that answers replaces it. The SQL in raw.ts, store.ts and
 * wearable-status.ts uses the same bound.
 */
export const NOT_FETCHED_SLACK_MS = 1000;

/** Whether this fetched_at is the "not fetched for this window" mark of a row with this window start. */
export function isNotFetchedMark(fetchedAt: string, windowStartUtc: string): boolean {
  const fetched = Date.parse(fetchedAt);
  const start = Date.parse(windowStartUtc);
  return Number.isFinite(fetched) && Number.isFinite(start) && fetched < start + NOT_FETCHED_SLACK_MS;
}

/**
 * Whether a stored row should be fetched again. A row fetched 6 h or more
 * after its window closed is final (WHOOP has synced by then). Anything
 * else is retried at most every 30 minutes. Never before the window opens.
 * A row marked "not fetched for this window" (see NOT_FETCHED_SLACK_MS) is always
 * fetched again, whatever the retry delay: the points on it were never checked
 * against WHOOP for this window.
 */
export function isStale(
  row: { status: string; fetchedAt: string; windowStartUtc?: string; windowEndUtc?: string } | null,
  window: { startUtc: string; endUtc: string },
  now: number,
): boolean {
  if (now < Date.parse(window.startUtc)) return false;
  if (!row) return true;
  if (row.windowStartUtc != null && row.windowEndUtc != null) {
    if (row.windowStartUtc !== window.startUtc || row.windowEndUtc !== window.endUtc) return true;
  }
  const fetched = Date.parse(row.fetchedAt);
  if (!Number.isFinite(fetched)) return true;
  if (isNotFetchedMark(row.fetchedAt, window.startUtc)) return true;
  const settled = fetched - Date.parse(window.endUtc) >= SETTLED_MS;
  if (settled && row.status !== "error") return false;
  return now - fetched >= RETRY_MS;
}

/** The local day a stress row covers, as a window, for `isStale`. */
export function stressDayWindow(day: string, timeZone: string): { startUtc: string; endUtc: string } {
  return { startUtc: localMidnightUtcIso(day, timeZone), endUtc: localMidnightUtcIso(addCalendarDays(day, 1), timeZone) };
}

function toSamples(points: HrPoint[]): HrSample[] {
  return points.map(([t, bpm]) => {
    const timestamp = new Date(t).toISOString();
    return { bpm, timestampMs: t, timestamp, source: "awake" };
  });
}

function inRange(points: HrPoint[], startMs: number, endMs: number): HrPoint[] {
  return points.filter(([t]) => t >= startMs && t <= endMs);
}

function percentile(sorted: number[], p: number): number | null {
  if (!sorted.length) return null;
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.floor((sorted.length - 1) * p)))];
}

export type HrBaseline = {
  /** Mean bpm of the baseline pool. */
  meanBpm: number | null;
  /** 25th–75th percentile: the "usual" band drawn behind the line. */
  lowBpm: number | null;
  highBpm: number | null;
  /** How many other meetings went into it. */
  meetings: number;
  sampleCount: number;
  /** "meetings" = other meetings over 14 days; "padding" = the 10 minutes either side; "none". */
  basis: "meetings" | "padding" | "none";
};

/** Select baseline windows from metadata before reading their samples. */
export function baselineWindows<T extends CachedHrMetadata>(meeting: MeetingInput, rows: T[]): T[] {
  const start = Date.parse(meeting.startUtc);
  const from = start - BASELINE_DAYS * 86_400_000;
  const to = start + 86_400_000;
  return rows
    .filter((r) => r.eventId !== meeting.id && r.status === "ok" && r.sampleCount > 0)
    .filter((r) => {
      const t = Date.parse(r.windowStartUtc);
      return t >= from && t < to;
    })
    .sort((a, b) => Math.abs(Date.parse(a.windowStartUtc) - start) - Math.abs(Date.parse(b.windowStartUtc) - start))
    .slice(0, BASELINE_MAX_WINDOWS);
}

function uniqueMinutes(points: Iterable<HrPoint>): HrPoint[] {
  // Two meetings can share minutes (overlap, back-to-back padding): count each minute once.
  const seen = new Set<number>();
  const unique: HrPoint[] = [];
  for (const point of points) {
    const minute = Math.floor(point[0] / 60_000);
    if (seen.has(minute)) continue;
    seen.add(minute);
    unique.push(point);
  }
  return unique;
}

function summarizeBaseline(points: HrPoint[], meetings: number, basis: HrBaseline["basis"]): HrBaseline {
  const bpms = points.map(([, b]) => b).sort((a, b) => a - b);
  if (!bpms.length) return { meanBpm: null, lowBpm: null, highBpm: null, meetings: 0, sampleCount: 0, basis: "none" };
  const mean = Math.round((bpms.reduce((a, b) => a + b, 0) / bpms.length) * 10) / 10;
  return { meanBpm: mean, lowBpm: percentile(bpms, 0.25), highBpm: percentile(bpms, 0.75), meetings, sampleCount: bpms.length, basis };
}

/** WHOOP wording on the shared no-coverage reading. */
export function whoopWebNoHr(): MeetingHrStress {
  return { ...noHrCoverage(), methodNote: WHOOP_WEB_METHOD_NOTE, headline: WHOOP_WEB_NO_HR, story: WHOOP_WEB_NO_HR_STORY };
}

/**
 * Score one meeting from the minute averages for its window and baselines.
 * Reuses the Oura scoring (`scoreMeetingHr`) with 1-minute spacing.
 */
export function scoreWhoopWebMeeting(
  meeting: MeetingInput,
  row: ScoringHrWindow | null,
  rows: ScoringHrWindow[],
  restingHint: number | null,
  seriesMax?: number,
): { hr: MeetingHrStress; baseline: HrBaseline } {
  const startMs = Date.parse(meeting.startUtc);
  const endMs = Date.parse(meeting.endUtc);
  const own = row && row.status === "ok" ? row.minutePoints : [];
  // Half-open [start, end): the minute that starts at the end time is after the meeting.
  const inMeeting = own.filter(([t]) => t >= startMs && t < endMs);
  if (!inMeeting.length) {
    return { hr: whoopWebNoHr(), baseline: summarizeBaseline([], 0, "none") };
  }
  const others = baselineWindows(meeting, rows.filter((r) => r.minutePoints.length));
  const pool = uniqueMinutes(others.flatMap((r) => r.minutePoints));
  let basePoints = pool;
  let basis: HrBaseline["basis"] = pool.length ? "meetings" : "none";
  if (pool.length < BASELINE_MIN_MINUTES) {
    // Not enough other meetings yet: use the minutes just before and after.
    const padding = own.filter(([t]) => t < startMs || t >= endMs);
    basePoints = uniqueMinutes([...pool, ...padding]);
    if (!pool.length && padding.length) basis = "padding";
  }
  const hr = scoreMeetingHr(toSamples(inMeeting), toSamples(basePoints), restingHint, {
    sampleMinutes: 1,
    usualPhrase: basis === "padding" ? "the minutes just before and after" : USUAL_PHRASE,
    sampleNoun: "minutes of WHOOP heart rate",
    seriesMax,
  });
  return {
    hr: meetingHrCoverage({ ...hr, methodNote: WHOOP_WEB_METHOD_NOTE }, inMeeting.map(([t]) => t), startMs, endMs, "WHOOP"),
    baseline: summarizeBaseline(basePoints, basis === "meetings" ? others.length : 0, basis),
  };
}

export type StressSlice = {
  points: Array<{ t: string; level: number }>;
  meanLevel: number | null;
  peakLevel: number | null;
  minLevel: number | null;
};

/** The day's Stress Monitor line, cut to [fromMs, toMs]. */
export function sliceStress(points: StressPoint[], fromMs: number, toMs: number): StressSlice {
  const inside = points.filter(([t]) => t >= fromMs && t <= toMs);
  const levels = inside.map(([, l]) => l);
  return {
    points: inside.map(([t, level]) => ({ t: new Date(t).toISOString(), level })),
    meanLevel: levels.length ? Math.round((levels.reduce((a, b) => a + b, 0) / levels.length) * 100) / 100 : null,
    peakLevel: levels.length ? Math.max(...levels) : null,
    minLevel: levels.length ? Math.min(...levels) : null,
  };
}

/** Local days a meeting touches (usually one). */
export function meetingDays(startUtc: string, endUtc: string, timeZone: string): string[] {
  const a = calendarDayInZone(startUtc, timeZone);
  const b = calendarDayInZone(endUtc, timeZone);
  return a === b ? [a] : [a, b];
}

export type MeetingHrDetail = {
  ok: true;
  enabled: boolean;
  meetingId: string;
  title: string | null;
  timeZone: string;
  window: { startUtc: string; endUtc: string; fetchStartUtc: string; fetchEndUtc: string };
  hrStress: MeetingHrStress;
  /** Every stored reading in the padded window, for the chart. */
  series: Array<{ t: string; bpm: number }>;
  baseline: HrBaseline;
  stress: (StressSlice & { dayCurrentLevel: number | null }) | null;
  /** What happened on this request: read from the cache, fetched now, or why not. */
  fill: { hr: FillOutcome; stress: FillOutcome };
  message: string | null;
};

export type FillOutcome = "cached" | "fetched" | "empty" | "error" | "skipped" | "pending" | "disabled";

export function buildMeetingDetail(opts: {
  enabled: boolean;
  meeting: MeetingInput & { title: string | null };
  timeZone: string;
  row: CachedHrWindow | null;
  scoringRow: ScoringHrWindow | null;
  rows: ScoringHrWindow[];
  stressDays: CachedStressDay[];
  restingHint: number | null;
  fill: { hr: FillOutcome; stress: FillOutcome };
}): MeetingHrDetail {
  const { meeting, row } = opts;
  const win = fetchWindow(meeting.startUtc, meeting.endUtc);
  const { hr, baseline } = scoreWhoopWebMeeting(meeting, opts.scoringRow, opts.rows, opts.restingHint, 120);
  const own = row && row.status === "ok" ? inRange(row.points, win.startMs, win.endMs) : [];
  const stressPoints = opts.stressDays.filter((s) => s.status === "ok").flatMap((s) => s.points).sort((a, b) => a[0] - b[0]);
  const hasStressDay = opts.stressDays.some((s) => s.status === "ok");
  const stress = hasStressDay
    ? {
        ...sliceStress(stressPoints, win.startMs, win.endMs),
        dayCurrentLevel: opts.stressDays.find((s) => s.status === "ok")?.currentLevel ?? null,
      }
    : null;
  let message: string | null = null;
  if (!opts.enabled) message = "Per-meeting heart rate from WHOOP is turned off.";
  else if (hr.coverage !== "ok") {
    if (opts.fill.hr === "error") message = `${WHOOP_WEB_NO_HR}. WHOOP did not answer; we will try again later.`;
    else if (opts.fill.hr === "pending") message = `${WHOOP_WEB_NO_HR} yet. It fills in once the meeting has started.`;
    else message = `${WHOOP_WEB_NO_HR}.`;
  }
  return {
    ok: true,
    enabled: opts.enabled,
    meetingId: meeting.id,
    title: meeting.title,
    timeZone: opts.timeZone,
    window: { startUtc: meeting.startUtc, endUtc: meeting.endUtc, fetchStartUtc: win.startUtc, fetchEndUtc: win.endUtc },
    hrStress: hr,
    series: own.map(([t, bpm]) => ({ t: new Date(t).toISOString(), bpm })),
    baseline,
    stress,
    fill: opts.fill,
    message,
  };
}
