import { MAX_MEETING_S, MAX_MOVED_MEETING_S, fetchWindow, meetingLimitS } from "./meeting-hr.ts";
import type { HrPoint } from "./parse.ts";
import { WINDOW_PAD_MIN } from "./constants.ts";
import { applyOverrides, loadOverridesForIds, OverrideSet, type ResolvedOverride } from "../../lib/meeting-override.ts";

export const LIVE_MAX_POINTS = 60;
// Covers the longest supported meeting (12 h, a window the owner moved) plus both pads, with room for retries.
export const LIVE_RETENTION_MS = 13 * 60 * 60_000;
const CLOCK_SKEW_MS = 10_000;

export function parseLiveBatch(body: unknown): { points: HrPoint[]; includeMeeting: boolean } | null {
  if (!body || typeof body !== "object") return null;
  const { version, points, includeMeeting } = body as Record<string, unknown>;
  if (version !== 1 || !Array.isArray(points) || !points.length || points.length > LIVE_MAX_POINTS) return null;
  const unique = new Map<number, number>();
  for (const pair of points) {
    if (!Array.isArray(pair) || pair.length !== 2) return null;
    const [ts, bpm] = pair;
    if (!Number.isSafeInteger(ts) || ts < 100_000_000_000 || !Number.isInteger(bpm) || bpm < 25 || bpm > 250) return null;
    unique.set(ts, bpm);
  }
  return { points: [...unique], includeMeeting: includeMeeting === true };
}

type MeetingRow = { id: string; title: string | null; start_utc: string; end_utc: string; duration_s: number; override?: ResolvedOverride };

function liveMeeting(row: MeetingRow) {
  return { id: row.id, title: row.title, startUtc: row.start_utc, endUtc: row.end_utc };
}

/** Candidates are read wider than the calendar test (a start up to 2 h early, an end up to 4 h late, a 12 h window). */
const SLACK_BEFORE_MS = 16 * 3600_000;
const SLACK_AFTER_MS = 3 * 3600_000;

export async function currentLiveMeeting(db: D1Database, now: number) {
  const padMs = WINDOW_PAD_MIN * 60_000;
  const nowUtc = new Date(now).toISOString();
  const startFrom = new Date(now - MAX_MEETING_S * 1000 - padMs).toISOString();
  const movedStartFrom = new Date(now - MAX_MOVED_MEETING_S * 1000 - padMs).toISOString();
  const endFrom = new Date(now - padMs).toISOString();
  // Tested again on effective times below, so a meeting the owner moved or extended counts and one they left out does not.
  const { results } = await db.prepare(`SELECT id, title, start_utc, end_utc, duration_s FROM calendar_event
    WHERE start_utc BETWEEN ? AND ? AND end_utc >= ? AND deleted_at IS NULL
      AND source_type = 'calendar'`)
    .bind(new Date(Date.parse(movedStartFrom) - SLACK_BEFORE_MS).toISOString(), new Date(now + SLACK_AFTER_MS).toISOString(),
      new Date(Date.parse(endFrom) - 4 * 3600_000).toISOString())
    .all<MeetingRow>();
  const found = results ?? [];
  const rows = applyOverrides(found, found.length ? await loadOverridesForIds(db, found.map((row) => row.id)) : OverrideSet.none)
    .filter((row) => row.start_utc >= (row.override?.timesChanged ? movedStartFrom : startFrom) && row.start_utc <= nowUtc &&
      row.end_utc >= endFrom && row.duration_s > 0 && row.duration_s <= meetingLimitS(row.override?.timesChanged));
  // Prefer a meeting in progress over a preceding meeting in its after-pad.
  rows.sort((a, b) => Number(b.end_utc >= nowUtc) - Number(a.end_utc >= nowUtc) ||
    b.start_utc.localeCompare(a.start_utc) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return rows[0] ? liveMeeting(rows[0]) : null;
}

export async function liveMeetingWindow(db: D1Database, id: string) {
  const found = await db.prepare(`SELECT id, title, start_utc, end_utc, duration_s FROM calendar_event
    WHERE id = ? AND deleted_at IS NULL AND source_type = 'calendar'`)
    .bind(id).first<MeetingRow>();
  if (!found) return null;
  const [row] = applyOverrides([found], await loadOverridesForIds(db, [id]));
  if (!row || !(row.duration_s > 0 && row.duration_s <= meetingLimitS(row.override?.timesChanged))) return null;
  const pad = fetchWindow(row.start_utc, row.end_utc);
  return { startMs: Date.parse(row.start_utc), endMs: Date.parse(row.end_utc), fromMs: pad.startMs, toMs: pad.endMs };
}

export type LiveRead = { points: HrPoint[]; cursor: number };

/** One private buffer per Worker installation. Only the Worker routes call it. */
export class LiveHeartRate {
  private storage: DurableObjectStorage;

  constructor(state: DurableObjectState) {
    this.storage = state.storage;
    this.storage.sql.exec(`CREATE TABLE IF NOT EXISTS points (
      ts INTEGER PRIMARY KEY, bpm INTEGER NOT NULL, revision INTEGER NOT NULL
    ); CREATE INDEX IF NOT EXISTS points_revision ON points(revision);`);
  }

  async fetch(request: Request): Promise<Response> {
    const now = Date.now();
    const sql = this.storage.sql;
    if (request.method === "POST") {
      const points = await request.json<HrPoint[]>();
      this.storage.transactionSync(() => {
        const { revision } = sql.exec<{ revision: number }>("SELECT COALESCE(MAX(revision), 0) AS revision FROM points").one();
        const next = Math.max(now * 1000, revision + 1);
        for (const [ts, bpm] of points) {
          if (ts <= now - LIVE_RETENTION_MS || ts > now + CLOCK_SKEW_MS) continue;
          sql.exec(`INSERT INTO points (ts, bpm, revision) VALUES (?, ?, ?)
            ON CONFLICT(ts) DO UPDATE SET bpm = excluded.bpm, revision = excluded.revision
            WHERE points.bpm <> excluded.bpm`, ts, bpm, next);
        }
      });
      await this.scheduleCleanup();
      return Response.json({ ok: true });
    }

    const query = new URL(request.url).searchParams;
    const since = Number(query.get("since"));
    const from = Math.max(Number(query.get("from")), now - LIVE_RETENTION_MS + 1);
    const to = Number(query.get("to"));
    const rows = sql.exec<{ ts: number; bpm: number; revision: number }>(
      "SELECT ts, bpm, revision FROM points WHERE ts BETWEEN ? AND ? AND revision > ? ORDER BY ts",
      from, to, since,
    );
    const points: HrPoint[] = [];
    let cursor = since;
    for (const { ts, bpm, revision } of rows) {
      points.push([ts, bpm]);
      cursor = Math.max(cursor, revision);
    }
    return Response.json({ points, cursor } satisfies LiveRead);
  }

  async alarm() {
    this.storage.sql.exec("DELETE FROM points WHERE ts <= ?", Date.now() - LIVE_RETENTION_MS);
    await this.scheduleCleanup();
  }

  private async scheduleCleanup() {
    const oldest = this.storage.sql.exec<{ ts: number }>("SELECT ts FROM points ORDER BY ts LIMIT 1").toArray()[0];
    if (!oldest) return;
    const at = Math.ceil((oldest.ts + LIVE_RETENTION_MS) / 60_000) * 60_000;
    const scheduled = await this.storage.getAlarm();
    if (scheduled === null || scheduled > at) await this.storage.setAlarm(at);
  }
}
