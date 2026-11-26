/**
 * "Your usual" numbers and the heavy-day comparison for the dashboard.
 *
 * Pure: the route loads meetings and wearable slices once, turns them into
 * DayRow[] with buildDayRows, and everything here works from that. Nothing
 * names a wearable brand; a missing score is null and is left out of medians.
 */
import { historyDays } from "./date-range.ts";
import type { CalendarEventRow } from "../types.ts";
import type { OuraDaySlice } from "../sources/calendar/join.ts";
import { addCalendarDays, calendarDayInZone } from "./time.ts";
import { otherAttendees, parseAttendeesJson } from "./people.ts";

export type DaySlice = Pick<OuraDaySlice, "sleepScore" | "readinessScore" | "avgHrv" | "lowestHr"> & {
  strain?: number | null;
};

export type DayRow = {
  day: string;
  /** Monday to Friday. */
  weekday: boolean;
  meetingCount: number;
  meetingS: number;
  afterHours: number;
  /** Scores from the morning of this day: how you woke up. */
  morning: DaySlice | null;
  /** Scores from the morning after: what the day cost. */
  next: DaySlice | null;
  people: Array<{ email: string; name: string | null; meetings: number }>;
};

/** A day counts as heavy at 4 or more hours of meetings, or 5 or more meetings. */
export const HEAVY_HOURS = 4;
export const HEAVY_MEETINGS = 5;

export function isHeavy(row: Pick<DayRow, "meetingS" | "meetingCount">): boolean {
  return row.meetingS >= HEAVY_HOURS * 3600 || row.meetingCount >= HEAVY_MEETINGS;
}

function slice(s: OuraDaySlice | undefined): DaySlice | null {
  if (!s) return null;
  return {
    sleepScore: s.sleepScore,
    readinessScore: s.readinessScore,
    avgHrv: s.avgHrv,
    lowestHr: s.lowestHr,
    strain: s.strain ?? null,
  };
}

function isWeekday(day: string): boolean {
  const wd = new Date(`${day}T12:00:00.000Z`).getUTCDay();
  return wd >= 1 && wd <= 5;
}

function localHour(event: Pick<CalendarEventRow, "start_local">): number | null {
  const m = /T(\d{2}):/.exec(event.start_local ?? "");
  return m ? Number(m[1]) : null;
}

/** Inclusive day rows. Extra-wide ranges omit empty days. */
export function buildDayRows(
  events: CalendarEventRow[],
  byDay: Map<string, OuraDaySlice>,
  from: string,
  to: string,
  timeZone: string,
): DayRow[] {
  const rows = new Map<string, DayRow>();
  const people = new Map<string, Map<string, { email: string; name: string | null; meetings: number }>>();
  const datedEvents = events.map((event) => ({ event, day: calendarDayInZone(event.start_utc, timeZone) }));
  const dateList = historyDays(from, to, [
    ...datedEvents.map(({ day }) => day),
    ...[...byDay.keys()].flatMap((day) => [day, addCalendarDays(day, -1)]),
  ]);
  for (const d of dateList) {
    rows.set(d, {
      day: d,
      weekday: isWeekday(d),
      meetingCount: 0,
      meetingS: 0,
      afterHours: 0,
      morning: slice(byDay.get(d)),
      next: slice(byDay.get(addCalendarDays(d, 1))),
      people: [],
    });
    people.set(d, new Map());
  }
  const seen = new Set<string>();
  for (const { event: e, day } of datedEvents) {
    if (seen.has(e.id)) continue;
    seen.add(e.id);
    const row = rows.get(day);
    if (!row) continue;
    row.meetingCount += 1;
    const s = Math.max(0, (Date.parse(e.end_utc) - Date.parse(e.start_utc)) / 1000);
    row.meetingS += Number.isFinite(s) ? s : e.duration_s ?? 0;
    const h = localHour(e);
    if (e.after_hours || (h != null && h >= 18)) row.afterHours += 1;
    const byEmail = people.get(day)!;
    for (const a of otherAttendees(parseAttendeesJson(e.attendees_json))) {
      if (!a.email) continue;
      const p = byEmail.get(a.email) ?? { email: a.email, name: a.name ?? null, meetings: 0 };
      p.meetings += 1;
      if (!p.name && a.name) p.name = a.name;
      byEmail.set(a.email, p);
    }
  }
  for (const [day, byEmail] of people) rows.get(day)!.people = [...byEmail.values()];
  return [...rows.values()];
}

export function median(values: Array<number | null | undefined>): number | null {
  const xs = values.filter((v): v is number => typeof v === "number" && Number.isFinite(v)).sort((a, b) => a - b);
  if (!xs.length) return null;
  const mid = Math.floor(xs.length / 2);
  return xs.length % 2 ? xs[mid] : (xs[mid - 1] + xs[mid]) / 2;
}

function mean(values: Array<number | null | undefined>): number | null {
  const xs = values.filter((v): v is number => typeof v === "number" && Number.isFinite(v));
  return xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null;
}

function round(n: number | null, places = 0): number | null {
  if (n == null) return null;
  const f = 10 ** places;
  return Math.round(n * f) / f;
}

export type Usual = {
  from: string;
  to: string;
  days: number;
  recovery: number | null;
  sleep: number | null;
  hrv: number | null;
  restingHr: number | null;
  strain: number | null;
  /** Median hours of meetings on a weekday. */
  meetingHours: number | null;
  /** Mean meetings after 6 pm per weekday. */
  afterHours: number | null;
};

