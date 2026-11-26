import type { CalendarEventRow } from "../../types.ts";
import { calendarDayInZone, ouraMorningDay } from "../../lib/time.ts";
import { isEarlyStart, type DayLoad, type JoinedMeeting, type OuraDaySlice } from "./join.ts";
import { thinHrSeries, type DayHrPoint, type MeetingHrStress } from "../../lib/heartrate.ts";
import { attendeesIdentityNote, otherAttendees, parseAttendeesJson, type Attendee } from "../../lib/people.ts";
import { normalizeSourceType, type EventSourceType } from "../../lib/source-type.ts";
import { overrideJson } from "../../lib/meeting-override.ts";

const KIND_WEIGHT: Record<string, number> = {
  client: 1,
  phone: 0.7,
  unknown: 0.5,
  tagged: 0.48,
  internal: 0.45,
  admin: 0.35,
  deep_work: 0.2,
  personal: 0.12,
};

export const SLEEP_HIT = 70;
export const READINESS_HIT = 65;

export type MeetingJson = {
  id: string;
  title: string | null;
  kind: string;
  day: string;
  startUtc: string;
  endUtc: string;
  startLocal: string | null;
  endLocal: string | null;
  afterHours: boolean;
  earlyStart: boolean;
  attendeeCount: number | null;
  durationS: number;
  ouraMorningDay: string;
  signals: {
    stressHighS: number | null;
    recoveryHighS: number | null;
    stressSummary: string | null;
    stressSource: JoinedMeeting["signals"]["stressSource"];
    readinessProxy: number | null;
    nextSleepScore: number | null;
    nextReadinessScore: number | null;
    nextHrv: number | null;
    nextLowestHr: number | null;
    nextTotalSleepS: number | null;
  };
  score: number;
  flags: string[];
  /** Ring HR in [start, end] — not Oura daytime stress. Null if not attached. */
  hrStress: MeetingHrStress | null;
  attendees: Attendee[];
  attendeeNote: string | null;
  sourceType: EventSourceType;
  syncReason: string | null;
  hasTranscript: boolean;
  /** The owner's choices (see src/lib/meeting-override.ts). Only present when the meeting has any. */
  override?: NonNullable<ReturnType<typeof overrideJson>>;
  /** Not joined or not linked: listed so it can be undone, with no heart rate, score or flags. */
  excluded?: true;
};

/** Person history: drop unused join fields and shrink the HR sparkline. */
export type PersonMeetingJson = {
  id: string;
  title: string | null;
  kind: string;
  day: string;
  startUtc: string;
  startLocal: string | null;
  afterHours: boolean;
  earlyStart: boolean;
  hrStress: MeetingHrStress | null;
  nextSleepScore: number | null;
  nextReadinessScore: number | null;
};

export type DayBriefing = {
  ok: true;
  date: string;
  timeZone: string;
  join: {
    workDay: string;
    priorNightOuraDay: string;
    nextMorningOuraDay: string;
    note: string;
  };
  calendar: DayLoad & { events: MeetingJson[] };
  priorNight: OuraDaySlice | null;
  nextMorning: OuraDaySlice | null;
  flags: string[];
  /** Plain-English composition of calendar load + prior/next Oura. */
  summary: string;
  /** Downsampled ring HR for the selected local day. */
  hr: {
    source: "Oura";
    method: "heartrate_proxy";
    methodNote: string;
    series: DayHrPoint[];
  } | null;
};

function clamp01(n: number): number {
  return Math.min(1, Math.max(0, n));
}

function eventEarly(event: CalendarEventRow): boolean {
  if (!event.start_local) return false;
  const m = /T(\d{2}):(\d{2})/.exec(event.start_local);
  return m ? isEarlyStart(Number(m[1]), Number(m[2])) : false;
}

