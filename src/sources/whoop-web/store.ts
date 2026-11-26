import type { HrPoint, StressPoint } from "./parse.ts";
import { WINDOW_PAD_MIN } from "./constants.ts";
import { NOT_FETCHED_SLACK_MS } from "./meeting-hr.ts";

/**
 * D1 cache for WHOOP web data (migration 0010). Every read tolerates the
 * tables being absent: a missing table reads as "nothing stored".
 */
export type CachedHrStatus = "ok" | "empty" | "error";

export type CachedHrWindow = {
  eventId: string;
  windowStartUtc: string;
  windowEndUtc: string;
  status: CachedHrStatus;
  points: HrPoint[];
  errorText: string | null;
  fetchedAt: string;
};

export type CachedHrMetadata = Omit<CachedHrWindow, "points"> & { sampleCount: number };
export type ScoringHrWindow = CachedHrMetadata & { minutePoints: HrPoint[] };

export type CachedStressDay = {
  day: string;
  status: CachedHrStatus;
  points: StressPoint[];
  currentLevel: number | null;
  peakLevel: number | null;
  minLevel: number | null;
  errorText: string | null;
  fetchedAt: string;
};

type HrMetadataRow = {
  event_id: string;
  window_start_utc: string;
  window_end_utc: string;
  status: string;
  sample_count: number;
  error_text: string | null;
  fetched_at: string;
};

type HrRow = HrMetadataRow & { samples_json: string | null };

type StressRow = {
  day: string;
  status: string;
  points_json: string | null;
  current_level: number | null;
  peak_level: number | null;
  min_level: number | null;
  error_text: string | null;
  fetched_at: string;
};

function parsePairs(raw: string | null): Array<[number, number]> {
  if (!raw) return [];
  try {
    const v = JSON.parse(raw) as unknown;
    if (!Array.isArray(v)) return [];
    return v.filter(
      (p): p is [number, number] =>
        Array.isArray(p) && p.length >= 2 && Number.isFinite(p[0]) && Number.isFinite(p[1]),
    );
  } catch {
    return [];
  }
}

function status(s: string): CachedHrStatus {
  return s === "ok" || s === "empty" ? s : "error";
}

function hrMetadata(r: HrMetadataRow): CachedHrMetadata {
  return {
    eventId: r.event_id,
    windowStartUtc: r.window_start_utc,
    windowEndUtc: r.window_end_utc,
    status: status(r.status),
    sampleCount: r.sample_count,
    errorText: r.error_text,
    fetchedAt: r.fetched_at,
  };
}

/**
 * samples_json can hold points outside the row's window (kept so that a meeting
 * whose times moved and moved back shows them again, see raw.ts). They are never
 * shown and never scored: readers get the points of the row's own window, and
 * none at all unless the row is 'ok' (an 'empty' row's kept points are hidden).
 */
function pointsOfWindow(r: HrRow): Array<[number, number]> {
  if (status(r.status) !== "ok") return [];
  const from = Date.parse(r.window_start_utc);
  const to = Date.parse(r.window_end_utc);
  if (!Number.isFinite(from) || !Number.isFinite(to)) return [];
  return parsePairs(r.samples_json).filter(([t]) => t >= from && t <= to);
}

function hrFromRow(r: HrRow): CachedHrWindow {
  const { sampleCount, ...metadata } = hrMetadata(r);
  return { ...metadata, points: pointsOfWindow(r) };
}

function stressFromRow(r: StressRow): CachedStressDay {
  return {
    day: r.day,
    status: status(r.status),
    points: parsePairs(r.points_json),
    currentLevel: r.current_level,
    peakLevel: r.peak_level,
    minLevel: r.min_level,
    errorText: r.error_text,
    fetchedAt: r.fetched_at,
  };
}

export async function getCachedHr(db: D1Database, eventId: string): Promise<CachedHrWindow | null> {
  try {
    const r = await db
      .prepare(
        `SELECT event_id, window_start_utc, window_end_utc, status, sample_count, samples_json, error_text, fetched_at
         FROM whoop_web_hr WHERE event_id = ?`,
      )
      .bind(eventId)
      .first<HrRow>();
    return r ? hrFromRow(r) : null;
  } catch {
    return null;
  }
}

