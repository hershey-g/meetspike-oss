import { addCalendarDays, localDayRangeUtc } from "../../lib/time.ts";
import { applyOverrides, loadOverridesInRange, type ResolvedOverride } from "../../lib/meeting-override.ts";
import type { WhoopWebIngestSource } from "./ingest-payload.ts";
import { fetchWindow, MAX_MEETING_S, meetingLimitS, NOT_FETCHED_SLACK_MS, type MeetingInput } from "./meeting-hr.ts";
import type { HrPoint } from "./parse.ts";

// The Worker authenticates writers for a single owner per installation.
const OWNER = "owner";
const RAW_BATCH_SIZE = 2_000;
const PROJECTION_BATCH_SIZE = 16;

export async function storeRawHr(db: D1Database, source: WhoopWebIngestSource, points: HrPoint[], now: number): Promise<void> {
  if (!points.length) return;
  const receivedAt = new Date(now).toISOString();
  const statements: D1PreparedStatement[] = [];
  for (let i = 0; i < points.length; i += RAW_BATCH_SIZE) {
    statements.push(db.prepare(
      `INSERT INTO whoop_web_hr_raw (user_id, source, time_ms, bpm, received_at)
       SELECT ?, ?, value ->> 0, value ->> 1, ? FROM json_each(?) WHERE true
       ON CONFLICT(user_id, time_ms, source) DO UPDATE SET
         bpm = excluded.bpm, received_at = excluded.received_at
       WHERE whoop_web_hr_raw.bpm <> excluded.bpm`,
    ).bind(OWNER, source, receivedAt, JSON.stringify(points.slice(i, i + RAW_BATCH_SIZE))));
  }
  if ((await db.batch(statements)).some((r) => !r.success)) throw new Error("Could not store raw heart rate");
}

/**
 * `meeting` carries the times heart rate is cut to. When the owner or the Mac
 * changed them, `calendar` holds the calendar row's own times: the row must
 * still match them exactly, so a meeting edited in the calendar meanwhile is
 * not projected under stale times.
 */
export type Projection = { meeting: MeetingInput; allowEmpty: boolean; calendar?: { startUtc: string; endUtc: string } };
type Counts = { written: number; empty: number; unchanged: number };

/**
 * Read the raw window and write its projection in the same SQL statement.
 * This prevents concurrent rebuilds and ingests from writing older snapshots.
 *
 * The row never ends with fewer points than it held. Some exist only in
 * samples_json (WHOOP cannot be asked again), so a window change must not drop them:
 *   - raw rows inside the NEW window win over a stored point at the same
 *     timestamp, and BLE wins over Codebox on a collision between the two;
 *   - every point already stored for the meeting is kept, whatever the row's
 *     window or status was. Those outside the new window stay in samples_json
 *     (every reader cuts to the row's window, see store.ts), so going back to
 *     the old times shows them again;
 *   - status and sample_count describe the points INSIDE the window. A window
 *     with none, but kept points outside, is 'empty' with count 0 and the points kept.
 * Fetchability: a window change over kept points that are not raw rows (WHOOP holds the
 * rest of the new window and was never asked) must not look like a finished fetch. The
 * row is then marked "not fetched for this window" (fetched_at = the new window's start,
 * see NOT_FETCHED_SLACK_MS in meeting-hr.ts), and stays marked through later projections
 * of the same window until a fetch answers. Rows whose points are all raw rows, and rows
 * with no window change, get fetched_at exactly as before.
 * A meeting nothing changed for writes exactly what it wrote before, so a repeated
 * ingest rewrites nothing (the DO UPDATE only fires on a difference). Read and write
 * share one statement, so a re-projection racing an ingest or a fetch only ever adds
 * points to what is stored.
 */
