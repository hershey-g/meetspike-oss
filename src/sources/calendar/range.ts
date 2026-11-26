import { addCalendarDays, calendarDayInZone } from "../../lib/time.ts";
import { historyDays, spanDays } from "../../lib/date-range.ts";
import { thinHrSeries, type MeetingHrStress } from "../../lib/heartrate.ts";
import type { JoinedMeeting } from "./join.ts";
import {
  READINESS_HIT,
  SLEEP_HIT,
  stressScore,
  toMeetingJson,
  zoneBucket,
  type MeetingJson,
  type WeekHardest,
} from "./meetings.ts";

/**
 * Morning recovery scores for one calendar day. Deliberately provider-neutral:
 * any wearable that yields a sleep and a readiness/recovery score per morning fits.
 */
export type RecoveryDay = {
  sleepScore: number | null;
  readinessScore: number | null;
  /** Whole-day exertion for the same calendar day. Present only when the wearable reports it. */
  strain?: number | null;
};

export type RangeZoneCounts = {
  elevated: number;
  watching: number;
  restored: number;
  noHr: number;
  combinedHr?: number;
};

export type RangeDay = RangeZoneCounts & {
  day: string;
  meetingCount: number;
  totalDurationS: number;
  afterHoursCount: number;
  earlyStartCount: number;
  /** Mean of the per-meeting average heart-rate, meetings with ring coverage only. */
  meanBpm: number | null;
  /** Scores from the morning of this day (the night before the work day). */
  morning: RecoveryDay | null;
  /** Scores from the morning after this day (the night that followed it). */
  nextMorning: RecoveryDay | null;
  meetings: MeetingJson[];
};

export type RangeRecovery = {
  /** Mornings in the range that have a score. */
  nSleep: number;
  nReadiness: number;
  avgSleepScore: number | null;
  avgReadinessScore: number | null;
  lowSleepDays: number;
  lowReadinessDays: number;
  /** Days in the range with a strain value, and their mean. Present only when there are any. */
  nStrain?: number;
  avgStrain?: number | null;
};

export type RangeBriefing = {
  ok: true;
  start: string;
  end: string;
  spanDays: number;
  singleDay: boolean;
  timeZone: string;
  summary: RangeZoneCounts & {
    meetingCount: number;
    daysWithMeetings: number;
    totalDurationS: number;
    afterHoursCount: number;
    earlyStartCount: number;
    byKind: Record<string, number>;
    meanBpm: number | null;
    hardest: WeekHardest | null;
    line: string;
  };
  recovery: RangeRecovery;
  /** Days in ascending order. Extra-wide ranges omit empty days. */
  days: RangeDay[];
};

function round1(n: number): number {
  return Math.round(n * 10) / 10;
}

function mean(values: number[]): number | null {
  if (!values.length) return null;
  return round1(values.reduce((s, n) => s + n, 0) / values.length);
}

function recoveryOf(slice: RecoveryDay | null | undefined): RecoveryDay | null {
  if (!slice) return null;
  const strain = slice.strain ?? null;
  if (slice.sleepScore == null && slice.readinessScore == null && strain == null) return null;
  return {
    sleepScore: slice.sleepScore,
    readinessScore: slice.readinessScore,
    ...(strain != null ? { strain } : {}),
  };
}

function formatDay(day: string): string {
  return new Date(`${day}T12:00:00.000Z`).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });
}

export function composeRangeSummary(opts: RangeZoneCounts & {
  start: string;
  end: string;
  meetingCount: number;
  daysWithMeetings: number;
  hardest: WeekHardest | null;
  /** False when the wearable has no heart-rate fine enough to slice per meeting. */
  intradayHr?: boolean;
  totalDurationS?: number;
  afterHoursCount?: number;
}): string {
  const single = opts.start === opts.end;
  const span = single ? `on ${formatDay(opts.start)}` : `from ${formatDay(opts.start)} to ${formatDay(opts.end)}`;
  if (opts.meetingCount === 0) return `No meetings ${span}.`;
  const noun = opts.meetingCount === 1 ? "meeting" : "meetings";
  const across = single ? "" : ` across ${opts.daysWithMeetings} ${opts.daysWithMeetings === 1 ? "day" : "days"}`;
  const head = `${opts.meetingCount} ${noun}${across} ${span}`;
  if (opts.intradayHr === false) {
    // No per-meeting signal to count: describe the load itself.
    const hours = Math.round(((opts.totalDurationS ?? 0) / 3600) * 10) / 10;
    const bits = [`${hours} ${hours === 1 ? "hour" : "hours"} in meetings`];
    if (opts.afterHoursCount) bits.push(`${opts.afterHoursCount} after hours`);
    return `${head}: ${bits.join(", ")}.`;
  }
  if (opts.elevated + opts.watching + opts.restored === 0 && !opts.combinedHr) {
    return `${head}. No ring HR in those windows — we will not invent a signal.`;
  }
  const combined = opts.combinedHr ? `, ${opts.combinedHr} with WHOOP + Oura heart rate` : "";
  let line = `${head}: ${opts.elevated} elevated, ${opts.watching} worth watching, ${opts.restored} restored${combined}.`;
  if (opts.hardest) {
    const title = opts.hardest.title?.trim() || "Untitled meeting";
    line += ` Highest: ${title} on ${formatDay(opts.hardest.day)}.`;
  }
  return line;
}

/**
 * Aggregate per-meeting and per-day results over an inclusive local-day range.
 * A range of one day is valid and yields exactly one `days` entry.
 *
 * `recoveryByDay` is keyed by the morning's calendar day and should cover
 * `start` through `end + 1` so the last day's "night after" can resolve.
 */