/** Select windows by time without reading their heart-rate arrays. */
export async function listCachedHrMetadata(db: D1Database, fromUtc: string, toUtc: string): Promise<CachedHrMetadata[]> {
  try {
    const res = await db
      .prepare(
        `SELECT event_id, window_start_utc, window_end_utc, status, sample_count, error_text, fetched_at
         FROM whoop_web_hr WHERE window_start_utc >= ? AND window_start_utc < ?`,
      )
      .bind(fromUtc, toUtc)
      .all<HrMetadataRow>();
    return (res.results ?? []).map(hrMetadata);
  } catch {
    return [];
  }
}

/**
 * Row plus what a cached entry is checked against. The check columns come from
 * the same statement and the same row as the averages, so they always describe
 * the data they sit next to.
 */
type ValidatorColumns = {
  ev_start: string | null;
  ev_end: string | null;
  samples_len: number | null;
  samples_tail: string | null;
};
type ScoringHrRow = HrRow & { minute_json: string } & ValidatorColumns;
type ValidatorRow = HrMetadataRow & ValidatorColumns;

const SCORING_BATCH_SIZE = 16;
const METADATA_BATCH_SIZE = 256;
/** Entries kept in memory. Least recently used is dropped first. */
export const SCORING_CACHE_MAX = 1000;
const TAIL_CHARS = 40;

function scoringFromRow(row: ScoringHrRow): ScoringHrWindow {
  return { ...hrMetadata(row), minutePoints: parsePairs(row.minute_json) };
}

/**
 * What a cached entry is valid for. A match means "the stored row and its
 * meeting are what the averages were computed from". Covered: the window,
 * status, error text, fetched_at, sample_count, the meeting's start and end
 * (the minute buckets are anchored to them), whether the meeting still exists,
 * the length of samples_json and its last 40 characters. A live meeting that
 * gets a new projection in the same millisecond with the same count changes
 * the length or the tail in practice (it appends, or digits change).
 * NOT covered: an edit in the middle of samples_json that keeps its length,
 * its tail, its count and fetched_at. projectRawHr never produces that: any row
 * it rewrites gets a strictly greater fetched_at (the incoming time if newer,
 * else the stored time plus 1 ms).
 */
function validatorOf(r: ValidatorRow): string {
  return JSON.stringify([
    r.event_id, r.window_start_utc, r.window_end_utc, r.status, r.sample_count, r.error_text, r.fetched_at,
    r.ev_start, r.ev_end, r.samples_len, r.samples_tail,
  ]);
}

type CacheEntry = { validator: string; window: ScoringHrWindow };

/**
 * Computed minute averages, kept per isolate. The Worker talks to one database,
 * and `env.DB` can be a new object on every request, so the key is the event id
 * and correctness rests on the validator, never on the database object. Two
 * databases that hold the same event id with identical stored rows and
 * identical meeting times would be indistinguishable here, which cannot happen
 * in production (one database). Map order is recency: a hit or a store moves
 * the entry to the end, and the front is dropped when over the cap.
 */
const scoringCache = new Map<string, CacheEntry>();

/** Tests only: forget everything. */
export function resetScoringHrCache(): void {
  scoringCache.clear();
}

const copyWindow = (w: ScoringHrWindow): ScoringHrWindow => ({
  ...w,
  minutePoints: w.minutePoints.map(([t, b]): HrPoint => [t, b]),
});

/** Store under the validator of the very row the averages came from. */
function remember(row: ScoringHrRow, window: ScoringHrWindow): void {
  scoringCache.delete(row.event_id);
  scoringCache.set(row.event_id, { validator: validatorOf(row), window: copyWindow(window) });
  while (scoringCache.size > SCORING_CACHE_MAX) {
    const oldest = scoringCache.keys().next();
    if (oldest.done) break;
    scoringCache.delete(oldest.value);
  }
}

/**
 * The meeting times to anchor minute buckets at, for meetings whose owner (or
 * the Mac) changed them. Everything else reads the calendar's own times.
 */
export type MeetingAnchors = ReadonlyMap<string, { startUtc: string; endUtc: string }>;

/**
 * SQL pieces for the meeting's start and end: the calendar row, or the
 * anchor when there is one. A meeting that no longer exists still reads as
 * missing (NULL), so a deleted meeting invalidates its cache entry.
 */
