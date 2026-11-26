import { addCalendarDays } from "./time.ts";

/** Bounds supported by the app's four-digit calendar dates. */
export const FIRST_CALENDAR_DAY = "0100-01-01";
const LAST_CALENDAR_DAY = "9999-12-30";

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

export type DateRange = {
  start: string;
  end: string;
  /** Inclusive day count: start === end is 1. */
  spanDays: number;
};

export type DateRangeError = { error: string };

export type DateRangeQuery = {
  start?: string | null;
  end?: string | null;
  /** Legacy single-day parameter. Equivalent to start = end = date. */
  date?: string | null;
};

export function isDateRangeError(r: DateRange | DateRangeError): r is DateRangeError {
  return "error" in r;
}

/** True only for a real calendar date written as YYYY-MM-DD (rejects 2026-02-30). */
export function isValidDay(day: unknown): day is string {
  if (typeof day !== "string" || !DAY_RE.test(day) || day < FIRST_CALENDAR_DAY || day > LAST_CALENDAR_DAY) return false;
  const d = new Date(`${day}T00:00:00.000Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === day;
}

/** Inclusive number of calendar days in [start, end]. Both must be valid days. */
export function spanDays(start: string, end: string): number {
  const a = Date.parse(`${start}T00:00:00.000Z`);
  const b = Date.parse(`${end}T00:00:00.000Z`);
  return Math.round((b - a) / 86_400_000) + 1;
}

/** Every calendar day in the inclusive range, ascending. */
export function daysInRange(start: string, end: string): string[] {
  const out: string[] = [];
  for (let day = start; day <= end; day = addCalendarDays(day, 1)) out.push(day);
  return out;
}

/**
 * Keep ordinary charts continuous. For unusually wide queries, emit the days
 * with records and the requested endpoints without allocating centuries of empty rows.
 */
export function historyDays(start: string, end: string, dataDays: Iterable<string>): string[] {
  if (spanDays(start, end) <= 3660) return daysInRange(start, end);
  return [...new Set([start, end, ...dataDays])].filter((day) => day >= start && day <= end).sort();
}

function present(v: string | null | undefined): v is string {
  return typeof v === "string" && v.trim() !== "";
}

/** Validate an already-resolved inclusive range. */
export function validateDateRange(
  start: string,
  end: string,
  maxSpanDays: number = Infinity,
  names: { start: string; end: string } = { start: "start", end: "end" },
): DateRange | DateRangeError {
  if (!isValidDay(start)) return { error: `${names.start} must be a valid YYYY-MM-DD date` };
  if (!isValidDay(end)) return { error: `${names.end} must be a valid YYYY-MM-DD date` };
  if (end < start) return { error: `${names.end} must be on or after ${names.start}` };
  const span = spanDays(start, end);
  if (span > maxSpanDays) {
    return { error: `range cannot exceed ${maxSpanDays} days (got ${span})` };
  }
  return { start, end, spanDays: span };
}

/**
 * Resolve `start` / `end` / `date` query parameters into one inclusive range.
 *
 * - `date` alone, `start` alone, or `end` alone is a one-day range.
 * - `start` + `end` is the span between them, inclusive.
 * - Nothing given falls back to `defaultSpanDays` ending on `today` (1 = today only).
 */
export function parseDateRange(
  query: DateRangeQuery,
  opts: { today: string; maxSpanDays?: number; defaultSpanDays?: number },
): DateRange | DateRangeError {
  const maxSpanDays = opts.maxSpanDays ?? Infinity;
  const start = present(query.start) ? query.start.trim() : null;
  const end = present(query.end) ? query.end.trim() : null;
  const date = present(query.date) ? query.date.trim() : null;

  if (date != null && (start != null || end != null)) {
    return { error: "use either date or start/end, not both" };
  }
  if (date != null) {
    if (!isValidDay(date)) return { error: "date must be a valid YYYY-MM-DD date" };
    return { start: date, end: date, spanDays: 1 };
  }
  if (start == null && end == null) {
    const span = Math.max(1, Math.min(maxSpanDays, spanDays(FIRST_CALENDAR_DAY, opts.today), Math.round(opts.defaultSpanDays ?? 1)));
    return validateDateRange(addCalendarDays(opts.today, -(span - 1)), opts.today, maxSpanDays);
  }
  // A lone bound is a one-day range.
  return validateDateRange(start ?? (end as string), end ?? (start as string), maxSpanDays);
}
