import { durationSeconds } from "../sources/calendar/classify.ts";
import { addCalendarDays, localDayRangeUtc } from "./time.ts";

/**
 * What the owner says about a meeting, and what the Mac saw of it (table
 * meeting_override, migration 0017). The calendar is never edited: these rows
 * only change how Meetspike reads a meeting. Everything here tolerates the
 * table being absent: that reads as "no overrides".
 *
 * Keys: `event:<calendar_event.id>` for one meeting, `series:<id>` for a
 * recurring series. Event state beats series state. A user-set or seen time
 * only counts inside the limits below, so a typo cannot swallow a day.
 */

export type OverrideState = "not_joined" | "unlinked" | "linked";
export type OverrideScope = "event" | "series";

export const OVERRIDE_STATES: readonly OverrideState[] = ["not_joined", "unlinked", "linked"];
const EXCLUDED_STATES: ReadonlySet<string> = new Set(["not_joined", "unlinked"]);

/** A start may be this much before the calendar start. */
export const MAX_EARLY_START_MS = 2 * 3600_000;
/** An end may be this much after the calendar end. */
export const MAX_LATE_END_MS = 4 * 3600_000;
/**
 * The Mac's sightings only count inside [calendar start - 15 min, calendar end + 4 h].
 * A sighting from before the event moved in the calendar lies outside and is ignored.
 */
export const MAX_SEEN_EARLY_MS = 15 * 60_000;
/** The longest a meeting can be made. */
export const MAX_WINDOW_MS = 12 * 3600_000;

export type OverrideRow = {
  key: string;
  state: string | null;
  start_utc: string | null;
  end_utc: string | null;
  seen_start_utc: string | null;
  seen_end_utc: string | null;
  seen_none: number;
  updated_at: string;
};

export const eventKey = (id: string): string => `event:${id}`;
export const seriesKey = (id: string): string => `series:${id}`;

const INSTANCE_SUFFIX = /^(.+)_(\d{4})(\d{2})(\d{2})(?:T\d{6}Z)?$/;

/**
 * The series a Google instance id belongs to: the id without `_YYYYMMDD` or
 * `_YYYYMMDDTHHMMSSZ`. Null when the id has no such suffix.
 */
export function seriesIdOf(eventId: string): string | null {
  const m = INSTANCE_SUFFIX.exec(eventId);
  if (!m) return null;
  const month = Number(m[3]);
  const day = Number(m[4]);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return m[1];
}

function isoMs(value: string | null | undefined): number {
  if (!value) return NaN;
  return Date.parse(value);
}

function normalizeIso(value: string | null | undefined): string | null {
  const ms = isoMs(value);
  return Number.isFinite(ms) ? new Date(ms).toISOString() : null;
}

/** Whether a Mac sighting still fits the calendar times it is read against. */
export function seenTimeFits(calendar: { startUtc: string; endUtc: string }, value: string | null | undefined): boolean {
  const ms = isoMs(value);
  return Number.isFinite(ms) && ms >= isoMs(calendar.startUtc) - MAX_SEEN_EARLY_MS && ms <= isoMs(calendar.endUtc) + MAX_LATE_END_MS;
}

export type EffectiveTimes = { startUtc: string; endUtc: string; changed: boolean };

/**
 * The times a meeting counts for. Per field the order is the owner's time,
 * then the Mac's sighting, then the calendar. An owner's start more than 2 h before the
 * calendar start, or an end more than 4 h after the calendar end, is skipped. A sighting
 * only counts inside [calendar start - 15 min, calendar end + 4 h] (see seenTimeFits).
 * Of the pairs that remain, one must end after it starts and last at most 12 h.
 * Pairs are tried by how many steps down from the owner's choice they are
 * (start and end steps added; a tie goes to the better start). The calendar
 * pair is always the last resort, so the answer is never invalid.
 */
