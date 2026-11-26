import { loadWithOverrides } from "../sources/calendar/query.ts";
import { median } from "./usual.ts";
import { otherAttendees, parseAttendeesJson } from "./people.ts";
import { addCalendarDays, calendarDayInZone } from "./time.ts";
import type { CalendarEventRow, WearableSource } from "../types.ts";

type PeopleEvent = Pick<CalendarEventRow, "id" | "source" | "start_utc" | "end_utc" | "title" | "attendees_json" | "source_type">;

/** Morning scores for a range plus the 28 days of "your usual" before its end, keyed by day. */
export async function loadMorningScores(
  db: D1Database, start: string, end: string, source: WearableSource | null,
): Promise<Map<string, number>> {
  if (source === null) return new Map();
  const usualStart = addCalendarDays(end, -27);
  const rows = await db.prepare(
    `SELECT day, score FROM daily_readiness
     WHERE source = ? AND day >= ? AND day <= ? AND deleted_at IS NULL AND score IS NOT NULL`,
  ).bind(source, start < usualStart ? start : usualStart, addCalendarDays(end, 1))
    .all<{ day: string; score: number }>().then((r) => r.results ?? []);
  return new Map(rows.map(({ day, score }) => [day, score]));
}

/** Average score on the mornings after these meeting days, rounded. Null without scores. */
export function nextMorningAverage(days: Iterable<string>, scores: ReadonlyMap<string, number>): number | null {
  let total = 0;
  let count = 0;
  for (const day of days) {
    const score = scores.get(addCalendarDays(day, 1));
    if (score == null) continue;
    total += score;
    count++;
  }
  return count ? Math.round(total / count) : null;
}

/** Median morning score over the 28 days ending on `end`. */
export function usualMorningScore(scores: ReadonlyMap<string, number>, end: string): number | null {
  const usualStart = addCalendarDays(end, -27);
  const usual = median([...scores].filter(([day]) => day >= usualStart && day <= end).map(([, score]) => score));
  return usual == null ? null : Math.round(usual);
}

export async function loadPeopleHistory(
  db: D1Database, start: string, end: string, tz: string, source: WearableSource | null,
) {
  // Meetings the owner left out do not count, and a changed time moves a meeting to its effective day.
  const [events, scores] = await Promise.all([
    loadWithOverrides<PeopleEvent>(db, start, end, tz, {}, "desc", async (span, ids) => {
      const args: unknown[] = [span.startUtc, span.endUtcExclusive];
      if (ids) args.push(JSON.stringify(ids));
      const res = await db.prepare(
        `SELECT id, source, start_utc, end_utc, title, attendees_json, source_type
         FROM calendar_event
         WHERE start_utc >= ? AND start_utc < ? AND deleted_at IS NULL AND attendees_json IS NOT NULL${
           ids ? " AND id IN (SELECT value FROM json_each(?))" : ""}
         ORDER BY start_utc DESC, id, source`,
      ).bind(...args).all<PeopleEvent>();
      return res.results ?? [];
    }),
    loadMorningScores(db, start, end, source),
  ]);
  const byEmail = new Map<string, { email: string; name: string | null; meetings: number; days: Set<string> }>();
  for (const event of events) {
    const day = calendarDayInZone(event.start_utc, tz);
    const seen = new Set<string>();
    for (const attendee of otherAttendees(parseAttendeesJson(event.attendees_json))) {
      if (seen.has(attendee.email)) continue;
      seen.add(attendee.email);
      const person = byEmail.get(attendee.email) ?? { email: attendee.email, name: null, meetings: 0, days: new Set() };
      person.name ??= attendee.name;
      person.meetings++;
      person.days.add(day);
      byEmail.set(person.email, person);
    }
  }
  const people = [...byEmail.values()]
    .sort((a, b) => b.meetings - a.meetings || (a.name ?? a.email).localeCompare(b.name ?? b.email))
    .slice(0, 30)
    .map(({ email, name, meetings, days }) => ({
      email, name, meetings, days: days.size, avg: nextMorningAverage(days, scores),
    }));
  return { people, usualRecovery: usualMorningScore(scores, end) };
}