function anchorSql(anchors?: MeetingAnchors) {
  if (!anchors?.size) return { join: "", start: "e.start_utc", end: "e.end_utc", params: [] as string[] };
  return {
    join: `LEFT JOIN (SELECT value ->> 0 AS id, value ->> 1 AS s, value ->> 2 AS e FROM json_each(?2)) o ON o.id = h.event_id`,
    start: "CASE WHEN e.start_utc IS NULL THEN NULL ELSE COALESCE(o.s, e.start_utc) END",
    end: "CASE WHEN e.end_utc IS NULL THEN NULL ELSE COALESCE(o.e, e.end_utc) END",
    params: [JSON.stringify([...anchors].map(([id, a]) => [id, a.startUtc, a.endUtc]))],
  };
}

/** Cheap: nothing is expanded, and the samples column is read only for its length and tail. */
async function readValidators(db: D1Database, ids: string[], anchors?: MeetingAnchors): Promise<ValidatorRow[]> {
  const anchor = anchorSql(anchors);
  try {
    const res = await db.prepare(
      `SELECT h.event_id, h.window_start_utc, h.window_end_utc, h.status, h.sample_count, h.error_text, h.fetched_at,
              ${anchor.start} AS ev_start, ${anchor.end} AS ev_end,
              length(h.samples_json) AS samples_len, substr(h.samples_json, -${TAIL_CHARS}) AS samples_tail
       FROM whoop_web_hr h
       LEFT JOIN calendar_event e ON e.id = h.event_id
       ${anchor.join}
       WHERE h.event_id IN (SELECT value FROM json_each(?1))`,
    ).bind(JSON.stringify(ids), ...anchor.params).all<ValidatorRow>();
    return res.results ?? [];
  } catch {
    return [];
  }
}

/** Return only minute averages for scoring, with the raw series opt-in for a single detail row. */
async function readScoringHr(
  db: D1Database, ids: string[], includeRaw = false, anchors?: MeetingAnchors,
): Promise<ScoringHrRow[]> {
  const anchor = anchorSql(anchors);
  const padMs = WINDOW_PAD_MIN * 60_000;
  // Anchor buckets at the meeting start, and restart them at the end so the
  // last minute inside never absorbs padding. MIN(t) preserves the timestamp
  // of a bucket with a single reading, including Codebox's minute samples.
  // The group key rounds down even for the negative offsets before the start.
  const epochMs = (column: string) =>
    `(1000 * unixepoch(${column}) + CAST(substr(strftime('%f', ${column}), 4) AS INTEGER))`;
  try {
    const res = await db.prepare(
      `WITH windows AS (
         SELECT h.*, ${anchor.start} AS ev_start, ${anchor.end} AS ev_end,
                COALESCE(${epochMs(anchor.start)}, ${epochMs("h.window_start_utc")} + ${padMs}) AS start_ms,
                COALESCE(${epochMs(anchor.end)}, ${epochMs("h.window_end_utc")} - ${padMs}) AS end_ms,
                ${epochMs("h.window_start_utc")} AS win_from, ${epochMs("h.window_end_utc")} AS win_to
         FROM whoop_web_hr h
         LEFT JOIN calendar_event e ON e.id = h.event_id
         ${anchor.join}
         WHERE h.event_id IN (SELECT value FROM json_each(?1))
       )
       SELECT w.event_id, w.window_start_utc, w.window_end_utc, w.status, w.sample_count, w.error_text, w.fetched_at,
              w.ev_start, w.ev_end,
              length(w.samples_json) AS samples_len, substr(w.samples_json, -${TAIL_CHARS}) AS samples_tail,
              ${includeRaw ? "w.samples_json" : "NULL AS samples_json"},
              (
                SELECT json_group_array(json_array(t, bpm))
                FROM (
                  SELECT MIN(t) AS t, AVG(bpm) AS bpm
                  FROM (
                    SELECT t, bpm, t >= w.end_ms AS is_after,
                           (t - CASE WHEN t >= w.end_ms THEN w.end_ms ELSE w.start_ms END) / 60000.0 AS minute_offset
                    FROM (
                      SELECT value ->> 0 AS t, value ->> 1 AS bpm
                      FROM json_each(CASE WHEN w.status = 'ok' AND json_valid(w.samples_json)
                                          THEN CASE WHEN json_type(w.samples_json) = 'array' THEN w.samples_json END
                                     END)
                      WHERE type = 'array'
                        -- Points kept outside the row's own window are never scored (see raw.ts).
                        AND value ->> 0 BETWEEN w.win_from AND w.win_to
                    )
                  )
                  WHERE typeof(t) IN ('integer', 'real') AND typeof(bpm) IN ('integer', 'real')
                  GROUP BY is_after, CAST(minute_offset AS INTEGER) - (minute_offset < CAST(minute_offset AS INTEGER))
                  ORDER BY MIN(t)
                )
              ) AS minute_json
       FROM windows w`,
    ).bind(JSON.stringify(ids), ...anchor.params).all<ScoringHrRow>();
    return res.results ?? [];
  } catch {
    return [];
  }
}