/** Medians over the window. Morning scores belong to the day you woke up. */
export function buildUsual(rows: DayRow[]): Usual {
  const weekdays = rows.filter((r) => r.weekday);
  return {
    from: rows[0]?.day ?? "",
    to: rows[rows.length - 1]?.day ?? "",
    days: rows.length,
    recovery: round(median(rows.map((r) => r.morning?.readinessScore))),
    sleep: round(median(rows.map((r) => r.morning?.sleepScore))),
    hrv: round(median(rows.map((r) => r.morning?.avgHrv))),
    restingHr: round(median(rows.map((r) => r.morning?.lowestHr))),
    strain: round(median(rows.map((r) => r.morning?.strain)), 1),
    meetingHours: round(median(weekdays.map((r) => r.meetingS / 3600)), 1),
    afterHours: round(mean(weekdays.map((r) => r.afterHours)), 1),
  };
}

export type HeavyEffect = {
  heavyHours: number;
  heavyMeetings: number;
  heavy: { days: number; nextRecovery: number | null };
  lighter: { days: number; nextRecovery: number | null };
  /** lighter minus heavy next-morning recovery, in points. Null unless both sides have scores. */
  cost: number | null;
};

/**
 * Next-morning recovery after heavy days against every other day in `rows`
 * that has a next-morning score.
 */
export function heavyEffect(rows: DayRow[]): HeavyEffect {
  const scored = rows.filter((r) => r.next?.readinessScore != null);
  const heavy = scored.filter(isHeavy);
  const lighter = scored.filter((r) => !isHeavy(r));
  const h = round(mean(heavy.map((r) => r.next!.readinessScore)));
  const l = round(mean(lighter.map((r) => r.next!.readinessScore)));
  return {
    heavyHours: HEAVY_HOURS,
    heavyMeetings: HEAVY_MEETINGS,
    heavy: { days: heavy.length, nextRecovery: h },
    lighter: { days: lighter.length, nextRecovery: l },
    cost: h != null && l != null ? l - h : null,
  };
}

function hasScore(s: DaySlice | null | undefined): boolean {
  return Boolean(s) && [s!.readinessScore, s!.sleepScore, s!.avgHrv, s!.lowestHr, s!.strain]
    .some((v) => typeof v === "number" && Number.isFinite(v));
}

export type AllHistoryBaseline = {
  usual: Usual;
  effect: HeavyEffect & { from: string; to: string };
};

/**
 * One wearable's numbers over all history, for Ask. `rows` run from the history start to
 * today and are built from this wearable's own scores only.
 * - Score medians use every day this wearable scored; from/to are its first and last scored day.
 * - Meeting hours and the heavy-day comparison only use days from the first meeting's day to
 *   the last finished day (before `today`), so days before the calendar was connected do not
 *   count as light days and today never counts.
 */
export function buildAllHistoryBaseline(rows: DayRow[], firstMeetingDay: string | null, today: string): AllHistoryBaseline {
  const inWindow = rows.filter((r) => r.day <= today);
  const scored = inWindow.filter((r) => hasScore(r.morning));
  const meetingRows = firstMeetingDay ? inWindow.filter((r) => r.day >= firstMeetingDay && r.day < today) : [];
  const usual = buildUsual(inWindow);
  const meetings = buildUsual(meetingRows);
  const compared = meetingRows.filter((r) => r.next?.readinessScore != null);
  return {
    usual: {
      ...usual,
      from: scored[0]?.day ?? "",
      to: scored[scored.length - 1]?.day ?? "",
      meetingHours: meetings.meetingHours,
      afterHours: meetings.afterHours,
    },
    effect: { ...heavyEffect(meetingRows), from: compared[0]?.day ?? "", to: compared[compared.length - 1]?.day ?? "" },
  };
}

export type CostlyDay = {
  day: string;
  meetingCount: number;
  meetingHours: number;
  afterHours: number;
  nextRecovery: number;
  nextSleep: number | null;
};

/** Days with meetings, lowest next-morning recovery first. */
export function costliestDays(rows: DayRow[], limit = 3): CostlyDay[] {
  return rows
    .filter((r) => r.meetingCount > 0 && r.next?.readinessScore != null)
    .sort((a, b) => a.next!.readinessScore! - b.next!.readinessScore! || b.meetingS - a.meetingS)
    .slice(0, limit)
    .map((r) => ({
      day: r.day,
      meetingCount: r.meetingCount,
      meetingHours: round(r.meetingS / 3600, 1) ?? 0,
      afterHours: r.afterHours,
      nextRecovery: r.next!.readinessScore!,
      nextSleep: r.next!.sleepScore,
    }));
}

export type HeavyDayPerson = { email: string; name: string | null; heavyDays: number; meetings: number };

/** People who were in meetings on heavy days, most heavy days first. */
export function peopleOnHeavyDays(rows: DayRow[], limit = 3): HeavyDayPerson[] {
  const byEmail = new Map<string, HeavyDayPerson>();
  for (const r of rows.filter(isHeavy)) {
    for (const p of r.people) {
      const cur = byEmail.get(p.email) ?? { email: p.email, name: p.name, heavyDays: 0, meetings: 0 };
      cur.heavyDays += 1;
      cur.meetings += p.meetings;
      if (!cur.name && p.name) cur.name = p.name;
      byEmail.set(p.email, cur);
    }
  }
  return [...byEmail.values()]
    .sort((a, b) => b.heavyDays - a.heavyDays || b.meetings - a.meetings || a.email.localeCompare(b.email))
    .slice(0, limit);
}
