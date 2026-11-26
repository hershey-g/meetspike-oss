import { addCalendarDays } from "./time.ts";
import { isEarlyStart } from "../sources/calendar/join.ts";
import type { CalendarEventRow } from "../types.ts";
import type { DailyMetricPoint } from "./daily-metrics.ts";
import { isHrSpike, type MeetingHrStress } from "./heartrate.ts";
import { otherAttendees, parseAttendeesJson, attendeesIdentityNote, type Attendee } from "./people.ts";
import { normalizeSourceType, type EventSourceType } from "./source-type.ts";

export const INSIGHTS_MIN_DAYS = 7;
export const INSIGHTS_DEFAULT_DAYS = 28;
export const INSIGHTS_HIT_LIMIT = 8;

/** Ignore tiny wiggles so the feed is not every day. */
export const MIN_SLEEP_BELOW = 5;
export const MIN_READY_BELOW = 5;
export const MIN_STRESS_HOURS_ABOVE = 0.75;

export type InsightBadge = "worse than usual" | "typical" | "better";

export type InsightMeeting = {
  id: string;
  title: string | null;
  kind: string;
  day: string;
  startLocal: string | null;
  afterHours: boolean;
  earlyStart: boolean;
  durationS: number;
  attendees: Attendee[];
  attendeeNote: string | null;
  sourceType: EventSourceType;
};

export type InsightBaseline = {
  windowDays: number;
  nSleep: number;
  nReady: number;
  nStress: number;
  sleepScore: number | null;
  readinessScore: number | null;
  stressHighS: number | null;
  stressHighHours: number | null;
  note: string;
};

export type InsightCompare = {
  key: "nextSleep" | "nextReadiness" | "stressHours";
  label: string;
  value: number | null;
  median: number | null;
  delta: number | null;
  worse: boolean;
};

export type InsightHit = {
  kind: "meeting" | "day";
  id: string;
  day: string;
  title: string;
  startLocal: string | null;
  afterHours: boolean;
  earlyStart: boolean;
  meetingKind: string | null;
  sentence: string;
  badge: InsightBadge;
  /** Ranking key only: in-meeting HR impact, then sleep/readiness after-effects. */
  impact: number;
  compare: InsightCompare[];
  hrStress: MeetingHrStress | null;
  attendees: Attendee[];
  attendeeNote: string | null;
  sourceType: EventSourceType;
};

/** Words the insight copy needs from the wearable. Defaults read as Oura. */
export type InsightLabels = {
  provider: string;
  /** Lower-case name of the morning score, e.g. "readiness" or "recovery". */
  readiness: string;
  /** False when the wearable has no heart-rate fine enough to slice per meeting. */
  intradayHr: boolean;
  hrProvider?: string | null;
};

export const DEFAULT_INSIGHT_LABELS: InsightLabels = { provider: "Oura", readiness: "readiness", intradayHr: true };

function hoursFromS(s: number | null | undefined): number | null {
  if (s == null) return null;
  return Math.round((s / 3600) * 10) / 10;
}

export function median(values: number[]): number | null {
  const xs = values.filter((n) => Number.isFinite(n)).sort((a, b) => a - b);
  if (!xs.length) return null;
  const mid = Math.floor(xs.length / 2);
  if (xs.length % 2 === 1) return xs[mid];
  return Math.round(((xs[mid - 1] + xs[mid]) / 2) * 10) / 10;
}

export function parseInsightsDays(raw: string | undefined): number {
  const n = Number(raw ?? INSIGHTS_DEFAULT_DAYS);
  if (!Number.isFinite(n)) return INSIGHTS_DEFAULT_DAYS;
  return Math.max(INSIGHTS_MIN_DAYS, Math.round(n));
}