export function effectiveTimes(
  calendar: { startUtc: string; endUtc: string },
  chosen: { startUtc?: string | null; endUtc?: string | null; seenStartUtc?: string | null; seenEndUtc?: string | null },
): EffectiveTimes {
  const calStart = isoMs(calendar.startUtc);
  const calEnd = isoMs(calendar.endUtc);
  if (!Number.isFinite(calStart) || !Number.isFinite(calEnd)) {
    return { startUtc: calendar.startUtc, endUtc: calendar.endUtc, changed: false };
  }
  const starts: Array<{ ms: number; rank: number }> = [];
  const ends: Array<{ ms: number; rank: number }> = [];
  const calendarTimes = { startUtc: calendar.startUtc, endUtc: calendar.endUtc };
  [chosen.startUtc, chosen.seenStartUtc].forEach((value, rank) => {
    const ms = isoMs(value);
    if (!Number.isFinite(ms)) return;
    if (rank === 0 ? ms >= calStart - MAX_EARLY_START_MS : seenTimeFits(calendarTimes, value)) starts.push({ ms, rank });
  });
  [chosen.endUtc, chosen.seenEndUtc].forEach((value, rank) => {
    const ms = isoMs(value);
    if (!Number.isFinite(ms)) return;
    if (rank === 0 ? ms <= calEnd + MAX_LATE_END_MS : seenTimeFits(calendarTimes, value)) ends.push({ ms, rank });
  });
  const pairs: Array<{ s: number; e: number; cost: number; startRank: number }> = [];
  for (const s of starts) {
    for (const e of ends) {
      if (e.ms > s.ms && e.ms - s.ms <= MAX_WINDOW_MS) pairs.push({ s: s.ms, e: e.ms, cost: s.rank + e.rank, startRank: s.rank });
    }
    // The calendar end stands in below the seen one (rank 2).
    if (calEnd > s.ms && calEnd - s.ms <= MAX_WINDOW_MS) pairs.push({ s: s.ms, e: calEnd, cost: s.rank + 2, startRank: s.rank });
  }
  for (const e of ends) {
    if (e.ms > calStart && e.ms - calStart <= MAX_WINDOW_MS) pairs.push({ s: calStart, e: e.ms, cost: 2 + e.rank, startRank: 2 });
  }
  pairs.sort((a, b) => a.cost - b.cost || a.startRank - b.startRank);
  const pick = pairs[0];
  if (!pick || (pick.s === calStart && pick.e === calEnd)) {
    return { startUtc: calendar.startUtc, endUtc: calendar.endUtc, changed: false };
  }
  const startUtc = pick.s === calStart ? calendar.startUtc : new Date(pick.s).toISOString();
  const endUtc = pick.e === calEnd ? calendar.endUtc : new Date(pick.e).toISOString();
  return { startUtc, endUtc, changed: startUtc !== calendar.startUtc || endUtc !== calendar.endUtc };
}

/** One meeting's overrides, resolved. */
export type ResolvedOverride = {
  state: OverrideState | null;
  scope: OverrideScope | null;
  /** The times the owner set (not the effective ones). */
  startUtc: string | null;
  endUtc: string | null;
  seenStartUtc: string | null;
  seenEndUtc: string | null;
  seenNone: boolean;
  seriesId: string | null;
  /** The series' own saved state (null when it has none), whoever decides this meeting's state. */
  seriesState: OverrideState | null;
  excluded: boolean;
  /** The calendar's own times, before any change. */
  calendarStartUtc: string;
  calendarEndUtc: string;
  timesChanged: boolean;
};

function stateOf(row: OverrideRow | undefined): OverrideState | null {
  const state = row?.state;
  return state === "not_joined" || state === "unlinked" || state === "linked" ? state : null;
}

const hasTimes = (row: OverrideRow): boolean =>
  row.start_utc != null || row.end_utc != null || row.seen_start_utc != null || row.seen_end_utc != null;

export class OverrideSet {
  readonly rows: ReadonlyMap<string, OverrideRow>;
  /** False when the table is missing: nothing can be saved either. */
  readonly available: boolean;

  constructor(rows: Iterable<OverrideRow> = [], available = true) {
    this.rows = new Map([...rows].map((row) => [row.key, row]));
    this.available = available;
  }

  static readonly none = new OverrideSet([], false);

  get size(): number {
    return this.rows.size;
  }