export function meetingFlags(row: JoinedMeeting): string[] {
  const flags: string[] = [];
  const { event, signals, dayLoad } = row;
  if (event.after_hours) flags.push("after_hours");
  if (eventEarly(event)) flags.push("early_start");
  if (event.kind === "client") flags.push("client");
  if (dayLoad.eventCount >= 5 || dayLoad.totalDurationS >= 5 * 3600 || dayLoad.clientCount >= 3) {
    flags.push("heavy_day");
  }
  if (signals.nextReadinessScore != null && signals.nextReadinessScore < READINESS_HIT) {
    flags.push("low_next_readiness");
  }
  if (signals.nextSleepScore != null && signals.nextSleepScore < SLEEP_HIT) {
    flags.push("low_next_sleep");
  }
  if (signals.stressSummary === "stressful") flags.push("stressful_day");
  if (signals.stressSource === "readiness_proxy") flags.push("stress_proxy");
  return flags;
}

/**
 * Rank key for "stressed about this meeting" when in-meeting HR is missing.
 * Same-day `daily_stress` is day-grain; next-morning readiness/HRV is D → D+1.
 * Prefer `hrStress.impact` on the dashboard when ring samples exist.
 */
export function stressScore(row: JoinedMeeting): number {
  const { event, signals, dayLoad } = row;
  const kind = KIND_WEIGHT[event.kind] ?? 0.4;
  const after = event.after_hours ? 0.22 : 0;
  const early = eventEarly(event) ? 0.08 : 0;
  const duration = clamp01(event.duration_s / (3 * 3600)) * 0.12;
  const attendees = clamp01((event.attendee_count ?? 0) / 8) * 0.08;
  const load = clamp01(dayLoad.totalDurationS / (6 * 3600)) * 0.08;

  let physiology = 0;
  if (signals.stressHighS != null) {
    physiology += clamp01(signals.stressHighS / 12_000) * 0.28;
  } else if (signals.readinessProxy != null) {
    physiology += signals.readinessProxy * 0.2;
  }
  if (signals.nextReadinessScore != null) {
    physiology += clamp01((100 - signals.nextReadinessScore) / 100) * 0.18;
  }
  if (signals.nextHrv != null) {
    physiology += clamp01((50 - signals.nextHrv) / 50) * 0.08;
  }
  if (signals.stressSummary === "stressful") physiology += 0.06;

  return Math.round((kind * 0.25 + after + early + duration + attendees + load + physiology) * 1000) / 1000;
}

/**
 * Rank key for "this meeting sat in front of a bad night".
 * Retrospective when D+1 Oura exists; otherwise calendar-load heuristics.
 */
export function sleepImpactScore(row: JoinedMeeting): number {
  const { event, signals, dayLoad } = row;
  const after = event.after_hours ? 0.32 : 0;
  const early = eventEarly(event) ? 0.22 : 0;
  const heavy =
    dayLoad.eventCount >= 5 || dayLoad.totalDurationS >= 5 * 3600 || dayLoad.clientCount >= 3 ? 0.16 : 0;
  const duration = clamp01(event.duration_s / (3 * 3600)) * 0.08;
  let night = 0;
  if (signals.nextSleepScore != null) night += clamp01((SLEEP_HIT - signals.nextSleepScore) / SLEEP_HIT) * 0.28;
  if (signals.nextReadinessScore != null) {
    night += clamp01((READINESS_HIT - signals.nextReadinessScore) / READINESS_HIT) * 0.18;
  }
  if (signals.nextTotalSleepS != null && signals.nextTotalSleepS < 21_600) night += 0.08;
  return Math.round((after + early + heavy + duration + night) * 1000) / 1000;
}