export function buildBaseline(
  days: DailyMetricPoint[],
  windowDays: number,
  /** Explicit range the baseline was computed over. Omit for "the last N days". */
  span?: { from: string; to: string },
  labels: InsightLabels = DEFAULT_INSIGHT_LABELS,
): InsightBaseline {
  const usual = span
    ? `Your usual from ${formatHitDay(span.from)} to ${formatHitDay(span.to)} (${windowDays} ${windowDays === 1 ? "day" : "days"}).`
    : `Your usual from the last ${windowDays} days.`;
  const sleep = median(days.map((d) => d.sleepScore).filter((n): n is number => n != null));
  const ready = median(days.map((d) => d.readinessScore).filter((n): n is number => n != null));
  const stress = median(days.map((d) => d.stressHighS).filter((n): n is number => n != null));
  return {
    windowDays,
    nSleep: days.filter((d) => d.sleepScore != null).length,
    nReady: days.filter((d) => d.readinessScore != null).length,
    nStress: days.filter((d) => d.stressHighS != null).length,
    sleepScore: sleep,
    readinessScore: ready,
    stressHighS: stress,
    stressHighHours: hoursFromS(stress),
    note: !labels.provider ? "Wearable display is off." : !labels.intradayHr
      ? `${usual} A work day is compared to the next morning. ${labels.provider} does not share heart rate during the day, so days are ranked by the sleep and ${labels.readiness} that followed.`
      : labels.hrProvider && labels.hrProvider !== "Oura"
        ? `${usual} A work day is compared to the next morning. Meeting heart rate comes from ${labels.hrProvider}.`
        : span
          ? `${usual} A work day is compared to the next morning. In-meeting stress uses ring heart-rate during the call — not a daytime stress score.`
          : `${usual} A work day is compared to the next morning. In-meeting stress uses ring heart-rate during the call — not Oura's daytime stress score.`,
  };
}

export function toInsightMeeting(event: CalendarEventRow): InsightMeeting {
  let earlyStart = false;
  if (event.start_local) {
    const m = /T(\d{2}):(\d{2})/.exec(event.start_local);
    if (m) earlyStart = isEarlyStart(Number(m[1]), Number(m[2]));
  }
  return {
    id: event.id,
    title: event.title,
    kind: event.kind,
    day: event.day,
    startLocal: event.start_local,
    afterHours: Boolean(event.after_hours),
    earlyStart,
    durationS: event.duration_s,
    attendees: otherAttendees(parseAttendeesJson(event.attendees_json)),
    attendeeNote: attendeesIdentityNote(parseAttendeesJson(event.attendees_json)),
    sourceType: normalizeSourceType(event.source_type),
  };
}

export function pickNotableMeeting(meetings: InsightMeeting[]): InsightMeeting | null {
  if (!meetings.length) return null;
  const scored = [...meetings].sort((a, b) => {
    const rank = (m: InsightMeeting) =>
      (m.afterHours ? 4 : 0) + (m.earlyStart ? 3 : 0) + (m.kind === "client" ? 2 : 0) + m.durationS / 100_000;
    return rank(b) - rank(a);
  });
  return scored[0] ?? null;
}

export function meetingsThatMatter(meetings: InsightMeeting[], limit = 3): InsightMeeting[] {
  const notable = meetings.filter((m) => m.afterHours || m.earlyStart || m.kind === "client");
  const pool = notable.length ? notable : [...meetings].sort((a, b) => b.durationS - a.durationS);
  return pool.slice(0, limit);
}

function compareAxis(
  key: InsightCompare["key"],
  label: string,
  value: number | null,
  medianValue: number | null,
  higherIsWorse: boolean,
): InsightCompare {
  let delta: number | null = null;
  if (value != null && medianValue != null) {
    delta = Math.round((value - medianValue) * 10) / 10;
  }
  const worse =
    delta != null && (higherIsWorse ? delta > 0 : delta < 0);
  return { key, label, value, median: medianValue, delta, worse };
}

export function dayCompare(
  work: DailyMetricPoint | undefined,
  next: DailyMetricPoint | undefined,
  baseline: InsightBaseline,
  labels: InsightLabels = DEFAULT_INSIGHT_LABELS,
): InsightCompare[] {
  return [
    compareAxis("nextSleep", "Next-night sleep", next?.sleepScore ?? null, baseline.sleepScore, false),
    compareAxis(
      "nextReadiness",
      `Next-morning ${labels.readiness}`,
      next?.readinessScore ?? null,
      baseline.readinessScore,
      false,
    ),
    compareAxis(
      "stressHours",
      "Same-day stress high",
      hoursFromS(work?.stressHighS ?? null),
      baseline.stressHighHours,
      true,
    ),
  ];
}