export function buildRangeBriefing(opts: {
  start: string;
  end: string;
  timeZone: string;
  joined: JoinedMeeting[];
  recoveryByDay?: Map<string, RecoveryDay>;
  hrByMeetingId?: Map<string, MeetingHrStress>;
  /** Pass false for a wearable without per-meeting heart-rate. Default true. */
  intradayHr?: boolean;
}): RangeBriefing {
  const { start, end, timeZone, joined } = opts;
  const recoveryByDay = opts.recoveryByDay ?? new Map<string, RecoveryDay>();

  const byDay = new Map<string, MeetingJson[]>();
  for (const row of joined) {
    const day = calendarDayInZone(row.event.start_utc, timeZone);
    if (day < start || day > end) continue;
    const hr = opts.hrByMeetingId?.get(row.event.id) ?? null;
    const json = toMeetingJson(row, stressScore(row), hr ? { ...hr, series: thinHrSeries(hr.series) } : null);
    const list = byDay.get(day) ?? [];
    list.push(json);
    byDay.set(day, list);
  }

  const total: RangeZoneCounts = { elevated: 0, watching: 0, restored: 0, noHr: 0 };
  const byKind: Record<string, number> = {};
  const allBpm: number[] = [];
  let meetingCount = 0;
  let daysWithMeetings = 0;
  let totalDurationS = 0;
  let afterHoursCount = 0;
  let earlyStartCount = 0;
  let hardestJson: MeetingJson | null = null;
  const sleepScores: number[] = [];
  const readinessScores: number[] = [];
  const strains: number[] = [];

  const dateList = historyDays(start, end, [
    ...byDay.keys(), ...[...recoveryByDay.keys()].flatMap((day) => [day, addCalendarDays(day, -1)]),
  ]);
  const days: RangeDay[] = dateList.map((day) => {
    const meetings = (byDay.get(day) ?? []).sort(
      (a, b) => a.startUtc.localeCompare(b.startUtc) || a.id.localeCompare(b.id),
    );
    const counts: RangeZoneCounts = { elevated: 0, watching: 0, restored: 0, noHr: 0 };
    const bpm: number[] = [];
    let durationS = 0;
    let afterHours = 0;
    let early = 0;
    for (const m of meetings) {
      const bucket = zoneBucket(m.hrStress);
      if (bucket !== "none") counts[bucket] += 1;
      else if (m.hrStress?.coverage === "ok") counts.combinedHr = (counts.combinedHr ?? 0) + 1;
      else counts.noHr += 1;
      if (bucket !== "none" && m.hrStress?.meanBpm != null) bpm.push(m.hrStress.meanBpm);
      if (bucket === "elevated" || bucket === "watching") {
        const impact = m.hrStress?.impact ?? 0;
        if (!hardestJson || impact > (hardestJson.hrStress?.impact ?? 0)) hardestJson = m;
      }
      durationS += m.durationS;
      if (m.afterHours) afterHours += 1;
      if (m.earlyStart) early += 1;
      byKind[m.kind] = (byKind[m.kind] ?? 0) + 1;
    }
    meetingCount += meetings.length;
    if (meetings.length) daysWithMeetings += 1;
    totalDurationS += durationS;
    afterHoursCount += afterHours;
    earlyStartCount += early;
    total.elevated += counts.elevated;
    total.watching += counts.watching;
    total.restored += counts.restored;
    total.noHr += counts.noHr;
    if (counts.combinedHr) total.combinedHr = (total.combinedHr ?? 0) + counts.combinedHr;
    allBpm.push(...bpm);

    const morning = recoveryOf(recoveryByDay.get(day));
    if (morning?.sleepScore != null) sleepScores.push(morning.sleepScore);
    if (morning?.readinessScore != null) readinessScores.push(morning.readinessScore);
    if (morning?.strain != null) strains.push(morning.strain);

    return {
      day,
      meetingCount: meetings.length,
      totalDurationS: durationS,
      afterHoursCount: afterHours,
      earlyStartCount: early,
      ...counts,
      meanBpm: mean(bpm),
      morning,
      nextMorning: recoveryOf(recoveryByDay.get(addCalendarDays(day, 1))),
      meetings,
    };
  });

  const top = hardestJson as MeetingJson | null;
  const hardest: WeekHardest | null = top
    ? {
        id: top.id,
        title: top.title,
        day: top.day,
        startLocal: top.startLocal,
        headline: top.hrStress?.headline ?? "Elevated",
        impact: top.hrStress?.impact ?? 0,
      }
    : null;

  return {
    ok: true,
    start,
    end,
    spanDays: spanDays(start, end),
    singleDay: start === end,
    timeZone,
    summary: {
      meetingCount,
      daysWithMeetings,
      totalDurationS,
      afterHoursCount,
      earlyStartCount,
      byKind,
      ...total,
      meanBpm: mean(allBpm),
      hardest,
      line: composeRangeSummary({
        start,
        end,
        meetingCount,
        daysWithMeetings,
        hardest,
        ...total,
        intradayHr: opts.intradayHr,
        totalDurationS,
        afterHoursCount,
      }),
    },
    recovery: {
      nSleep: sleepScores.length,
      nReadiness: readinessScores.length,
      avgSleepScore: mean(sleepScores),
      avgReadinessScore: mean(readinessScores),
      lowSleepDays: sleepScores.filter((n) => n < SLEEP_HIT).length,
      lowReadinessDays: readinessScores.filter((n) => n < READINESS_HIT).length,
      ...(strains.length ? { nStrain: strains.length, avgStrain: mean(strains) } : {}),
    },
    days,
  };
}