  /** Event rows that carry times, set by the owner or seen by the Mac. They can move a meeting to another day. */
  shiftedEventIds(): string[] {
    const out: string[] = [];
    for (const row of this.rows.values()) {
      if (row.key.startsWith("event:") && hasTimes(row)) out.push(row.key.slice("event:".length));
    }
    return out;
  }

  /** Not joined or not linked: the meeting stays out of everything. */
  isExcluded(id: string): boolean {
    const own = stateOf(this.rows.get(eventKey(id)));
    if (own) return EXCLUDED_STATES.has(own);
    const series = seriesIdOf(id);
    const inherited = series ? stateOf(this.rows.get(seriesKey(series))) : null;
    return inherited != null && EXCLUDED_STATES.has(inherited);
  }

  /** The times this meeting counts for, and who decided its state. Null when nothing is overridden. */
  effective(id: string, calendarStartUtc: string, calendarEndUtc: string): { startUtc: string; endUtc: string; override: ResolvedOverride } | null {
    const own = this.rows.get(eventKey(id));
    const seriesId = seriesIdOf(id);
    const inherited = seriesId ? this.rows.get(seriesKey(seriesId)) : undefined;
    const ownState = stateOf(own);
    const seriesState = stateOf(inherited);
    // "Never saw it" can't be dated to the event's current time without a schema change. It only counts
    // when it was saved after the calendar end: before that it was about an earlier time.
    const savedSeenNone = own?.seen_none === 1;
    const seenNone = savedSeenNone && isoMs(calendarEndUtc) < isoMs(own?.updated_at);
    // Nothing chosen. A meeting in a series still says which series, so the app can offer "all of them".
    if (!this.available || (!ownState && !seriesState && !(own && (hasTimes(own) || savedSeenNone)) && !seriesId)) return null;
    const state = ownState ?? seriesState;
    const times = effectiveTimes(
      { startUtc: calendarStartUtc, endUtc: calendarEndUtc },
      own
        ? { startUtc: own.start_utc, endUtc: own.end_utc, seenStartUtc: own.seen_start_utc, seenEndUtc: own.seen_end_utc }
        : {},
    );
    return {
      startUtc: times.startUtc,
      endUtc: times.endUtc,
      override: {
        state,
        scope: ownState ? "event" : seriesState ? "series" : null,
        startUtc: own?.start_utc ?? null,
        endUtc: own?.end_utc ?? null,
        seenStartUtc: own?.seen_start_utc ?? null,
        seenEndUtc: own?.seen_end_utc ?? null,
        seenNone: seenNone && own?.seen_start_utc == null,
        seriesId,
        seriesState,
        excluded: state != null && EXCLUDED_STATES.has(state),
        calendarStartUtc,
        calendarEndUtc,
        timesChanged: times.changed,
      },
    };
  }

  resolve(id: string, calendarStartUtc: string, calendarEndUtc: string): ResolvedOverride | null {
    return this.effective(id, calendarStartUtc, calendarEndUtc)?.override ?? null;
  }
}

export type OverridableRow = { id: string; start_utc: string; end_utc: string; duration_s?: number; override?: ResolvedOverride };

/**
 * Put the owner's choices on these rows: effective start, end and duration,
 * and the resolved override. Excluded meetings are dropped unless asked for.
 * With no overrides the same array comes back untouched. Run it after
 * dedupeMeetings (a recording of a dropped meeting must not come back) and
 * before localizeEventForZone (day, local times and after-hours come from the
 * effective times).
 */
export function applyOverrides<T extends OverridableRow>(
  rows: T[], set: OverrideSet, opts: { includeExcluded?: boolean } = {},
): T[] {
  if (!set.available) return rows;
  const out: T[] = [];
  for (const row of rows) {
    const found = set.effective(row.id, row.start_utc, row.end_utc);
    if (!found) {
      out.push(row);
      continue;
    }
    if (found.override.excluded && !opts.includeExcluded) continue;
    const next: T = { ...row, override: found.override };
    if (found.override.timesChanged) {
      next.start_utc = found.startUtc;
      next.end_utc = found.endUtc;
      if (row.duration_s !== undefined) next.duration_s = durationSeconds(found.startUtc, found.endUtc);
    }
    out.push(next);
  }
  return out;
}