export function briefingCompare(
  prior: { sleepScore: number | null; readinessScore: number | null; stressHighS: number | null } | null,
  next: { sleepScore: number | null; readinessScore: number | null } | null,
  baseline: InsightBaseline,
): { woke: InsightCompare[]; next: InsightCompare[]; stress: InsightCompare } {
  const wokeSleep = compareAxis("nextSleep", "Woke — sleep", prior?.sleepScore ?? null, baseline.sleepScore, false);
  const wokeReady = compareAxis(
    "nextReadiness",
    "Woke — readiness",
    prior?.readinessScore ?? null,
    baseline.readinessScore,
    false,
  );
  const stress = compareAxis(
    "stressHours",
    "Same-day stress high",
    hoursFromS(prior?.stressHighS ?? null),
    baseline.stressHighHours,
    true,
  );
  const nextSleep = compareAxis("nextSleep", "Next-night sleep", next?.sleepScore ?? null, baseline.sleepScore, false);
  const nextReady = compareAxis(
    "nextReadiness",
    "Next-morning readiness",
    next?.readinessScore ?? null,
    baseline.readinessScore,
    false,
  );
  return { woke: [wokeSleep, wokeReady], next: [nextSleep, nextReady], stress };
}

export function badgeFor(compares: InsightCompare[]): InsightBadge {
  const known = compares.filter((c) => c.delta != null);
  if (!known.length) return "typical";
  const hit = known.some((c) => isMeaningfulHit(c));
  if (hit) return "worse than usual";
  const allBetter = known.every((c) => {
    if (c.key === "stressHours") return (c.delta ?? 0) < 0;
    return (c.delta ?? 0) > 0;
  });
  return allBetter ? "better" : "typical";
}

export function isMeaningfulHit(c: InsightCompare): boolean {
  if (c.delta == null || c.value == null || c.median == null) return false;
  if (c.key === "stressHours") return c.delta >= MIN_STRESS_HOURS_ABOVE;
  if (c.key === "nextSleep") return c.delta <= -MIN_SLEEP_BELOW;
  return c.delta <= -MIN_READY_BELOW;
}

export function composeHitSentence(compares: InsightCompare[], labels: InsightLabels = DEFAULT_INSIGHT_LABELS): string {
  const bits: string[] = [];
  for (const c of compares) {
    if (!isMeaningfulHit(c) || c.delta == null || c.value == null || c.median == null) continue;
    if (c.key === "nextSleep") {
      bits.push(`Next-night sleep ${Math.abs(c.delta)} below your median`);
    } else if (c.key === "nextReadiness") {
      bits.push(`Next-morning ${labels.readiness} ${Math.abs(c.delta)} below your median`);
    } else {
      bits.push(`same-day stress ${c.delta}h above usual`);
    }
  }
  if (!bits.length) {
    const pending = compares.filter((c) => c.value == null);
    if (pending.length === compares.length) return `${labels.provider} for this join is not in yet.`;
    return "Close to your usual — not a standout hit.";
  }
  const head = bits[0];
  const rest = bits.slice(1).map((s) => s.charAt(0).toLowerCase() + s.slice(1));
  if (!rest.length) return `${head}.`;
  return `${head}; ${rest.join("; ")}.`;
}

function impactOf(compares: InsightCompare[]): number {
  let n = 0;
  for (const c of compares) {
    if (!isMeaningfulHit(c) || c.delta == null) continue;
    if (c.key === "stressHours") n += c.delta * 10;
    else n += Math.abs(c.delta);
  }
  return Math.round(n * 10) / 10;
}

export function formatHitDay(day: string): string {
  return new Date(`${day}T12:00:00.000Z`).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });
}

/** Plain titles only — never “thin night” / “heavy calendar day”. */
export function fallbackHitTitle(onDay: InsightMeeting[], day: string, recoveryHit: boolean): string {
  const notable = pickNotableMeeting(onDay);
  const named = notable?.title?.trim();
  if (named) return named;
  if (onDay.length) return `Meetings on ${formatHitDay(day)}`;
  return recoveryHit ? "Quiet calendar — still a hard recovery day" : "No calendar meeting that day";
}

