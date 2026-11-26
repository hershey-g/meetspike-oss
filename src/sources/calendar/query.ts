import { SOURCE_OURA, type CalendarEventRow, type WearableSource } from "../../types.ts";
import { wearableInfo } from "../../lib/wearable.ts";
import { addCalendarDays, calendarDayInZone, DEFAULT_TIME_ZONE, localDayRangeUtc } from "../../lib/time.ts";
import { dedupeMeetings } from "../../lib/meeting-identity.ts";
import { normalizePersonName } from "../../lib/people.ts";
import {
  applyOverrides,
  exclusionClause,
  loadExclusionRules,
  loadOverridesInRange,
  type OverridableRow,
  type OverrideScopeHandle,
  type OverrideSet,
} from "../../lib/meeting-override.ts";
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

/** How the loaders below treat the owner's meeting choices. */
export type LoadOptions = {
  /** Overrides already loading for this request, reused when they cover the span. */
  overrides?: OverrideScopeHandle;
  /** Keep meetings marked not joined or not linked (they carry `override.excluded`). */
  includeExcluded?: boolean;
};

type Span = { startUtc: string; endUtcExclusive: string };

const IDS_CLAUSE = (column: string) => ` AND ${column} IN (SELECT value FROM json_each(?))`;

/**
 * Meetings in [fromDay, toDay] with the owner's choices applied. One small
 * extra query for the overrides, run beside the calendar query. With no
 * overrides this is the plain calendar read. A meeting moved by an override
 * can start outside the span in the calendar, so when any meeting has times
 * the meetings that have them are also fetched from a span one day wider each
 * side, and the result is cut to the effective days. Order: dedupe, overrides,
 * localize (a recording of a dropped meeting must not come back, and the day
 * and after-hours come from the effective times).
 */
export async function loadWithOverrides<T extends OverridableRow & Parameters<typeof dedupeMeetings>[0][number] & { source: string }>(
  db: D1Database,
  fromDay: string,
  toDay: string,
  timeZone: string,
  opts: LoadOptions,
  order: "asc" | "desc",
  fetchRows: (span: Span, ids: string[] | null) => Promise<T[]>,
  localize: (row: T) => T = (row) => row,
): Promise<T[]> {
  const span = localDayRangeUtc(fromDay, toDay, timeZone);
  const wide = localDayRangeUtc(addCalendarDays(fromDay, -1), addCalendarDays(toDay, 1), timeZone);
  const reuse = opts.overrides
    && opts.overrides.range.startUtc <= wide.startUtc && opts.overrides.range.endUtcExclusive >= wide.endUtcExclusive;
  const [base, set]: [T[], OverrideSet] = await Promise.all([
    fetchRows(span, null),
    reuse ? opts.overrides!.ready : loadOverridesInRange(db, wide),
  ]);
  let rows = base;
  const shifted = set.shiftedEventIds();
  if (shifted.length) {
    const have = new Set(base.map((row) => `${row.id}\u0000${row.source}`));
    const extra = (await fetchRows(wide, shifted)).filter((row) => !have.has(`${row.id}\u0000${row.source}`));
    rows = [...base, ...extra];
  }
  let out = applyOverrides(dedupeMeetings(rows), set, { includeExcluded: opts.includeExcluded })
    .map(localize);
  if (shifted.length) {
    const sign = order === "asc" ? 1 : -1;
    out = out
      .filter((row) => {
        const day = calendarDayInZone(row.start_utc, timeZone);
        return day >= fromDay && day <= toDay;
      })
      .sort((a, b) => sign * a.start_utc.localeCompare(b.start_utc) || a.id.localeCompare(b.id) || a.source.localeCompare(b.source));
  }
  return out;
}

export async function loadCalendarEvents(
  db: D1Database,
  fromDay: string,
  toDay: string,
  timeZone: string = DEFAULT_TIME_ZONE,
  opts: LoadOptions = {},
): Promise<CalendarEventRow[]> {
  return loadWithOverrides(db, fromDay, toDay, timeZone, opts, "asc", async (span, ids) => {
    const args: unknown[] = [span.startUtc, span.endUtcExclusive];
    if (ids) args.push(JSON.stringify(ids));
    const res = await db
      .prepare(
        `SELECT id, source, day, start_utc, end_utc, start_local, end_local, tz_offset_min,
                duration_s, title, kind, client_key, project_key, attendee_count, attendees_json,
                after_hours, location, raw_id, deleted_at, updated_at,
                source_type, plaud_file_id, sync_reason, has_transcript, synced_at
         FROM calendar_event
         WHERE start_utc >= ? AND start_utc < ? AND deleted_at IS NULL${ids ? IDS_CLAUSE("id") : ""}
         ORDER BY start_utc ASC, id, source`,
      )
      .bind(...args)
      .all<CalendarEventRow>();
    return res.results ?? [];
  }, (row) => localizeEventForZone(row, timeZone));
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
  source: WearableSource | null = SOURCE_OURA,
): Promise<{ byDay: Map<string, OuraDaySlice>; contributors: Map<string, string | null> }> {
  if (source === null) return { byDay: new Map(), contributors: new Map() };
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
  source: WearableSource | null = SOURCE_OURA,
  opts: LoadOptions = {},
): Promise<JoinedMeeting[]> {
  // Morning D+1 needs one extra day; same-day stress needs fromDay itself.
  const ouraTo = addCalendarDays(toDay, 1);
  const [events, { byDay, contributors }] = await Promise.all([
    loadCalendarEvents(db, fromDay, toDay, timeZone, opts),
    loadOuraSlices(db, fromDay, ouraTo, source),
  ]);
  return joinMeetings(events, byDay, contributors);
}