/** The override as the API shows it. Null when nothing is overridden. */
export function overrideJson(override: ResolvedOverride | null | undefined) {
  if (!override) return null;
  return {
    state: override.state,
    scope: override.scope,
    startUtc: override.startUtc,
    endUtc: override.endUtc,
    seenStartUtc: override.seenStartUtc,
    seenEndUtc: override.seenEndUtc,
    seenNone: override.seenNone,
    seriesId: override.seriesId,
    seriesState: override.seriesState,
    calendarStartUtc: override.calendarStartUtc,
    calendarEndUtc: override.calendarEndUtc,
  };
}

// MARK: D1

const COLUMNS = "key, state, start_utc, end_utc, seen_start_utc, seen_end_utc, seen_none, updated_at";
const CHUNK = 90;

export function missingOverrideTable(error: unknown): boolean {
  return String(error).includes("no such table: meeting_override");
}

/**
 * Overrides that can touch meetings starting in [startUtc, endUtcExclusive):
 * every series rule (there are few) and the rows of events in that span.
 * One small query. A missing table is "no overrides".
 */
export async function loadOverridesInRange(
  db: D1Database, range: { startUtc: string; endUtcExclusive: string },
): Promise<OverrideSet> {
  try {
    const { results } = await db.prepare(
      `SELECT ${COLUMNS} FROM meeting_override
       WHERE (key >= 'series:' AND key < 'series;')
          OR key IN (SELECT 'event:' || id FROM calendar_event WHERE start_utc >= ? AND start_utc < ?)`,
    ).bind(range.startUtc, range.endUtcExclusive).all<OverrideRow>();
    return new OverrideSet(results ?? []);
  } catch (error) {
    if (missingOverrideTable(error)) return OverrideSet.none;
    throw error;
  }
}

/** Overrides for these event ids, and for their series. One small query per 45 ids. */
export async function loadOverridesForIds(db: D1Database, ids: Iterable<string>): Promise<OverrideSet> {
  const keys = new Set<string>();
  for (const id of ids) {
    keys.add(eventKey(id));
    const series = seriesIdOf(id);
    if (series) keys.add(seriesKey(series));
  }
  if (!keys.size) return new OverrideSet([], true);
  const list = [...keys];
  const rows: OverrideRow[] = [];
  try {
    for (let i = 0; i < list.length; i += CHUNK) {
      const part = list.slice(i, i + CHUNK);
      const { results } = await db.prepare(
        `SELECT ${COLUMNS} FROM meeting_override WHERE key IN (${part.map(() => "?").join(", ")})`,
      ).bind(...part).all<OverrideRow>();
      rows.push(...(results ?? []));
    }
  } catch (error) {
    if (missingOverrideTable(error)) return OverrideSet.none;
    throw error;
  }
  return new OverrideSet(rows);
}

/**
 * The series' own row and the event rows of its instances: one index range
 * read of the primary key. A missing table is "no overrides".
 */
export async function loadSeriesOverrides(db: D1Database, seriesId: string): Promise<OverrideSet> {
  try {
    const { results } = await db.prepare(
      `SELECT ${COLUMNS} FROM meeting_override WHERE key = ?1 OR (key >= ?2 AND key < ?3)`,
    ).bind(seriesKey(seriesId), `event:${seriesId}_`, `event:${seriesId}\``).all<OverrideRow>();
    return new OverrideSet(results ?? []);
  } catch (error) {
    if (missingOverrideTable(error)) return OverrideSet.none;
    throw error;
  }
}

/** Most instances of a series that are read when a series choice changes. */
export const SERIES_INSTANCE_LIMIT = 500;

/**
 * The calendar rows of a series' instances that have started by `nowUtc`,
 * newest first, at most SERIES_INSTANCE_LIMIT. The id range uses the primary
 * key; the suffix length keeps out ids that merely start with the series id.
 */