export function toMeetingJson(row: JoinedMeeting, score: number, hrStress: MeetingHrStress | null = null): MeetingJson {
  return {
    id: row.event.id,
    title: row.event.title,
    kind: row.event.kind,
    day: row.event.day,
    startUtc: row.event.start_utc,
    endUtc: row.event.end_utc,
    startLocal: row.event.start_local,
    endLocal: row.event.end_local,
    afterHours: Boolean(row.event.after_hours),
    earlyStart: eventEarly(row.event),
    attendeeCount: row.event.attendee_count,
    durationS: row.event.duration_s,
    ouraMorningDay: row.signals.ouraMorningDay,
    signals: {
      stressHighS: row.signals.stressHighS,
      recoveryHighS: row.signals.recoveryHighS,
      stressSummary: row.signals.stressSummary,
      stressSource: row.signals.stressSource,
      readinessProxy: row.signals.readinessProxy,
      nextSleepScore: row.signals.nextSleepScore,
      nextReadinessScore: row.signals.nextReadinessScore,
      nextHrv: row.signals.nextHrv,
      nextLowestHr: row.signals.nextLowestHr,
      nextTotalSleepS: row.signals.nextTotalSleepS,
    },
    score,
    flags: meetingFlags(row),
    hrStress,
    attendees: otherAttendees(parseAttendeesJson(row.event.attendees_json)),
    attendeeNote: attendeesIdentityNote(parseAttendeesJson(row.event.attendees_json)),
    sourceType: normalizeSourceType(row.event.source_type),
    syncReason: row.event.sync_reason ?? null,
    hasTranscript: Boolean(row.event.has_transcript),
    ...overrideFields(row.event),
  };
}

function overrideFields(event: CalendarEventRow): Pick<MeetingJson, "override" | "excluded"> {
  const override = overrideJson(event.override);
  if (!override) return {};
  return {
    override,
    ...(event.override?.excluded ? { excluded: true as const } : {}),
  };
}

/** A meeting left out (not joined, not linked): in the day's list so it can be undone, but never scored or counted. */
export function toExcludedMeetingJson(event: CalendarEventRow): MeetingJson {
  return {
    id: event.id,
    title: event.title,
    kind: event.kind,
    day: event.day,
    startUtc: event.start_utc,
    endUtc: event.end_utc,
    startLocal: event.start_local,
    endLocal: event.end_local,
    afterHours: Boolean(event.after_hours),
    earlyStart: eventEarly(event),
    attendeeCount: event.attendee_count,
    durationS: event.duration_s,
    ouraMorningDay: ouraMorningDay(event.day),
    signals: {
      stressHighS: null,
      recoveryHighS: null,
      stressSummary: null,
      stressSource: "none",
      readinessProxy: null,
      nextSleepScore: null,
      nextReadinessScore: null,
      nextHrv: null,
      nextLowestHr: null,
      nextTotalSleepS: null,
    },
    score: 0,
    flags: [],
    hrStress: null,
    attendees: otherAttendees(parseAttendeesJson(event.attendees_json)),
    attendeeNote: attendeesIdentityNote(parseAttendeesJson(event.attendees_json)),
    sourceType: normalizeSourceType(event.source_type),
    syncReason: event.sync_reason ?? null,
    hasTranscript: Boolean(event.has_transcript),
    ...overrideFields(event),
  };
}

export function toPersonMeetingJson(
  row: MeetingJson,
  nextSleepScore: number | null,
  nextReadinessScore: number | null,
): PersonMeetingJson {
  const hr = row.hrStress;
  return {
    id: row.id,
    title: row.title,
    kind: row.kind,
    day: row.day,
    startUtc: row.startUtc,
    startLocal: row.startLocal,
    afterHours: row.afterHours,
    earlyStart: row.earlyStart,
    hrStress: hr
      ? {
          ...hr,
          series: thinHrSeries(hr.series),
        }
      : null,
    nextSleepScore,
    nextReadinessScore,
  };
}

export function rankStressedMeetings(
  rows: JoinedMeeting[],
  limit = 20,
  hrByMeetingId?: Map<string, MeetingHrStress>,
): MeetingJson[] {
  const mapped = rows.map((r) => toMeetingJson(r, stressScore(r), hrByMeetingId?.get(r.event.id) ?? null));
  const hasHr = mapped.some((m) => m.hrStress?.coverage === "ok");
  return mapped
    .sort((a, b) => {
      if (hasHr) {
        const ah = a.hrStress?.coverage === "ok" ? (a.hrStress.impact ?? 0) : -1;
        const bh = b.hrStress?.coverage === "ok" ? (b.hrStress.impact ?? 0) : -1;
        if (bh !== ah) return bh - ah;
      }
      return b.score - a.score || a.startUtc.localeCompare(b.startUtc);
    })
    .slice(0, limit);
}