export function composeMeetingHrSentence(hr: MeetingHrStress, compares: InsightCompare[]): string {
  if (hr.coverage === "none") {
    const after = composeHitSentence(compares);
    if (after.startsWith("Close to your usual") || after.startsWith("Oura for this join")) {
      return `${hr.headline}.`;
    }
    return `${hr.headline}. ${after}`;
  }
  const after = composeHitSentence(compares);
  if (after.startsWith("Close to your usual") || after.startsWith("Oura for this join")) {
    return `${hr.headline}. ${hr.story}`;
  }
  return `${hr.headline}. ${hr.story} ${after}`;
}

function badgeForHr(hr: MeetingHrStress, compares: InsightCompare[]): InsightBadge {
  if (hr.zone === "high" || compares.some(isMeaningfulHit)) return "worse than usual";
  if (hr.zone === "low" && !compares.some((c) => c.worse)) return "better";
  return "typical";
}

export function rankHits(opts: {
  days: DailyMetricPoint[];
  meetings: InsightMeeting[];
  baseline: InsightBaseline;
  from: string;
  to: string;
  limit?: number;
  hrByMeetingId?: Map<string, MeetingHrStress>;
  labels?: InsightLabels;
}): InsightHit[] {
  const labels = opts.labels ?? DEFAULT_INSIGHT_LABELS;
  const byDay = new Map(opts.days.map((d) => [d.day, d]));
  const meetingsByDay = new Map<string, InsightMeeting[]>();
  for (const m of opts.meetings) {
    const list = meetingsByDay.get(m.day) ?? [];
    list.push(m);
    meetingsByDay.set(m.day, list);
  }

  const hits: InsightHit[] = [];
  const usedDays = new Set<string>();

  if (opts.hrByMeetingId?.size) {
    for (const m of opts.meetings) {
      const hr = opts.hrByMeetingId.get(m.id);
      if (!hr || !isHrSpike(hr)) continue;
      const work = byDay.get(m.day);
      const next = byDay.get(addCalendarDays(m.day, 1));
      const compare = dayCompare(work, next, opts.baseline);
      const recovery = impactOf(compare);
      hits.push({
        kind: "meeting",
        id: m.id,
        day: m.day,
        title: m.title?.trim() || `Meeting on ${formatHitDay(m.day)}`,
        startLocal: m.startLocal,
        afterHours: m.afterHours,
        earlyStart: m.earlyStart,
        meetingKind: m.kind,
        sentence: composeMeetingHrSentence(hr, compare),
        badge: badgeForHr(hr, compare),
        impact: Math.round((hr.impact * 2 + recovery) * 10) / 10,
        compare,
        hrStress: hr,
        attendees: m.attendees,
        attendeeNote: m.attendeeNote,
        sourceType: m.sourceType,
      });
      usedDays.add(m.day);
    }
  }

  for (let day = opts.from; day <= opts.to; day = addCalendarDays(day, 1)) {
    if (usedDays.has(day)) continue;
    const work = byDay.get(day);
    const next = byDay.get(addCalendarDays(day, 1));
    const compare = dayCompare(work, next, opts.baseline, labels);
    if (!compare.some(isMeaningfulHit)) continue;
    const onDay = meetingsByDay.get(day) ?? [];
    const notable = pickNotableMeeting(onDay);
    const title = fallbackHitTitle(onDay, day, true);
    const hr = notable && opts.hrByMeetingId ? (opts.hrByMeetingId.get(notable.id) ?? null) : null;
    hits.push({
      kind: notable ? "meeting" : "day",
      id: notable?.id ?? `day:${day}`,
      day,
      title,
      startLocal: notable?.startLocal ?? null,
      afterHours: Boolean(notable?.afterHours),
      earlyStart: Boolean(notable?.earlyStart),
      meetingKind: notable?.kind ?? null,
      sentence: hr ? composeMeetingHrSentence(hr, compare) : composeHitSentence(compare, labels),
      badge: "worse than usual",
      impact: impactOf(compare),
      compare,
      hrStress: hr,
      attendees: notable?.attendees ?? [],
      attendeeNote: notable?.attendeeNote ?? (onDay.length ? null : "No calendar meeting that day"),
      sourceType: notable?.sourceType ?? "calendar",
    });
  }

  return hits.sort((a, b) => b.impact - a.impact || b.day.localeCompare(a.day)).slice(0, opts.limit ?? INSIGHTS_HIT_LIMIT);
}