export async function seriesInstances(
  db: D1Database, seriesId: string, nowUtc: string,
): Promise<Array<{ id: string; start_utc: string; end_utc: string }>> {
  const { results } = await db.prepare(
    `SELECT id, start_utc, end_utc FROM calendar_event
     WHERE id >= ?1 AND id < ?2 AND length(id) IN (?3, ?4) AND deleted_at IS NULL AND start_utc <= ?5
     ORDER BY start_utc DESC, id LIMIT ?6`,
  ).bind(`${seriesId}_`, `${seriesId}\``, seriesId.length + 9, seriesId.length + 17, nowUtc, SERIES_INSTANCE_LIMIT)
    .all<{ id: string; start_utc: string; end_utc: string }>();
  return (results ?? []).filter((row) => seriesIdOf(row.id) === seriesId);
}

export type ExclusionRules = {
  /** Meetings left out by their own choice. */
  eventIds: string[];
  /** Meetings that keep themselves in although their series is left out. */
  linkedIds: string[];
  /** Series left out. */
  seriesIds: string[];
};

/**
 * Every choice that leaves meetings out, for reads that scan all of history
 * in their own SQL (company search). Rows with a state only, so Mac sightings
 * are not read. A missing table is "nothing left out".
 */
export async function loadExclusionRules(db: D1Database): Promise<ExclusionRules> {
  const rules: ExclusionRules = { eventIds: [], linkedIds: [], seriesIds: [] };
  try {
    const { results } = await db.prepare(`SELECT key, state FROM meeting_override WHERE state IS NOT NULL`)
      .all<{ key: string; state: string }>();
    for (const { key, state } of results ?? []) {
      const excluded = EXCLUDED_STATES.has(state);
      if (key.startsWith("event:")) (excluded ? rules.eventIds : state === "linked" ? rules.linkedIds : []).push(key.slice(6));
      else if (key.startsWith("series:") && excluded) rules.seriesIds.push(key.slice(7));
    }
  } catch (error) {
    if (!missingOverrideTable(error)) throw error;
  }
  return rules;
}

/**
 * SQL for reads that scan history: ` AND <not excluded>` for the events of
 * `alias` (a calendar_event alias). A recording that is the twin of a left-out
 * meeting (same start, title and attendees) is dropped with it. Uses numbered
 * parameters `base` to `base + 2`, bound to `params` in that order. Null when
 * nothing is left out, so the caller keeps its own SQL.
 */
export function exclusionClause(rules: ExclusionRules, alias: string, base = 1): { sql: string; params: string[] } | null {
  if (!rules.eventIds.length && !rules.seriesIds.length) return null;
  const [events, series, linked] = [`?${base}`, `?${base + 1}`, `?${base + 2}`];
  const excluded = (a: string) => `(${a}.id IN (SELECT value FROM json_each(${events}))
      OR (EXISTS (SELECT 1 FROM json_each(${series}) s
                  WHERE ${a}.id >= s.value || '_' AND ${a}.id < s.value || '\`'
                    AND length(${a}.id) IN (length(s.value) + 9, length(s.value) + 17))
          AND ${a}.id NOT IN (SELECT value FROM json_each(${linked}))))`;
  return {
    sql: ` AND NOT ${excluded(alias)}
      AND NOT EXISTS (SELECT 1 FROM calendar_event x
                      WHERE x.deleted_at IS NULL AND x.id <> ${alias}.id AND x.start_utc = ${alias}.start_utc
                        AND x.title IS ${alias}.title AND x.attendees_json IS ${alias}.attendees_json
                        AND ${excluded("x")})`,
    params: [JSON.stringify(rules.eventIds), JSON.stringify(rules.seriesIds), JSON.stringify(rules.linkedIds)],
  };
}

/** Overrides loading for a span of time, shared by every read in one request that fits inside it. */
export type OverrideScopeHandle = { range: { startUtc: string; endUtcExclusive: string }; ready: Promise<OverrideSet> };

/** Start loading overrides for a span now; loaders reuse it when it covers what they need. */
export function openOverrides(db: D1Database, range: { startUtc: string; endUtcExclusive: string }): OverrideScopeHandle {
  const ready = loadOverridesInRange(db, range);
  // A request that fails before it awaits this must not leave an unhandled rejection behind.
  ready.catch(() => {});
  return { range, ready };
}

/**
 * Start reading the owner's meeting choices for local days [from, to] and the
 * days before them that heart-rate baselines look back over. One small query,
 * shared by every read in the request that fits inside it.
 */