function project(db: D1Database, { meeting, allowEmpty, calendar }: Projection, fetchedAt: string): D1PreparedStatement {
  const win = fetchWindow(meeting.startUtc, meeting.endUtc);
  return db.prepare(
    `WITH raw AS MATERIALIZED (
       SELECT time_ms, COALESCE(MAX(CASE WHEN source = 'ble' THEN bpm END), MAX(bpm)) AS bpm
       FROM whoop_web_hr_raw
       WHERE user_id = ?1 AND time_ms BETWEEN ?2 AND ?3
       GROUP BY time_ms
     ), kept AS MATERIALIZED (
       SELECT t AS time_ms, b AS bpm FROM (
         SELECT value ->> 0 AS t, value ->> 1 AS b
         FROM whoop_web_hr AS h,
              json_each(CASE WHEN json_valid(h.samples_json) THEN CASE WHEN json_type(h.samples_json) = 'array' THEN h.samples_json END END)
         WHERE h.event_id = ?4 AND type = 'array'
       ) WHERE typeof(t) IN ('integer', 'real') AND typeof(b) IN ('integer', 'real')
     ), samples AS (
       SELECT time_ms, bpm FROM raw
       UNION ALL
       SELECT time_ms, bpm FROM kept WHERE NOT EXISTS (SELECT 1 FROM raw WHERE raw.time_ms = kept.time_ms)
     ), summary AS (
       SELECT COUNT(*) AS total, COALESCE(SUM(time_ms BETWEEN ?2 AND ?3), 0) AS sample_count,
              json_group_array(json_array(time_ms, bpm)) AS samples_json
       FROM (SELECT time_ms, bpm FROM samples ORDER BY time_ms)
     )
     INSERT INTO whoop_web_hr
       (event_id, window_start_utc, window_end_utc, status, sample_count, samples_json, error_text, fetched_at)
     SELECT ?4, ?5, ?6, CASE WHEN sample_count > 0 THEN 'ok' ELSE 'empty' END, sample_count,
            CASE WHEN total > 0 THEN samples_json END, NULL, ?7
     FROM summary
     WHERE (total > 0 OR ?8)
       AND EXISTS (SELECT 1 FROM calendar_event WHERE id = ?4 AND start_utc = ?9 AND end_utc = ?10 AND deleted_at IS NULL)
     ON CONFLICT(event_id) DO UPDATE SET
       window_start_utc = excluded.window_start_utc, window_end_utc = excluded.window_end_utc,
       status = excluded.status, sample_count = excluded.sample_count, samples_json = excluded.samples_json,
       error_text = NULL,
       -- A rewritten row must look newer to the scoring cache: take the incoming time when it is
       -- ahead, otherwise the stored time plus 1 ms (text shape YYYY-MM-DDTHH:MM:SS.mmmZ).
       -- Except for a row that is not fetched for its window (see NOT_FETCHED_SLACK_MS):
       --  * a window change over stored points that are not raw rows writes the mark, the NEW
       --    window's start, so the row is fetched again for that window;
       --  * a marked row rewritten for the same window keeps the mark: stored time plus 1 ms, never
       --    past the slack (the scoring cache still sees every change in practice), never "now".
       fetched_at = CASE
         WHEN (whoop_web_hr.window_start_utc <> excluded.window_start_utc OR whoop_web_hr.window_end_utc <> excluded.window_end_utc)
              AND EXISTS (
                SELECT 1 FROM json_each(CASE WHEN json_valid(whoop_web_hr.samples_json)
                                             THEN CASE WHEN json_type(whoop_web_hr.samples_json) = 'array' THEN whoop_web_hr.samples_json END END) k
                WHERE k.type = 'array' AND typeof(k.value ->> 0) IN ('integer', 'real') AND typeof(k.value ->> 1) IN ('integer', 'real')
                  AND NOT EXISTS (SELECT 1 FROM whoop_web_hr_raw r WHERE r.user_id = ?1 AND r.time_ms = k.value ->> 0))
           THEN excluded.window_start_utc
         WHEN whoop_web_hr.window_start_utc = excluded.window_start_utc AND whoop_web_hr.window_end_utc = excluded.window_end_utc
              AND whoop_web_hr.fetched_at < strftime('%Y-%m-%dT%H:%M:%fZ', whoop_web_hr.window_start_utc, printf('+%.3f seconds', ?11 / 1000.0))
           THEN min(
             strftime('%Y-%m-%dT%H:%M:%S', (CAST(strftime('%s', whoop_web_hr.fetched_at) AS INTEGER) * 1000
                                            + CAST(substr(whoop_web_hr.fetched_at, 21, 3) AS INTEGER) + 1) / 1000, 'unixepoch')
             || '.' || printf('%03d', (CAST(substr(whoop_web_hr.fetched_at, 21, 3) AS INTEGER) + 1) % 1000) || 'Z',
             strftime('%Y-%m-%dT%H:%M:%fZ', whoop_web_hr.window_start_utc, printf('+%.3f seconds', (?11 - 1) / 1000.0)))
         WHEN excluded.fetched_at > whoop_web_hr.fetched_at THEN excluded.fetched_at
         ELSE
           strftime('%Y-%m-%dT%H:%M:%S', (CAST(strftime('%s', whoop_web_hr.fetched_at) AS INTEGER) * 1000
                                          + CAST(substr(whoop_web_hr.fetched_at, 21, 3) AS INTEGER) + 1) / 1000, 'unixepoch')
           || '.' || printf('%03d', (CAST(substr(whoop_web_hr.fetched_at, 21, 3) AS INTEGER) + 1) % 1000) || 'Z'
       END
     WHERE whoop_web_hr.window_start_utc <> excluded.window_start_utc
        OR whoop_web_hr.window_end_utc <> excluded.window_end_utc
        OR whoop_web_hr.status <> excluded.status
        OR whoop_web_hr.samples_json IS NOT excluded.samples_json
     RETURNING status`,
  ).bind(OWNER, win.startMs, win.endMs, meeting.id, win.startUtc, win.endUtc, fetchedAt, Number(allowEmpty),
    calendar?.startUtc ?? meeting.startUtc, calendar?.endUtc ?? meeting.endUtc, NOT_FETCHED_SLACK_MS);
}

