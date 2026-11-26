import type { Env } from "../env.ts";
import { SOURCE_OURA } from "../types.ts";
import { addCalendarDays, calendarDayInZone } from "./time.ts";
import { getRawJson } from "./r2.ts";
import {
  attachMeetingHr,
  downsampleDayHr,
  parseHeartrateDoc,
  samplesOnLocalDay,
  type DayHrPoint,
  type HrSample,
  type MeetingHrStress,
} from "./heartrate.ts";

export type HeartrateRawRow = {
  r2_key: string;
  day: string | null;
  document_id: string;
};

const HR_DOC_DAY = /^hr-(\d{4}-\d{2}-\d{2})/;
const R2_FETCH_CONCURRENCY = 8;
const LEGACY_WINDOW_DAYS = 7;

function legacyPage(row: HeartrateRawRow): boolean {
  return /-p\d+$/.test(row.document_id);
}

export function rawRowOverlapsDays(row: HeartrateRawRow, fromDay: string, toDay: string): boolean {
  if (row.day && row.day >= fromDay && row.day <= toDay) return true;
  const m = HR_DOC_DAY.exec(row.document_id);
  return Boolean(m && m[1] >= fromDay && m[1] <= toDay);
}

/** Meeting days plus ±1 so timezone-straddling HR docs still load. */
export function paddedHeartrateDays(days: string[]): string[] {
  const keep = new Set<string>();
  for (const day of days) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) continue;
    keep.add(addCalendarDays(day, -1));
    keep.add(day);
    keep.add(addCalendarDays(day, 1));
  }
  return [...keep].sort();
}

export function heartrateRowDay(row: HeartrateRawRow): string | null {
  if (row.day && /^\d{4}-\d{2}-\d{2}$/.test(row.day)) return row.day;
  const m = HR_DOC_DAY.exec(row.document_id);
  return m?.[1] ?? null;
}

export function filterHeartrateRowsForDays(rows: HeartrateRawRow[], days: string[]): HeartrateRawRow[] {
  const keep = new Set(paddedHeartrateDays(days));
  if (!keep.size) return [];
  return rows.filter((row) => {
    const day = heartrateRowDay(row);
    if (!day) return false;
    if (keep.has(day)) return true;
    return legacyPage(row) && days.some((meetingDay) => day < meetingDay && addCalendarDays(day, LEGACY_WINDOW_DAYS) >= meetingDay);
  });
}

export async function mapPool<T, R>(items: T[], concurrency: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  if (!items.length) return [];
  const limit = Math.max(1, Math.min(concurrency, items.length));
  const out: R[] = new Array(items.length);
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const i = next;
      next += 1;
      out[i] = await fn(items[i]);
    }
  }
  await Promise.all(Array.from({ length: limit }, () => worker()));
  return out;
}

export async function listHeartrateRaw(
  db: D1Database,
  fromDay: string,
  toDay: string,
): Promise<HeartrateRawRow[]> {
  const from = addCalendarDays(fromDay, -LEGACY_WINDOW_DAYS);
  const to = addCalendarDays(toDay, 1);
  const fromDoc = `hr-${from}`;
  const toDoc = `hr-${addCalendarDays(to, 1)}`;
  const res = await db
    .prepare(
      `SELECT r2_key, day, document_id
       FROM raw_object AS hr
       WHERE source = ? AND endpoint = 'heartrate'
         AND (
           (day IS NOT NULL AND day >= ? AND day <= ?)
           OR (document_id >= ? AND document_id < ?)
         )
         AND (document_id NOT LIKE '%-daily' OR NOT EXISTS (
           SELECT 1 FROM raw_object AS newer
           WHERE newer.source = hr.source AND newer.endpoint = hr.endpoint
             AND newer.document_id = hr.document_id AND newer.id > hr.id
         ))
       ORDER BY fetched_at DESC, id DESC`,
    )
    .bind(SOURCE_OURA, from, to, fromDoc, toDoc)
    .all<HeartrateRawRow>();
  return (res.results ?? []).filter((row) =>
    rawRowOverlapsDays(row, legacyPage(row) ? from : addCalendarDays(fromDay, -1), to),
  );
}

async function samplesFromRows(env: Env, rows: HeartrateRawRow[]): Promise<HrSample[]> {
  const samples: HrSample[] = [];
  const seen = new Set<string>();
  const bodies = await mapPool(rows, R2_FETCH_CONCURRENCY, (row) => getRawJson(env, row.r2_key));
  for (const body of bodies) {
    if (!body) continue;
    let doc: unknown;
    try {
      doc = JSON.parse(body);
    } catch {
      continue;
    }
    for (const s of parseHeartrateDoc(doc)) {
      const key = `${s.timestampMs}:${s.source}`;
      if (seen.has(key)) continue;
      seen.add(key);
      samples.push(s);
    }
  }
  return samples.sort((a, b) => a.timestampMs - b.timestampMs);
}

export async function loadHeartrateSamples(env: Env, fromDay: string, toDay: string): Promise<HrSample[]> {
  const rows = await listHeartrateRaw(env.DB, fromDay, toDay);
  return samplesFromRows(env, rows);
}

/** Load only the days we need (plus a 1-day pad), not a sparse min→max span. */
export async function loadHeartrateSamplesForDays(env: Env, days: string[]): Promise<HrSample[]> {
  const padded = paddedHeartrateDays(days);
  if (!padded.length) return [];
  const rows = filterHeartrateRowsForDays(
    await listHeartrateRaw(env.DB, addCalendarDays(padded[0], 1), addCalendarDays(padded[padded.length - 1], -1)),
    days,
  );
  return samplesFromRows(env, rows);
}

export async function loadMeetingHrMap(
  env: Env,
  meetings: Array<{ id: string; startUtc: string; endUtc: string; day: string }>,
  lowestHrByDay: Map<string, number | null>,
  timeZone = "America/New_York",
): Promise<Map<string, MeetingHrStress>> {
  if (!meetings.length) return new Map();
  const days = [...new Set(meetings.flatMap((m) => [m.day, calendarDayInZone(m.endUtc, timeZone)]))];
  const samples = await loadHeartrateSamplesForDays(env, days);
  return attachMeetingHr(meetings, samples, lowestHrByDay, timeZone);
}

export async function loadDayHrSeries(
  env: Env,
  day: string,
  timeZone = "America/New_York",
): Promise<DayHrPoint[]> {
  const samples = await loadHeartrateSamples(env, day, day);
  return downsampleDayHr(samplesOnLocalDay(samples, day, timeZone));
}