export function openRangeOverrides(db: D1Database, from: string, to: string, tz: string): OverrideScopeHandle {
  return openOverrides(db, localDayRangeUtc(addCalendarDays(from, -18), addCalendarDays(to, 1), tz));
}

/** Days before a meeting whose neighbours feed its heart-rate baseline (14) and a margin. */
export const BASELINE_LOOKBACK_DAYS = 16;

/** Overrides for one meeting, its series and the meetings around it that a heart-rate baseline reads. */
export function overridesAround(db: D1Database, calendarStartUtc: string): Promise<OverrideSet> {
  const start = Date.parse(calendarStartUtc);
  return loadOverridesInRange(db, {
    startUtc: new Date(start - BASELINE_LOOKBACK_DAYS * 86_400_000).toISOString(),
    endUtcExclusive: new Date(start + 2 * 86_400_000).toISOString(),
  });
}

/** Epoch milliseconds of an ISO text column or expression, in SQL (exact to the millisecond). */
const sqlEpochMs = (expr: string): string =>
  `(1000 * unixepoch(${expr}) + CAST(substr(strftime('%f', ${expr}), 4) AS INTEGER))`;

/**
 * SQL: the stored row's seen_none is stale, i.e. it was saved before the event's calendar end (the same
 * test as `effective`: valid only when calendar end < updated_at). `idParam` is the numbered parameter
 * holding the event id. An event with no calendar row cannot be judged, so it is not stale. Reads the
 * row's own seen_none and updated_at as they are before the statement writes.
 */
const staleSeenNoneSql = (idParam: string): string =>
  `(meeting_override.seen_none = 1 AND EXISTS (SELECT 1 FROM calendar_event c WHERE c.id = ${idParam}
       AND COALESCE(${sqlEpochMs("c.end_utc")} < ${sqlEpochMs("meeting_override.updated_at")}, 0) = 0))`;

export type OverridePatch = {
  state?: OverrideState | null;
  startUtc?: string | null;
  endUtc?: string | null;
};

/**
 * Save the owner's choice for one key. Fields left out stay as they are (the
 * Mac's sightings are never touched). A row left with nothing in it is
 * removed. Returns false when the table is missing.
 */
export async function saveOverride(
  db: D1Database, key: string, patch: OverridePatch, at: string = new Date().toISOString(),
): Promise<boolean> {
  const has = (field: keyof OverridePatch) => (field in patch ? 1 : 0);
  try {
    await db.prepare(
      `INSERT INTO meeting_override (key, state, start_utc, end_utc, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)
       ON CONFLICT (key) DO UPDATE SET
         state = CASE WHEN ?6 THEN excluded.state ELSE state END,
         start_utc = CASE WHEN ?7 THEN excluded.start_utc ELSE start_utc END,
         end_utc = CASE WHEN ?8 THEN excluded.end_utc ELSE end_utc END,
         -- Any write moves updated_at, which would make an old "never saw it" look newer than the
         -- calendar end. A stale one is dropped here, in the same statement (a valid one stays).
         seen_none = CASE WHEN ${staleSeenNoneSql("?9")} THEN 0 ELSE seen_none END,
         updated_at = excluded.updated_at`,
    ).bind(key, patch.state ?? null, patch.startUtc ?? null, patch.endUtc ?? null, at,
      has("state"), has("startUtc"), has("endUtc"), key.startsWith("event:") ? key.slice("event:".length) : null).run();
    await db.prepare(
      `DELETE FROM meeting_override
       WHERE key = ? AND state IS NULL AND start_utc IS NULL AND end_utc IS NULL
         AND seen_start_utc IS NULL AND seen_end_utc IS NULL AND seen_none = 0`,
    ).bind(key).run();
    return true;
  } catch (error) {
    if (missingOverrideTable(error)) return false;
    throw error;
  }
}

/**
 * Clear an own `linked` on one meeting and keep everything else on its row (its
 * times and the Mac's sightings). Does nothing when the row says anything else.
 * A row left with nothing in it is removed. One batch, so both steps land together.
 * Returns whether a `linked` was cleared. False too when the table is missing.
 */