export async function loadCalendarEventsByAttendee(
  db: D1Database,
  email: string,
  fromDay: string,
  toDay: string,
  timeZone: string = DEFAULT_TIME_ZONE,
  opts: LoadOptions = {},
): Promise<CalendarEventRow[]> {
  return loadWithOverrides(db, fromDay, toDay, timeZone, opts, "desc", async (span, ids) => {
    const args: unknown[] = [email, span.startUtc, span.endUtcExclusive];
    if (ids) args.push(JSON.stringify(ids));
    const res = await db
      .prepare(
        `SELECT e.id, e.source, e.day, e.start_utc, e.end_utc, e.start_local, e.end_local, e.tz_offset_min,
                e.duration_s, e.title, e.kind, e.client_key, e.project_key, e.attendee_count, e.attendees_json,
                e.after_hours, e.location, e.raw_id, e.deleted_at, e.updated_at,
                e.source_type, e.plaud_file_id, e.sync_reason, e.has_transcript, e.synced_at
         FROM calendar_event e
         INNER JOIN calendar_attendee a ON a.event_id = e.id AND a.source = e.source
         WHERE a.email = ? AND a.self = 0 AND e.deleted_at IS NULL
           AND e.start_utc >= ? AND e.start_utc < ?${ids ? IDS_CLAUSE("e.id") : ""}
         ORDER BY e.start_utc DESC, e.id, e.source`,
      )
      .bind(...args)
      .all<CalendarEventRow>();
    return res.results ?? [];
  }, (row) => localizeEventForZone(row, timeZone));
}

export async function loadJoinedMeetingsByAttendee(
  db: D1Database,
  email: string,
  fromDay: string,
  toDay: string,
  timeZone: string = DEFAULT_TIME_ZONE,
  source: WearableSource | null = SOURCE_OURA,
  opts: LoadOptions = {},
): Promise<{ joined: JoinedMeeting[]; byDay: Map<string, OuraDaySlice> }> {
  const events = await loadCalendarEventsByAttendee(db, email, fromDay, toDay, timeZone, opts);
  if (!events.length) return { joined: [], byDay: new Map() };
  const first = events[events.length - 1].day;
  const last = addCalendarDays(events[0].day, 1);
  const { byDay, contributors } = await loadOuraSlices(db, first, last, source);
  return { joined: joinMeetings(events, byDay, contributors), byDay };
}

/**
 * Meetings with anyone whose address is at `domain` or a subdomain of it.
 * Callers still check each meeting with companyDomain(): the LIKE only narrows.
 * `domain` is a normalized company domain (letters, digits, dots, hyphens).
 */
export async function loadCalendarEventsByDomain(
  db: D1Database,
  domain: string,
  fromDay: string,
  toDay: string,
  timeZone: string = DEFAULT_TIME_ZONE,
  opts: LoadOptions = {},
): Promise<CalendarEventRow[]> {
  return loadWithOverrides(db, fromDay, toDay, timeZone, opts, "desc", async (span, ids) => {
    const args: unknown[] = [span.startUtc, span.endUtcExclusive];
    if (ids) args.push(JSON.stringify(ids));
    args.push(`%@${domain}`, `%.${domain}`);
    const res = await db
      .prepare(
        `SELECT e.id, e.source, e.day, e.start_utc, e.end_utc, e.start_local, e.end_local, e.tz_offset_min,
                e.duration_s, e.title, e.kind, e.client_key, e.project_key, e.attendee_count, e.attendees_json,
                e.after_hours, e.location, e.raw_id, e.deleted_at, e.updated_at,
                e.source_type, e.plaud_file_id, e.sync_reason, e.has_transcript, e.synced_at
         FROM calendar_event e
         WHERE e.deleted_at IS NULL AND e.start_utc >= ? AND e.start_utc < ?${ids ? IDS_CLAUSE("e.id") : ""}
           AND EXISTS (
             SELECT 1 FROM calendar_attendee a
             WHERE a.event_id = e.id AND a.source = e.source AND a.self = 0
               AND (a.email LIKE ? OR a.email LIKE ?)
           )
         ORDER BY e.start_utc DESC, e.id, e.source`,
      )
      .bind(...args)
      .all<CalendarEventRow>();
    return res.results ?? [];
  }, (row) => localizeEventForZone(row, timeZone));
}

/** Joined meetings for these events, with the morning slices they need. */
export async function joinEvents(
  db: D1Database,
  events: CalendarEventRow[],
  source: WearableSource | null = SOURCE_OURA,
): Promise<JoinedMeeting[]> {
  if (!events.length) return [];
  const days = events.map((e) => e.day).sort();
  const { byDay, contributors } = await loadOuraSlices(db, days[0], addCalendarDays(days[days.length - 1], 1), source);
  return joinMeetings(events, byDay, contributors);
}

export async function loadAttendeeDisplayName(db: D1Database, email: string): Promise<string | null> {
  // A name only seen in meetings the owner left out is not used.
  const left = exclusionClause(await loadExclusionRules(db), "e", 2);
  const row = await db
    .prepare(
      left
        ? `SELECT a.display_name FROM calendar_attendee a JOIN calendar_event e ON e.id = a.event_id AND e.source = a.source
           WHERE a.email = ?1 AND a.display_name IS NOT NULL AND trim(a.display_name) != ''${left.sql}
           LIMIT 1`
        : `SELECT display_name FROM calendar_attendee
           WHERE email = ? AND display_name IS NOT NULL AND trim(display_name) != ''
           LIMIT 1`,
    )
    .bind(email, ...(left?.params ?? []))
    .first<{ display_name: string }>();
  return normalizePersonName(row?.display_name);
}

export function sliceForDay(byDay: Map<string, OuraDaySlice>, day: string): OuraDaySlice | null {
  return byDay.get(day) ?? null;
}