export function rankSleepImpactMeetings(rows: JoinedMeeting[], limit = 20): MeetingJson[] {
  return [...rows]
    .map((r) => toMeetingJson(r, sleepImpactScore(r)))
    .sort((a, b) => b.score - a.score || a.startUtc.localeCompare(b.startUtc))
    .slice(0, limit);
}

function formatBriefingDay(day: string): string {
  const d = new Date(`${day}T12:00:00.000Z`);
  return d.toLocaleDateString("en-US", {
    weekday: "long",
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });
}

function hoursLabel(totalDurationS: number): string {
  const hours = Math.round((totalDurationS / 3600) * 10) / 10;
  return Number.isInteger(hours) ? String(hours) : hours.toFixed(1);
}

function kindBits(byKind: Record<string, number>): string {
  return Object.entries(byKind)
    .filter(([, n]) => n > 0)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([k, n]) => `${n} ${k.replaceAll("_", " ")}`)
    .join(", ");
}

/** Words the briefing copy needs from the wearable. Defaults read as Oura. */
export type BriefingLabels = {
  /** Brand name, e.g. "Oura" or "WHOOP". */
  provider: string;
  /** Lower-case name of the morning score, e.g. "readiness" or "recovery". */
  readiness: string;
  /** Lower-case name of whole-day exertion, or null when there is none. */
  strain: string | null;
  /** False when the wearable has no heart-rate fine enough to slice per meeting. */
  intradayHr: boolean;
  hrProvider?: string | null;
};

export const DEFAULT_BRIEFING_LABELS: BriefingLabels = {
  provider: "Oura",
  readiness: "readiness",
  strain: null,
  intradayHr: true,
};

export function composeDaySummary(b: {
  date: string;
  calendar: DayLoad;
  priorNight: OuraDaySlice | null;
  nextMorning: OuraDaySlice | null;
  join: { nextMorningOuraDay: string };
  labels?: BriefingLabels;
}): string {
  const labels = b.labels ?? DEFAULT_BRIEFING_LABELS;
  const parts: string[] = [];
  const head = formatBriefingDay(b.date);
  const { calendar: cal } = b;
  if (cal.eventCount === 0) {
    parts.push(`${head} is a quiet calendar day.`);
  } else {
    const bits = [`${hoursLabel(cal.totalDurationS)}h on the calendar`];
    const kinds = kindBits(cal.byKind);
    if (kinds) bits.push(kinds);
    if (cal.afterHoursCount) bits.push(`${cal.afterHoursCount} after-hours`);
    if (cal.earlyStartCount) bits.push(`${cal.earlyStartCount} early start`);
    const noun = cal.eventCount === 1 ? "meeting" : "meetings";
    parts.push(`${head} — ${cal.eventCount} ${noun} (${bits.join("; ")}).`);
  }

  if (!labels.provider) return parts.join(" ");
  const prior = b.priorNight;
  if (prior?.sleepScore != null || prior?.readinessScore != null) {
    const scores: string[] = [];
    if (prior.sleepScore != null) scores.push(`sleep ${prior.sleepScore}`);
    if (prior.readinessScore != null) scores.push(`${labels.readiness} ${prior.readinessScore}`);
    let line = `Woke that morning on ${scores.join(" / ")}`;
    if (prior.stressSummary === "stressful") line += " after a stressful day";
    else if (prior.stressSummary === "restorative") line += " after a restorative day";
    else if (prior.stressSummary === "normal") line += " after a normal stress day";
    else if (prior.stressSummary) line += ` after a ${prior.stressSummary} day`;
    line += ".";
    if (prior.sleepScore != null && prior.sleepScore < SLEEP_HIT) {
      line += ` Prior-night sleep was below ${SLEEP_HIT}.`;
    }
    if (prior.readinessScore != null && prior.readinessScore < READINESS_HIT) {
      line += ` Morning ${labels.readiness} was below ${READINESS_HIT}.`;
    }
    parts.push(line);
  } else {
    parts.push(`No prior-night ${labels.provider} row for this morning yet.`);
  }
  if (labels.strain && prior?.strain != null) {
    parts.push(`Day ${labels.strain} reached ${prior.strain}.`);
  }

  const next = b.nextMorning;
  if (next?.sleepScore != null || next?.readinessScore != null) {
    const scores: string[] = [];
    if (next.sleepScore != null) scores.push(`sleep ${next.sleepScore}`);
    if (next.readinessScore != null) scores.push(`${labels.readiness} ${next.readinessScore}`);
    let line = `The night after (${labels.provider} morning ${b.join.nextMorningOuraDay}) landed at ${scores.join(" / ")}`;
    if (next.sleepScore != null && next.sleepScore < SLEEP_HIT) line += ` — below the sleep threshold of ${SLEEP_HIT}`;
    line += ".";
    parts.push(line);
  } else {
    parts.push(`Next-morning ${labels.provider} (D+1) is not in yet — nights×work join is pending.`);
  }

  return parts.join(" ");
}