export async function projectRawHr(db: D1Database, projections: Projection[], fetchedAt: string): Promise<Counts> {
  const counts: Counts = { written: 0, empty: 0, unchanged: 0 };
  for (let i = 0; i < projections.length; i += PROJECTION_BATCH_SIZE) {
    const batch = projections.slice(i, i + PROJECTION_BATCH_SIZE);
    const results = await db.batch<{ status: string }>(batch.map((p) => project(db, p, fetchedAt)));
    for (const result of results) {
      if (!result.success) throw new Error("Could not project meeting heart rate");
      const row = result.results[0];
      if (!row) counts.unchanged += 1;
      else if (row.status === "ok") counts.written += 1;
      else counts.empty += 1;
    }
  }
  return counts;
}

type DayRow = { id: string; start_utc: string; end_utc: string; duration_s: number; override?: ResolvedOverride };

/**
 * Rebuild meetings that start on the requested local calendar day. Meetings
 * the owner left out are skipped, and a meeting whose times were changed is
 * cut to its effective times (and counts for the day it effectively starts).
 */
export async function rebuildRawHrDay(db: D1Database, day: string, timeZone: string, now: number): Promise<Counts> {
  const { startUtc, endUtcExclusive } = localDayRangeUtc(day, day, timeZone);
  const nowUtc = new Date(now).toISOString();
  const { results } = await db.prepare(
    `SELECT id, start_utc, end_utc, duration_s FROM calendar_event
     WHERE start_utc >= ? AND start_utc < ? AND start_utc <= ?
       AND deleted_at IS NULL AND duration_s > 0 AND duration_s <= ?
     ORDER BY start_utc, id`,
  ).bind(startUtc, endUtcExclusive, nowUtc, MAX_MEETING_S).all<DayRow>();
  let rows: DayRow[] = results;
  const set = await loadOverridesInRange(db, localDayRangeUtc(addCalendarDays(day, -1), addCalendarDays(day, 1), timeZone));
  if (set.size) {
    const shifted = set.shiftedEventIds();
    if (shifted.length) {
      const have = new Set(rows.map((row) => row.id));
      const extra = await db.prepare(
        `SELECT id, start_utc, end_utc, duration_s FROM calendar_event
         WHERE deleted_at IS NULL AND id IN (SELECT value FROM json_each(?))`,
      ).bind(JSON.stringify(shifted)).all<DayRow>();
      rows = [...rows, ...(extra.results ?? []).filter((row) => !have.has(row.id))];
    }
    rows = applyOverrides(rows, set)
      .filter((row) => row.start_utc >= startUtc && row.start_utc < endUtcExclusive && row.start_utc <= nowUtc &&
        row.duration_s > 0 && row.duration_s <= meetingLimitS(row.override?.timesChanged))
      .sort((a, b) => a.start_utc.localeCompare(b.start_utc) || a.id.localeCompare(b.id));
  }
  return projectRawHr(db, rows.map((row) => ({
    meeting: { id: row.id, startUtc: row.start_utc, endUtc: row.end_utc, day, ...(row.override?.timesChanged ? { effective: true as const } : {}) },
    allowEmpty: false,
    ...(row.override?.timesChanged ? { calendar: { startUtc: row.override.calendarStartUtc, endUtc: row.override.calendarEndUtc } } : {}),
  })), nowUtc);
}

/**
 * Project one meeting's stored raw heart rate again after its effective times
 * changed. Bounded (one meeting, one statement) and safe to fail. On success the
 * row follows the new window and keeps every stored point; when the window
 * changed over points that are not raw rows (WHOOP was never asked about the
 * new window), the row is marked "not fetched for this window" and the next
 * fill or page open fetches it (see project()). On an error, which is logged
 * with the meeting id, the old row stays: its window differs from the new one,
 * so the stale check in the 15 minute fill picks the meeting up again. Raw rows
 * are never touched.
 */
export async function reprojectMeeting(
  db: D1Database,
  meeting: { id: string; startUtc: string; endUtc: string; day: string },
  calendar: { startUtc: string; endUtc: string },
  now: number,
): Promise<"projected" | "skipped" | "failed"> {
  const seconds = (Date.parse(meeting.endUtc) - Date.parse(meeting.startUtc)) / 1000;
  const changed = meeting.startUtc !== calendar.startUtc || meeting.endUtc !== calendar.endUtc;
  if (!(seconds > 0 && seconds <= meetingLimitS(changed))) return "skipped";
  try {
    await projectRawHr(db, [{
      meeting: { ...meeting, ...(changed ? { effective: true as const } : {}) },
      allowEmpty: false,
      ...(changed ? { calendar } : {}),
    }], new Date(now).toISOString());
    return "projected";
  } catch (error) {
    console.error(JSON.stringify({ event: "override_reproject_failed", meetingId: meeting.id, error: String(error) }));
    return "failed";
  }
}
