import type { CalendarEventRow } from "../../types.ts";
import { addCalendarDays, DEFAULT_TIME_ZONE, ouraMorningDay } from "../../lib/time.ts";
import { isAfterHours } from "./classify.ts";

/** Early local start that can steal the prior night's sleep. */
export const EARLY_START_HOUR = 8;

export type OuraDaySlice = {
  day: string;
  sleepScore: number | null;
  readinessScore: number | null;
  avgHrv: number | null;
  lowestHr: number | null;
  totalSleepS: number | null;
  /** Same-day Oura `daily_stress.stress_high` seconds, if projected. */
  stressHighS: number | null;
  recoveryHighS: number | null;
  stressSummary: string | null;
  /** Whole-day exertion for this calendar day, for wearables that report it (WHOOP strain, 0–21). */
  strain?: number | null;
  /** Average / max heart rate over the whole day, when the wearable reports only day totals. */
  dayAvgHr?: number | null;
  dayMaxHr?: number | null;
};

/** Provider-neutral name for the per-day wearable slice. */
export type WearableDaySlice = OuraDaySlice;

export type StressSource = "daily_stress" | "readiness_proxy" | "none";

export type JoinedSignals = {
  workDay: string;
  ouraMorningDay: string;
  stressSource: StressSource;
  /** Same-day stress (work day D). Day grain — not intra-meeting HR. */
  stressHighS: number | null;
  recoveryHighS: number | null;
  stressSummary: string | null;
  /** Next-morning Oura (D+1). */
  nextSleepScore: number | null;
  nextReadinessScore: number | null;
  nextHrv: number | null;
  nextLowestHr: number | null;
  nextTotalSleepS: number | null;
  /** Proxy 0–1 used only when daily_stress is missing. */
  readinessProxy: number | null;
};

export type DayLoad = {
  day: string;
  eventCount: number;
  totalDurationS: number;
  afterHoursCount: number;
  earlyStartCount: number;
  clientCount: number;
  byKind: Record<string, number>;
};

export type JoinedMeeting = {
  event: CalendarEventRow;
  signals: JoinedSignals;
  dayLoad: DayLoad;
};

export function isEarlyStart(localHour: number, localMinute = 0): boolean {
  return localHour + localMinute / 60 < EARLY_START_HOUR;
}

export function joinWorkDayToOuraMorning(workDay: string): string {
  return ouraMorningDay(workDay);
}

/**
 * Readiness-derived stress proxy when `daily_stress` has no row.
 * Low readiness / low hrv_balance → higher proxy (0–1). Not Oura stress.
 */
export function readinessStressProxy(opts: {
  readinessScore: number | null;
  contributorsJson: string | null;
}): number | null {
  const score = opts.readinessScore;
  let hrvBalance: number | null = null;
  if (opts.contributorsJson) {
    try {
      const c = JSON.parse(opts.contributorsJson) as { hrv_balance?: number };
      if (typeof c.hrv_balance === "number") hrvBalance = c.hrv_balance;
    } catch {
      hrvBalance = null;
    }
  }
  if (score == null && hrvBalance == null) return null;
  const invReady = score == null ? 0.5 : Math.min(1, Math.max(0, (100 - score) / 100));
  const invHrv = hrvBalance == null ? invReady : Math.min(1, Math.max(0, (100 - hrvBalance) / 100));
  return Math.round((0.65 * invReady + 0.35 * invHrv) * 1000) / 1000;
}

export function buildDayLoad(events: CalendarEventRow[], day: string): DayLoad {
  const onDay = events.filter((e) => e.day === day && !e.deleted_at);
  const byKind: Record<string, number> = {};
  let totalDurationS = 0;
  let afterHoursCount = 0;
  let earlyStartCount = 0;
  let clientCount = 0;
  for (const e of onDay) {
    byKind[e.kind] = (byKind[e.kind] ?? 0) + 1;
    totalDurationS += e.duration_s;
    if (e.after_hours) afterHoursCount += 1;
    if (e.start_local) {
      const m = /T(\d{2}):(\d{2})/.exec(e.start_local);
      if (m && isEarlyStart(Number(m[1]), Number(m[2]))) earlyStartCount += 1;
    } else if (e.after_hours === 0) {
      // fallback: after_hours already captured; early unknown without local
    }
    if (e.kind === "client") clientCount += 1;
  }
  return {
    day,
    eventCount: onDay.length,
    totalDurationS,
    afterHoursCount,
    earlyStartCount,
    clientCount,
    byKind,
  };
}

export function joinMeeting(
  event: CalendarEventRow,
  ouraByDay: Map<string, OuraDaySlice>,
  allEvents: CalendarEventRow[],
  readinessContributorsByDay?: Map<string, string | null>,
  dayLoad = buildDayLoad(allEvents, event.day),
): JoinedMeeting {
  const workDay = event.day;
  const morning = joinWorkDayToOuraMorning(workDay);
  const sameDay = ouraByDay.get(workDay);
  const next = ouraByDay.get(morning);
  let stressSource: StressSource = "none";
  let readinessProxy: number | null = null;
  if (sameDay && sameDay.stressHighS != null) {
    stressSource = "daily_stress";
  } else {
    const contrib = readinessContributorsByDay?.get(workDay) ?? null;
    readinessProxy = readinessStressProxy({
      readinessScore: sameDay?.readinessScore ?? null,
      contributorsJson: contrib,
    });
    if (readinessProxy != null) stressSource = "readiness_proxy";
  }
  return {
    event,
    dayLoad,
    signals: {
      workDay,
      ouraMorningDay: morning,
      stressSource,
      stressHighS: sameDay?.stressHighS ?? null,
      recoveryHighS: sameDay?.recoveryHighS ?? null,
      stressSummary: sameDay?.stressSummary ?? null,
      nextSleepScore: next?.sleepScore ?? null,
      nextReadinessScore: next?.readinessScore ?? null,
      nextHrv: next?.avgHrv ?? null,
      nextLowestHr: next?.lowestHr ?? null,
      nextTotalSleepS: next?.totalSleepS ?? null,
      readinessProxy,
    },
  };
}

export function joinMeetings(
  events: CalendarEventRow[],
  ouraByDay: Map<string, OuraDaySlice>,
  readinessContributorsByDay?: Map<string, string | null>,
): JoinedMeeting[] {
  const live = events.filter((e) => !e.deleted_at);
  const byDay = new Map<string, CalendarEventRow[]>();
  for (const event of live) {
    const day = byDay.get(event.day) ?? [];
    day.push(event);
    byDay.set(event.day, day);
  }
  const loads = new Map([...byDay].map(([day, meetings]) => [day, buildDayLoad(meetings, day)]));
  return live.map((event) => joinMeeting(event, ouraByDay, live, readinessContributorsByDay, loads.get(event.day)));
}

export function priorNightOuraDay(workDay: string): string {
  return workDay;
}

export function nextMorningOuraDay(workDay: string): string {
  return addCalendarDays(workDay, 1);
}

export { DEFAULT_TIME_ZONE, isAfterHours };
