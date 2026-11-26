import { FIRST_CALENDAR_DAY, parseDateRange, type DateRangeQuery } from "./date-range.ts";
import { addCalendarDays, calendarDayInZone } from "./time.ts";
import type { WearableSource } from "../types.ts";

export async function loadHistoryStart(
  db: D1Database, source: WearableSource | null, timeZone: string, end: string, secondarySource: WearableSource | null = source,
) {
  const row = await db.prepare(
    `WITH sources(source) AS (VALUES (?), (?))
     SELECT (SELECT MIN(start_utc) FROM calendar_event WHERE deleted_at IS NULL) AS first_meeting,
       (SELECT MIN(day) FROM (
         SELECT MIN(day) AS day FROM daily_sleep WHERE source IN (SELECT source FROM sources) AND deleted_at IS NULL
         UNION ALL SELECT MIN(day) FROM daily_readiness WHERE source IN (SELECT source FROM sources) AND deleted_at IS NULL
         UNION ALL SELECT MIN(day) FROM daily_activity WHERE source IN (SELECT source FROM sources) AND deleted_at IS NULL
         UNION ALL SELECT MIN(day) FROM daily_stress WHERE source IN (SELECT source FROM sources) AND deleted_at IS NULL
         UNION ALL SELECT MIN(day) FROM daily_strain WHERE source IN (SELECT source FROM sources) AND deleted_at IS NULL
       )) AS first_metric`,
  ).bind(source, secondarySource).first<{ first_meeting: string | null; first_metric: string | null }>();
  const meeting = row?.first_meeting ? calendarDayInZone(row.first_meeting, timeZone) : end;
  return [meeting, row?.first_metric ?? end, end].sort()[0];
}

export function parseHistoryRange(query: DateRangeQuery, today: string, days: number) {
  return parseDateRange(query, { today, defaultSpanDays: days });
}

const NUMBER_WORDS = [
  "", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
];

/** "all time", "of all time", "all my history", "all history", "since the beginning". */
const ALL_HISTORY_PHRASE = /\b(?:all[\s-]+time|all\s+(?:my\s+)?history|since\s+the\s+beginning)\b/i;
/** A bare "ever" as a word: not every, never, however or forever, and not "ever since". */
const BARE_EVER = /\bever\b(?!\s+since\b)/i;

/**
 * The dates a question asks about: a range, "all" for all history, or null for no period.
 * An all-history phrase beats a period; a period beats a bare "ever" ("worst ever this month").
 */
export function questionPeriod(question: string, today: string): { start: string; end: string } | "all" | null {
  if (ALL_HISTORY_PHRASE.test(question)) return "all";
  const range = questionRange(question, today);
  if (range) return range;
  return BARE_EVER.test(question) ? "all" : null;
}

/** Common rolling periods in Ask questions, using calendar months and years. */
export function questionRange(question: string, today: string): { start: string; end: string } | null {
  if (/\bthis month\b/i.test(question)) return { start: `${today.slice(0, 7)}-01`, end: today };
  if (/\bthis year\b/i.test(question)) return { start: `${today.slice(0, 4)}-01-01`, end: today };
  const match = /\b(?:past|last)\s+(?:(\d+|[a-z]+)\s+)?(days?|weeks?|months?|years?)\b/i.exec(question.toLowerCase());
  if (!match) return null;
  const [, raw, unit] = match;
  const count = !raw || raw === "a" || raw === "an" ? 1 : /^\d+$/.test(raw) ? Number(raw) : NUMBER_WORDS.indexOf(raw);
  if (count < 1) return null;
  if (unit.startsWith("day") || unit.startsWith("week")) {
    const range = parseHistoryRange({}, today, count * (unit.startsWith("week") ? 7 : 1));
    return "error" in range ? null : { start: range.start, end: today };
  }

  const [y, m, d] = today.split("-").map(Number);
  const month = Math.max(100 * 12, y * 12 + m - 1 - count * (unit.startsWith("year") ? 12 : 1));
  const first = new Date(Date.UTC(Math.floor(month / 12), month % 12, 1));
  const firstNext = new Date(first);
  firstNext.setUTCMonth(first.getUTCMonth() + 1);
  const last = new Date(firstNext.getTime() - 86_400_000).getUTCDate();
  first.setUTCDate(Math.min(d, last));
  const start = first.toISOString().slice(0, 10);
  return { start: start === FIRST_CALENDAR_DAY ? start : addCalendarDays(start, 1), end: today };
}