export function buildDayBriefing(opts: {
  date: string;
  timeZone: string;
  joined: JoinedMeeting[];
  priorNight: OuraDaySlice | null;
  nextMorning: OuraDaySlice | null;
  hrByMeetingId?: Map<string, MeetingHrStress>;
  hrSeries?: DayHrPoint[];
  hrMethodNote?: string;
  labels?: BriefingLabels;
  /** Meetings left out for this day. Listed after the others, never counted. */
  excluded?: CalendarEventRow[];
}): DayBriefing {
  const { date, timeZone, joined, priorNight, nextMorning } = opts;
  const onDay = joined.filter((j) => calendarDayInZone(j.event.start_utc, timeZone) === date);
  const load = onDay[0]?.dayLoad ?? {
    day: date,
    eventCount: 0,
    totalDurationS: 0,
    afterHoursCount: 0,
    earlyStartCount: 0,
    clientCount: 0,
    byKind: {},
  };
  const flags: string[] = [];
  if (load.eventCount >= 5 || load.totalDurationS >= 5 * 3600 || load.clientCount >= 3) flags.push("heavy_day");
  if (load.afterHoursCount > 0) flags.push("after_hours");
  if (load.earlyStartCount > 0) flags.push("early_start");
  if (priorNight?.readinessScore != null && priorNight.readinessScore < READINESS_HIT) {
    flags.push("low_morning_readiness");
  }
  if (priorNight?.sleepScore != null && priorNight.sleepScore < SLEEP_HIT) flags.push("low_prior_sleep");
  if (nextMorning?.sleepScore != null && nextMorning.sleepScore < SLEEP_HIT) flags.push("low_next_sleep");
  if (priorNight?.stressSummary === "stressful") flags.push("stressful_day");

  const provider = (opts.labels ?? DEFAULT_BRIEFING_LABELS).provider;
  const join = {
    workDay: date,
    priorNightOuraDay: date,
    nextMorningOuraDay: onDay[0]?.signals.ouraMorningDay ?? ouraMorningDay(date),
    note: provider ? `Calendar load is work day D. Prior-night ${provider} is morning D (woke that day). Nights×work correlation uses ${provider} morning D+1.`
      : "Calendar load is grouped by local start day.",
  };
  const calendar = {
    ...load,
    events: onDay
      .map((r) => toMeetingJson(r, stressScore(r), opts.hrByMeetingId?.get(r.event.id) ?? null))
      .sort((a, b) => {
        const ah = a.hrStress?.coverage === "ok" ? (a.hrStress.impact ?? 0) : -1;
        const bh = b.hrStress?.coverage === "ok" ? (b.hrStress.impact ?? 0) : -1;
        if (bh !== ah) return bh - ah;
        return a.startUtc.localeCompare(b.startUtc);
      })
      .concat(
        (opts.excluded ?? [])
          .filter((event) => calendarDayInZone(event.start_utc, timeZone) === date)
          .sort((a, b) => a.start_utc.localeCompare(b.start_utc) || a.id.localeCompare(b.id))
          .map(toExcludedMeetingJson),
      ),
  };
  return {
    ok: true,
    date,
    timeZone,
    join,
    calendar,
    priorNight,
    nextMorning,
    flags,
    summary: composeDaySummary({ date, calendar, priorNight, nextMorning, join, labels: opts.labels }),
    hr: opts.hrSeries
      ? {
          source: "Oura" as const,
          method: "heartrate_proxy",
          methodNote: opts.hrMethodNote ?? GRAIN_NOTE.stress,
          series: opts.hrSeries,
        }
      : null,
  };
}

