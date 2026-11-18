import { SOURCE_OURA, type CalendarEventRow, type WearableSource } from "../../types.ts";
import { wearableInfo } from "../../lib/wearable.ts";
import { addCalendarDays, DEFAULT_TIME_ZONE, localDayRangeUtc } from "../../lib/time.ts";
import { normalizePersonName } from "../../lib/people.ts";
import { localizeEventForZone } from "./project.ts";
import { joinMeetings, type JoinedMeeting, type OuraDaySlice } from "./join.ts";

type SleepRow = {
  day: string;
  score: number | null;
  avg_hrv: number | null;
  lowest_hr: number | null;
  total_sleep_s: number | null;
};

type ReadyRow = {
  day: string;
  score: number | null;
  contributors_json: string | null;
};

type StrainRow = {
  day: string;
  strain: number | null;
  avg_hr: number | null;
  max_hr: number | null;
};

type StressRow = {
  day: string;
  stress_high_s: number | null;
  recovery_high_s: number | null;
  day_summary: string | null;
};

export async function loadCalendarEvents(
  db: D1Database,
  fromDay: string,
  toDay: string,
  timeZone: string = DEFAULT_TIME_ZONE,
): Promise<CalendarEventRow[]> {
  const range = localDayRangeUtc(fromDay, toDay, timeZone);
  const res = await db
    .prepare(
      `SELECT id, source, day, start_utc, end_utc, start_local, end_local, tz_offset_min,
              duration_s, title, kind, client_key, project_key, attendee_count, attendees_json,
              after_hours, location, raw_id, deleted_at, updated_at,
              source_type, plaud_file_id, sync_reason, has_transcript, synced_at
       FROM calendar_event
       WHERE start_utc >= ? AND start_utc < ? AND deleted_at IS NULL
       ORDER BY start_utc ASC`,
    )
    .bind(range.startUtc, range.endUtcExclusive)
    .all<CalendarEventRow>();
  return (res.results ?? []).map((row) => localizeEventForZone(row, timeZone));
}

/** Day strain rows, for wearables that have them. A missing table (migration 0008 not applied) is "none". */
async function loadStrain(db: D1Database, source: WearableSource, fromDay: string, toDay: string): Promise<StrainRow[]> {
  if (wearableInfo(source).strainLabel == null) return [];
  try {
    const res = await db
      .prepare(
        `SELECT day, strain, avg_hr, max_hr
         FROM daily_strain WHERE source = ? AND day >= ? AND day <= ? AND deleted_at IS NULL`,
      )
      .bind(source, fromDay, toDay)
      .all<StrainRow>();
    return res.results ?? [];
  } catch {
    return [];
  }
}

/**
 * Per-day wearable scores for [fromDay, toDay], read for one `source`.
 * The name is historical; nothing in here is Oura-specific.
 */
export async function loadOuraSlices(
  db: D1Database,
  fromDay: string,
  toDay: string,
  source: WearableSource = SOURCE_OURA,
): Promise<{ byDay: Map<string, OuraDaySlice>; contributors: Map<string, string | null> }> {
  const [sleep, ready, stress, strain] = await Promise.all([
    db
      .prepare(
        `SELECT day, score, avg_hrv, lowest_hr, total_sleep_s
         FROM daily_sleep WHERE source = ? AND day >= ? AND day <= ? AND deleted_at IS NULL`,
      )
      .bind(source, fromDay, toDay)
      .all<SleepRow>(),
    db
      .prepare(
        `SELECT day, score, contributors_json
         FROM daily_readiness WHERE source = ? AND day >= ? AND day <= ? AND deleted_at IS NULL`,
      )
      .bind(source, fromDay, toDay)
      .all<ReadyRow>(),
    db
      .prepare(
        `SELECT day, stress_high_s, recovery_high_s, day_summary
         FROM daily_stress WHERE source = ? AND day >= ? AND day <= ? AND deleted_at IS NULL`,
      )
      .bind(source, fromDay, toDay)
      .all<StressRow>(),
    loadStrain(db, source, fromDay, toDay),
  ]);

  const byDay = new Map<string, OuraDaySlice>();
  const contributors = new Map<string, string | null>();
  const days = new Set<string>();
  for (const r of sleep.results ?? []) days.add(r.day);
  for (const r of ready.results ?? []) days.add(r.day);
  for (const r of stress.results ?? []) days.add(r.day);
  for (const r of strain) days.add(r.day);

  const sleepBy = new Map((sleep.results ?? []).map((r) => [r.day, r]));
  const readyBy = new Map((ready.results ?? []).map((r) => [r.day, r]));
  const stressBy = new Map((stress.results ?? []).map((r) => [r.day, r]));
  const strainBy = new Map(strain.map((r) => [r.day, r]));

  for (const day of days) {
    const s = sleepBy.get(day);
    const r = readyBy.get(day);
    const t = stressBy.get(day);
    const x = strainBy.get(day);
    byDay.set(day, {
      day,
      sleepScore: s?.score ?? null,
      readinessScore: r?.score ?? null,
      avgHrv: s?.avg_hrv ?? null,
      lowestHr: s?.lowest_hr ?? null,
      totalSleepS: s?.total_sleep_s ?? null,
      stressHighS: t?.stress_high_s ?? null,
      recoveryHighS: t?.recovery_high_s ?? null,
      stressSummary: t?.day_summary ?? null,
      ...(x ? { strain: x.strain, dayAvgHr: x.avg_hr, dayMaxHr: x.max_hr } : {}),
    });
    contributors.set(day, r?.contributors_json ?? null);
  }
  return { byDay, contributors };
}