/**
 * Minute averages for scoring. A cheap metadata query decides which cached
 * entries are still good; only the others run the json_each aggregation, in
 * batches. A failed query returns nothing for its ids and caches nothing.
 * Callers get their own copies, never the cached arrays.
 */
export async function listScoringHr(db: D1Database, ids: string[], anchors?: MeetingAnchors): Promise<ScoringHrWindow[]> {
  const unique = [...new Set(ids)];
  const rows: ScoringHrWindow[] = [];
  for (let i = 0; i < unique.length; i += METADATA_BATCH_SIZE) {
    const current = await readValidators(db, unique.slice(i, i + METADATA_BATCH_SIZE), anchors);
    const misses: string[] = [];
    // Keep the metadata query's order: hits and recomputed rows interleave.
    const slots: Array<ScoringHrWindow | string> = [];
    for (const v of current) {
      const entry = scoringCache.get(v.event_id);
      if (entry && entry.validator === validatorOf(v)) {
        scoringCache.delete(v.event_id);
        scoringCache.set(v.event_id, entry);
        slots.push(copyWindow(entry.window));
      } else {
        misses.push(v.event_id);
        slots.push(v.event_id);
      }
    }
    const fresh = new Map<string, ScoringHrWindow>();
    for (let j = 0; j < misses.length; j += SCORING_BATCH_SIZE) {
      for (const row of await readScoringHr(db, misses.slice(j, j + SCORING_BATCH_SIZE), false, anchors)) {
        const window = scoringFromRow(row);
        remember(row, window);
        fresh.set(row.event_id, window);
      }
    }
    for (const slot of slots) {
      if (typeof slot !== "string") rows.push(slot);
      else {
        const w = fresh.get(slot);
        if (w) rows.push(copyWindow(w));
      }
    }
  }
  return rows;
}

/** Read the chart and scoring series from the same version of the stored row. */
export async function getDetailHr(
  db: D1Database, id: string, anchors?: MeetingAnchors,
): Promise<{ raw: CachedHrWindow; scoring: ScoringHrWindow } | null> {
  const [row] = await readScoringHr(db, [id], true, anchors);
  if (!row) return null;
  const scoring = scoringFromRow(row);
  remember(row, scoring);
  return { raw: hrFromRow(row), scoring };
}

/**
 * Store one fetched answer for a meeting. Never loses a stored point: the fetched
 * points win on the same timestamp, and stored points the answer did not return
 * stay (a point outside the window is kept but hidden, see raw.ts). An error or an
 * empty answer therefore removes nothing. `status` and `sample_count` describe the
 * points inside the window: stored points inside it make an 'empty' answer 'ok', and
 * an 'error' answer keeps its status (readers show nothing for it) while the points
 * stay for the next good answer or projection. The merge is read and written in one
 * statement, so it cannot race another writer into dropping a point.
 *
 * `failed` says this write is the result of a fetch that did not answer (the caller may
 * still pass the kept points of an earlier good row, with the time of the failed attempt).
 * Such a write must not make the row look fetched: on a row marked "not fetched for this
 * window" (see NOT_FETCHED_SLACK_MS) the mark stays, so the next fill or page open asks again.
 * Every other write stores `fetchedAt` as given.
 *
 * Returns the status that was stored.
 */