export async function clearOwnLinked(
  db: D1Database, id: string, at: string = new Date().toISOString(),
): Promise<boolean> {
  const key = eventKey(id);
  try {
    const [cleared] = await db.batch([
      // A stale "never saw it" must not come back to life through the new updated_at (same rule as saveOverride).
      db.prepare(
        `UPDATE meeting_override SET state = NULL,
           seen_none = CASE WHEN ${staleSeenNoneSql("?3")} THEN 0 ELSE seen_none END,
           updated_at = ?2
         WHERE key = ?1 AND state = 'linked'`,
      ).bind(key, at, id),
      db.prepare(
        `DELETE FROM meeting_override
         WHERE key = ? AND state IS NULL AND start_utc IS NULL AND end_utc IS NULL
           AND seen_start_utc IS NULL AND seen_end_utc IS NULL AND seen_none = 0`,
      ).bind(key),
    ]);
    return (cleared.meta?.changes ?? 0) > 0;
  } catch (error) {
    if (missingOverrideTable(error)) return false;
    throw error;
  }
}

export type Sighting = { seenStartUtc: string; seenEndUtc: string } | { seenNone: true };

/**
 * Record what the Mac saw. Idempotent. A later sighting widens the seen times
 * (earliest start, latest end), but only a stored value that still fits the
 * event's current calendar times (see seenTimeFits): one that no longer fits
 * was about an earlier time, and the new report replaces it. This is decided
 * per value. Any sighting clears seen_none. A "never saw it" report is ignored
 * once Zoom has been seen. When the stored seen_none is stale (saved before the
 * calendar end, so it does not count), a repeated report moves updated_at to
 * now so it counts. Never touches the owner's state or times. Returns false
 * when the table is missing.
 */
export async function saveSighting(
  db: D1Database, id: string, sighting: Sighting, at: string = new Date().toISOString(),
): Promise<boolean> {
  const key = eventKey(id);
  try {
    if ("seenNone" in sighting) {
      await db.prepare(
        `INSERT INTO meeting_override (key, seen_none, updated_at) VALUES (?1, 1, ?2)
         ON CONFLICT (key) DO UPDATE SET
           seen_none = CASE WHEN seen_start_utc IS NULL THEN 1 ELSE seen_none END,
           updated_at = CASE WHEN seen_start_utc IS NULL AND (seen_none = 0 OR ${staleSeenNoneSql("?3")})
                             THEN excluded.updated_at ELSE updated_at END`,
      ).bind(key, at, id).run();
    } else {
      // seenTimeFits in SQL, against the calendar row read in the same statement. No calendar row: every stored value fits.
      const stillFits = (column: string) =>
        `(NOT EXISTS (SELECT 1 FROM calendar_event c WHERE c.id = ?5)
          OR EXISTS (SELECT 1 FROM calendar_event c WHERE c.id = ?5
                     AND ${sqlEpochMs(`meeting_override.${column}`)}
                         BETWEEN ${sqlEpochMs("c.start_utc")} - ${MAX_SEEN_EARLY_MS} AND ${sqlEpochMs("c.end_utc")} + ${MAX_LATE_END_MS}))`;
      await db.prepare(
        `INSERT INTO meeting_override (key, seen_start_utc, seen_end_utc, seen_none, updated_at) VALUES (?1, ?2, ?3, 0, ?4)
         ON CONFLICT (key) DO UPDATE SET
           seen_start_utc = CASE WHEN seen_start_utc IS NULL OR NOT ${stillFits("seen_start_utc")}
                                      OR excluded.seen_start_utc < seen_start_utc
                                 THEN excluded.seen_start_utc ELSE seen_start_utc END,
           seen_end_utc = CASE WHEN seen_end_utc IS NULL OR NOT ${stillFits("seen_end_utc")}
                                    OR excluded.seen_end_utc > seen_end_utc
                               THEN excluded.seen_end_utc ELSE seen_end_utc END,
           seen_none = 0,
           updated_at = excluded.updated_at`,
      ).bind(key, normalizeIso(sighting.seenStartUtc), normalizeIso(sighting.seenEndUtc), at, id).run();
    }
    return true;
  } catch (error) {
    if (missingOverrideTable(error)) return false;
    throw error;
  }
}

export { normalizeIso };