export type WeekMeetingDay = {
  day: string;
  meetings: MeetingJson[];
};

export type WeekHardest = {
  id: string;
  title: string | null;
  day: string;
  startLocal: string | null;
  headline: string;
  impact: number;
};

export type WeekBriefing = {
  ok: true;
  date: string;
  weekStart: string;
  weekEnd: string;
  /** Inclusive Monday–Sunday of the selected day. */
  weekDays: "monday_sunday";
  timeZone: string;
  summary: {
    meetingCount: number;
    elevated: number;
    watching: number;
    restored: number;
    noHr: number;
    combinedHr?: number;
    hardest: WeekHardest | null;
    line: string;
  };
  days: WeekMeetingDay[];
};

export function zoneBucket(hr: MeetingJson["hrStress"]): "elevated" | "watching" | "restored" | "none" {
  if (!hr || hr.coverage !== "ok" || !hr.zone) return "none";
  if (hr.zone === "high") return "elevated";
  if (hr.zone === "moderate") return "watching";
  return "restored";
}

export function composeWeekSummary(opts: {
  meetingCount: number;
  elevated: number;
  watching: number;
  restored: number;
  noHr: number;
  combinedHr?: number;
  hardest: WeekHardest | null;
  /** False when the wearable has no heart-rate fine enough to slice per meeting. */
  intradayHr?: boolean;
  totalDurationS?: number;
}): string {
  if (opts.meetingCount === 0) return "No calendar meetings this week.";
  if (opts.intradayHr === false) {
    const hours = Math.round(((opts.totalDurationS ?? 0) / 3600) * 10) / 10;
    return `${opts.meetingCount} ${opts.meetingCount === 1 ? "meeting" : "meetings"} this week, ${hours} ${hours === 1 ? "hour" : "hours"} in total.`;
  }
  const withHr = opts.elevated + opts.watching + opts.restored;
  if (withHr === 0 && !opts.combinedHr) {
    return `${opts.meetingCount} ${opts.meetingCount === 1 ? "meeting" : "meetings"} this week. No ring HR in those windows — we will not invent a signal.`;
  }
  const bits = [
    `${opts.elevated} elevated`,
    `${opts.watching} worth watching`,
    `${opts.restored} restored`,
  ];
  if (opts.combinedHr) bits.push(`${opts.combinedHr} with WHOOP + Oura heart rate`);
  let line = `${bits.join(", ")} this week.`;
  if (opts.hardest) {
    const when = formatBriefingDay(opts.hardest.day);
    const title = opts.hardest.title?.trim() || "Untitled meeting";
    line += ` Highest: ${title} on ${when}.`;
  }
  return line;
}