export async function putCachedHr(db: D1Database, w: CachedHrWindow, failed = false): Promise<CachedHrStatus> {
  const finite = (ms: number) => (Number.isFinite(ms) ? ms : null);
  const stored = await db
    .prepare(
      `WITH fetched AS (
         SELECT t, b FROM (SELECT value ->> 0 AS t, value ->> 1 AS b FROM json_each(?7) WHERE type = 'array')
         WHERE typeof(t) IN ('integer', 'real') AND typeof(b) IN ('integer', 'real')
       ), kept AS (
         SELECT t, b FROM (
           SELECT value ->> 0 AS t, value ->> 1 AS b
           FROM whoop_web_hr AS h,
                json_each(CASE WHEN json_valid(h.samples_json) THEN CASE WHEN json_type(h.samples_json) = 'array' THEN h.samples_json END END)
           WHERE h.event_id = ?1 AND type = 'array'
         ) WHERE typeof(t) IN ('integer', 'real') AND typeof(b) IN ('integer', 'real')
           AND t NOT IN (SELECT t FROM fetched)
       ), summary AS (
         SELECT COUNT(*) AS total, COALESCE(SUM(t BETWEEN ?8 AND ?9), 0) AS inside,
                json_group_array(json_array(t, b)) AS samples_json
         FROM (SELECT t, b FROM fetched UNION ALL SELECT t, b FROM kept ORDER BY t)
       )
       INSERT INTO whoop_web_hr
         (event_id, window_start_utc, window_end_utc, status, sample_count, samples_json, error_text, fetched_at)
       SELECT ?1, ?2, ?3,
              CASE WHEN ?4 = 'error' THEN 'error' WHEN inside > 0 THEN 'ok' ELSE 'empty' END,
              inside, CASE WHEN total > 0 THEN samples_json END, ?5, ?6
       FROM summary WHERE true
       ON CONFLICT(event_id) DO UPDATE SET
         window_start_utc = excluded.window_start_utc,
         window_end_utc = excluded.window_end_utc,
         status = excluded.status,
         sample_count = excluded.sample_count,
         samples_json = excluded.samples_json,
         error_text = excluded.error_text,
         -- A failed attempt on a row marked "not fetched" keeps the mark: the stored time for the
         -- same window, otherwise the new window's start. Everything else stores the given time.
         fetched_at = CASE
           WHEN ?10 AND whoop_web_hr.fetched_at < strftime('%Y-%m-%dT%H:%M:%fZ', whoop_web_hr.window_start_utc, printf('+%.3f seconds', ?11 / 1000.0))
           THEN CASE WHEN whoop_web_hr.window_start_utc = excluded.window_start_utc AND whoop_web_hr.window_end_utc = excluded.window_end_utc
                     THEN whoop_web_hr.fetched_at ELSE excluded.window_start_utc END
           ELSE excluded.fetched_at
         END
       RETURNING status`,
    )
    .bind(
      w.eventId,
      w.windowStartUtc,
      w.windowEndUtc,
      w.status,
      w.errorText,
      w.fetchedAt,
      JSON.stringify(w.points),
      finite(Date.parse(w.windowStartUtc)),
      finite(Date.parse(w.windowEndUtc)),
      failed ? 1 : 0,
      NOT_FETCHED_SLACK_MS,
    )
    .first<{ status: string }>();
  if (!stored) throw new Error(`Heart rate row for ${w.eventId} was not stored`);
  return status(stored.status);
}

export async function getCachedStressDays(db: D1Database, days: string[]): Promise<Map<string, CachedStressDay>> {
  const out = new Map<string, CachedStressDay>();
  const list = [...new Set(days)].filter((d) => /^\d{4}-\d{2}-\d{2}$/.test(d)).sort();
  if (!list.length) return out;
  try {
    const res = await db
      .prepare(
        `SELECT day, status, points_json, current_level, peak_level, min_level, error_text, fetched_at
         FROM whoop_web_stress_day WHERE day >= ? AND day <= ?`,
      )
      .bind(list[0], list[list.length - 1])
      .all<StressRow>();
    const want = new Set(list);
    for (const r of res.results ?? []) if (want.has(r.day)) out.set(r.day, stressFromRow(r));
  } catch {
    /* table missing: nothing cached */
  }
  return out;
}

export async function putCachedStressDay(db: D1Database, s: CachedStressDay): Promise<void> {
  await db
    .prepare(
      `INSERT INTO whoop_web_stress_day
         (day, status, point_count, points_json, current_level, peak_level, min_level, error_text, fetched_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(day) DO UPDATE SET
         status = excluded.status,
         point_count = excluded.point_count,
         points_json = excluded.points_json,
         current_level = excluded.current_level,
         peak_level = excluded.peak_level,
         min_level = excluded.min_level,
         error_text = excluded.error_text,
         fetched_at = excluded.fetched_at`,
    )
    .bind(
      s.day,
      s.status,
      s.points.length,
      s.points.length ? JSON.stringify(s.points) : null,
      s.currentLevel,
      s.peakLevel,
      s.minLevel,
      s.errorText,
      s.fetchedAt,
    )
    .run();
}