export async function loadJoinedMeetings(
  db: D1Database,
  fromDay: string,
  toDay: string,
  timeZone: string = DEFAULT_TIME_ZONE,
  source: WearableSource = SOURCE_OURA,
): Promise<JoinedMeeting[]> {
  // Morning D+1 needs one extra day; same-day stress needs fromDay itself.
  const ouraTo = addCalendarDays(toDay, 1);
  const events = await loadCalendarEvents(db, fromDay, toDay, timeZone);
  const { byDay, contributors } = await loadOuraSlices(db, fromDay, ouraTo, source);
  return joinMeetings(events, byDay, contributors);
}

export async function loadCalendarEventsByAttendee(
  db: D1Database,
  email: string,
  fromDay: string,
  toDay: string,
  timeZone: string = DEFAULT_TIME_ZONE,
): Promise<CalendarEventRow[]> {
  const range = localDayRangeUtc(fromDay, toDay, timeZone);
  const res = await db
    .prepare(
      `SELECT e.id, e.source, e.day, e.start_utc, e.end_utc, e.start_local, e.end_local, e.tz_offset_min,
              e.duration_s, e.title, e.kind, e.client_key, e.project_key, e.attendee_count, e.attendees_json,
              e.after_hours, e.location, e.raw_id, e.deleted_at, e.updated_at,
              e.source_type, e.plaud_file_id, e.sync_reason, e.has_transcript, e.synced_at
       FROM calendar_event e
       INNER JOIN calendar_attendee a ON a.event_id = e.id AND a.source = e.source
       WHERE a.email = ? AND a.self = 0 AND e.deleted_at IS NULL
         AND e.start_utc >= ? AND e.start_utc < ?
       ORDER BY e.start_utc DESC`,
    )
    .bind(email, range.startUtc, range.endUtcExclusive)
    .all<CalendarEventRow>();
  return (res.results ?? []).map((row) => localizeEventForZone(row, timeZone));
}

export async function loadJoinedMeetingsByAttendee(
  db: D1Database,
  email: string,
  fromDay: string,
  toDay: string,
  timeZone: string = DEFAULT_TIME_ZONE,
  source: WearableSource = SOURCE_OURA,
): Promise<{ joined: JoinedMeeting[]; byDay: Map<string, OuraDaySlice> }> {
  const ouraTo = addCalendarDays(toDay, 1);
  const events = await loadCalendarEventsByAttendee(db, email, fromDay, toDay, timeZone);
  if (!events.length) return { joined: [], byDay: new Map() };
  const { byDay, contributors } = await loadOuraSlices(db, fromDay, ouraTo, source);
  return { joined: joinMeetings(events, byDay, contributors), byDay };
}

export async function loadAttendeeDisplayName(db: D1Database, email: string): Promise<string | null> {
  const row = await db
    .prepare(
      `SELECT display_name FROM calendar_attendee
       WHERE email = ? AND display_name IS NOT NULL AND trim(display_name) != ''
       LIMIT 1`,
    )
    .bind(email)
    .first<{ display_name: string }>();
  return normalizePersonName(row?.display_name);
}

export function sliceForDay(byDay: Map<string, OuraDaySlice>, day: string): OuraDaySlice | null {
  return byDay.get(day) ?? null;
}