export function buildWeekBriefing(opts: {
  date: string;
  timeZone: string;
  weekStart: string;
  weekEnd: string;
  joined: JoinedMeeting[];
  hrByMeetingId?: Map<string, MeetingHrStress>;
  /** Pass false for a wearable without per-meeting heart-rate. Default true. */
  intradayHr?: boolean;
}): WeekBriefing {
  const { date, timeZone, weekStart, weekEnd, joined } = opts;
  const meetings = joined
    .filter((j) => {
      const day = calendarDayInZone(j.event.start_utc, timeZone);
      return day >= weekStart && day <= weekEnd;
    })
    .map((r) => toMeetingJson(r, stressScore(r), opts.hrByMeetingId?.get(r.event.id) ?? null))
    .sort((a, b) => a.startUtc.localeCompare(b.startUtc) || a.id.localeCompare(b.id));

  let elevated = 0;
  let watching = 0;
  let restored = 0;
  let noHr = 0;
  let combinedHr = 0;
  let hardestJson: MeetingJson | null = null;
  for (const m of meetings) {
    const bucket = zoneBucket(m.hrStress);
    if (bucket === "elevated") elevated += 1;
    else if (bucket === "watching") watching += 1;
    else if (bucket === "restored") restored += 1;
    else if (m.hrStress?.coverage === "ok") combinedHr += 1;
    else noHr += 1;
    if (bucket === "elevated" || bucket === "watching") {
      const impact = m.hrStress?.impact ?? 0;
      if (!hardestJson || impact > (hardestJson.hrStress?.impact ?? 0)) hardestJson = m;
    }
  }

  const hardest: WeekHardest | null = hardestJson
    ? {
        id: hardestJson.id,
        title: hardestJson.title,
        day: hardestJson.day,
        startLocal: hardestJson.startLocal,
        headline: hardestJson.hrStress?.headline ?? "Elevated",
        impact: hardestJson.hrStress?.impact ?? 0,
      }
    : null;

  const byDay = new Map<string, MeetingJson[]>();
  for (const m of meetings) {
    const list = byDay.get(m.day) ?? [];
    list.push(m);
    byDay.set(m.day, list);
  }
  const days: WeekMeetingDay[] = [...byDay.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([day, list]) => ({ day, meetings: list }));

  return {
    ok: true,
    date,
    weekStart,
    weekEnd,
    weekDays: "monday_sunday",
    timeZone,
    summary: {
      meetingCount: meetings.length,
      elevated,
      watching,
      restored,
      noHr,
      ...(combinedHr ? { combinedHr } : {}),
      hardest,
      line: composeWeekSummary({
        meetingCount: meetings.length,
        elevated,
        watching,
        restored,
        noHr,
        combinedHr,
        hardest,
        intradayHr: opts.intradayHr,
        totalDurationS: meetings.reduce((s, m) => s + m.durationS, 0),
      }),
    },
    days,
  };
}

export const GRAIN_NOTE = {
  join: "work day D → Oura sleep/readiness on morning D+1",
  stress:
    "Same-day Oura stress is the whole day. Stress during a meeting uses heart-rate from your ring in that window — not Oura's daytime stress score. If the ring saved nothing, we say so.",
  afterHours: "start ≥ 18:00 local",
  earlyStart: "start < 08:00 local",
  week: "Week in review is Monday–Sunday in America/New_York, the week that contains the selected day.",
  range: "A date range is inclusive local days. Meetings are keyed by local start day; recovery averages use the mornings inside the range.",
} as const;

/** The same notes, worded for the active wearable. With no labels this is `GRAIN_NOTE`. */
export function grainNote(labels: BriefingLabels = DEFAULT_BRIEFING_LABELS): Record<keyof typeof GRAIN_NOTE, string> {
  if (!labels.provider) return {
    ...GRAIN_NOTE,
    join: "Meetings are grouped by local start day.",
    stress: "Wearable display is off.",
    range: "A date range is inclusive local days.",
  };
  if (labels.intradayHr && labels.provider === DEFAULT_BRIEFING_LABELS.provider && (!labels.hrProvider || labels.hrProvider === "Oura")) return GRAIN_NOTE;
  return {
    ...GRAIN_NOTE,
    join: `work day D → ${labels.provider} sleep/${labels.readiness} on morning D+1`,
    stress: labels.intradayHr
      ? `Stress during a meeting uses heart-rate from ${labels.hrProvider ?? labels.provider} in that window. If it saved nothing, we say so.`
      : `${labels.provider} does not share heart rate during the day, so there is no per-meeting stress reading. Days are compared by ${labels.readiness}${labels.strain ? `, ${labels.strain}` : ""} and meeting load.`,
  };
}
