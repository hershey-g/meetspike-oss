import type { CalendarEventRow, Projected } from "../types.ts";
import { SOURCE_OURA } from "../types.ts";
import { DEFAULT_TIME_ZONE } from "./time.ts";
import { parseAttendeesJson, type Attendee } from "./people.ts";

export async function findRaw(
  db: D1Database,
  endpoint: string,
  documentId: string,
  hash: string,
  source: string = SOURCE_OURA,
): Promise<{ id: number } | null> {
  return db
    .prepare(
      `SELECT id FROM raw_object
       WHERE source = ? AND endpoint = ? AND document_id = ? AND content_hash = ?
       LIMIT 1`,
    )
    .bind(source, endpoint, documentId, hash)
    .first<{ id: number }>();
}

export async function insertRaw(
  db: D1Database,
  row: {
    endpoint: string;
    documentId: string;
    day: string | null;
    r2Key: string;
    hash: string;
    fetchedAt: string;
  },
  source: string = SOURCE_OURA,
): Promise<number> {
  const res = await db
    .prepare(
      `INSERT INTO raw_object (source, endpoint, document_id, day, r2_key, content_hash, fetched_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       RETURNING id`,
    )
    .bind(source, row.endpoint, row.documentId, row.day, row.r2Key, row.hash, row.fetchedAt)
    .first<{ id: number }>();
  if (!res) throw new Error("insert raw_object returned no id");
  return res.id;
}

export async function loadTimeZone(db: D1Database): Promise<string> {
  const row = await db
    .prepare(`SELECT time_zone FROM user_profile WHERE id = ?`)
    .bind("self")
    .first<{ time_zone: string }>();
  return row?.time_zone || DEFAULT_TIME_ZONE;
}

export async function upsertCalendarEvent(
  db: D1Database,
  row: CalendarEventRow,
): Promise<"written" | "skipped"> {
  const existing = await db
    .prepare(
      `SELECT title, start_utc, end_utc, start_local, end_local, kind, after_hours,
              attendee_count, attendees_json, deleted_at, duration_s, location,
              source_type, plaud_file_id, sync_reason, has_transcript
       FROM calendar_event WHERE id = ? AND source = ?`,
    )
    .bind(row.id, row.source)
    .first<{
      title: string | null;
      start_utc: string;
      end_utc: string;
      start_local: string | null;
      end_local: string | null;
      kind: string;
      after_hours: number;
      attendee_count: number | null;
      attendees_json: string | null;
      deleted_at: string | null;
      duration_s: number;
      location: string | null;
      source_type: string | null;
      plaud_file_id: string | null;
      sync_reason: string | null;
      has_transcript: number | null;
    }>();
  if (
    existing &&
    existing.title === row.title &&
    existing.start_utc === row.start_utc &&
    existing.end_utc === row.end_utc &&
    existing.start_local === row.start_local &&
    existing.end_local === row.end_local &&
    existing.kind === row.kind &&
    existing.after_hours === row.after_hours &&
    existing.attendee_count === row.attendee_count &&
    (existing.attendees_json ?? null) === (row.attendees_json ?? null) &&
    existing.deleted_at === row.deleted_at &&
    existing.duration_s === row.duration_s &&
    existing.location === row.location &&
    (existing.source_type ?? "calendar") === (row.source_type ?? "calendar") &&
    (existing.plaud_file_id ?? null) === (row.plaud_file_id ?? null) &&
    (existing.sync_reason ?? null) === (row.sync_reason ?? null) &&
    (existing.has_transcript ?? null) === (row.has_transcript ?? null)
  ) {
    await replaceEventAttendees(db, row.id, row.source, parseAttendeesJson(row.attendees_json));
    return "skipped";
  }
  await db
    .prepare(
      `INSERT INTO calendar_event (
        id, source, day, start_utc, end_utc, tz_offset_min, duration_s, title, kind,
        client_key, project_key, attendee_count, attendees_json, after_hours, location, raw_id,
        deleted_at, updated_at, start_local, end_local,
        source_type, plaud_file_id, sync_reason, has_transcript, synced_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (id, source) DO UPDATE SET
        day = excluded.day,
        start_utc = excluded.start_utc,
        end_utc = excluded.end_utc,
        tz_offset_min = excluded.tz_offset_min,
        duration_s = excluded.duration_s,
        title = excluded.title,
        kind = excluded.kind,
        client_key = excluded.client_key,
        project_key = excluded.project_key,
        attendee_count = excluded.attendee_count,
        attendees_json = excluded.attendees_json,
        after_hours = excluded.after_hours,
        location = excluded.location,
        raw_id = excluded.raw_id,
        deleted_at = excluded.deleted_at,
        updated_at = excluded.updated_at,
        start_local = excluded.start_local,
        end_local = excluded.end_local,
        source_type = excluded.source_type,
        plaud_file_id = excluded.plaud_file_id,
        sync_reason = excluded.sync_reason,
        has_transcript = excluded.has_transcript,
        synced_at = excluded.synced_at`,
    )
    .bind(
      row.id,
      row.source,
      row.day,
      row.start_utc,
      row.end_utc,
      row.tz_offset_min,
      row.duration_s,
      row.title,
      row.kind,
      row.client_key,
      row.project_key,
      row.attendee_count,
      row.attendees_json,
      row.after_hours,
      row.location,
      row.raw_id,
      row.deleted_at,
      row.updated_at,
      row.start_local,
      row.end_local,
      row.source_type ?? "calendar",
      row.plaud_file_id ?? null,
      row.sync_reason ?? null,
      row.has_transcript ?? null,
      row.synced_at ?? null,
    )
    .run();
  await replaceEventAttendees(db, row.id, row.source, parseAttendeesJson(row.attendees_json));
  return "written";
}

export async function replaceEventAttendees(
  db: D1Database,
  eventId: string,
  source: string,
  attendees: Attendee[],
): Promise<void> {
  await db.prepare(`DELETE FROM calendar_attendee WHERE event_id = ? AND source = ?`).bind(eventId, source).run();
  if (!attendees.length) return;
  const stmts = attendees.map((a) =>
    db
      .prepare(
        `INSERT OR REPLACE INTO calendar_attendee (event_id, source, email, self, display_name) VALUES (?, ?, ?, ?, ?)`,
      )
      .bind(eventId, source, a.email, a.self ? 1 : 0, a.name),
  );
  await db.batch(stmts);
}

export async function applyProjected(db: D1Database, item: Projected): Promise<void> {
  switch (item.kind) {
    case "daily_sleep": {
      const r = item.row;
      await db
        .prepare(
          `INSERT INTO daily_sleep (
            day, source, source_day, score, total_sleep_s, time_in_bed_s, efficiency, latency_s,
            deep_s, rem_s, light_s, awake_s, avg_hrv, avg_hr, lowest_hr, respiratory_rate,
            contributors_json, raw_id, deleted_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (day, source) DO UPDATE SET
            source_day = excluded.source_day,
            score = excluded.score,
            total_sleep_s = coalesce(excluded.total_sleep_s, daily_sleep.total_sleep_s),
            time_in_bed_s = coalesce(excluded.time_in_bed_s, daily_sleep.time_in_bed_s),
            efficiency = coalesce(excluded.efficiency, daily_sleep.efficiency),
            latency_s = coalesce(excluded.latency_s, daily_sleep.latency_s),
            deep_s = coalesce(excluded.deep_s, daily_sleep.deep_s),
            rem_s = coalesce(excluded.rem_s, daily_sleep.rem_s),
            light_s = coalesce(excluded.light_s, daily_sleep.light_s),
            awake_s = coalesce(excluded.awake_s, daily_sleep.awake_s),
            avg_hrv = coalesce(excluded.avg_hrv, daily_sleep.avg_hrv),
            avg_hr = coalesce(excluded.avg_hr, daily_sleep.avg_hr),
            lowest_hr = coalesce(excluded.lowest_hr, daily_sleep.lowest_hr),
            respiratory_rate = coalesce(excluded.respiratory_rate, daily_sleep.respiratory_rate),
            contributors_json = excluded.contributors_json,
            raw_id = excluded.raw_id,
            deleted_at = excluded.deleted_at,
            updated_at = excluded.updated_at`,
        )
        .bind(
          r.day, r.source, r.source_day, r.score, r.total_sleep_s, r.time_in_bed_s, r.efficiency,
          r.latency_s, r.deep_s, r.rem_s, r.light_s, r.awake_s, r.avg_hrv, r.avg_hr, r.lowest_hr,
          r.respiratory_rate, r.contributors_json, r.raw_id, r.deleted_at, r.updated_at,
        )
        .run();
      return;
    }
    case "daily_readiness": {
      const r = item.row;
      await db
        .prepare(
          `INSERT INTO daily_readiness (
            day, source, source_day, score, temperature_deviation, contributors_json, raw_id, deleted_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (day, source) DO UPDATE SET
            source_day = excluded.source_day,
            score = excluded.score,
            temperature_deviation = excluded.temperature_deviation,
            contributors_json = excluded.contributors_json,
            raw_id = excluded.raw_id,
            deleted_at = excluded.deleted_at,
            updated_at = excluded.updated_at`,
        )
        .bind(
          r.day, r.source, r.source_day, r.score, r.temperature_deviation,
          r.contributors_json, r.raw_id, r.deleted_at, r.updated_at,
        )
        .run();
      return;
    }
    case "daily_activity": {
      const r = item.row;
      await db
        .prepare(
          `INSERT INTO daily_activity (
            day, source, source_day, score, steps, active_cal, total_cal, met_minutes,
            class_5_min, raw_id, deleted_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (day, source) DO UPDATE SET
            source_day = excluded.source_day,
            score = excluded.score,
            steps = excluded.steps,
            active_cal = excluded.active_cal,
            total_cal = excluded.total_cal,
            met_minutes = excluded.met_minutes,
            class_5_min = excluded.class_5_min,
            raw_id = excluded.raw_id,
            deleted_at = excluded.deleted_at,
            updated_at = excluded.updated_at`,
        )
        .bind(
          r.day, r.source, r.source_day, r.score, r.steps, r.active_cal, r.total_cal,
          r.met_minutes, r.class_5_min, r.raw_id, r.deleted_at, r.updated_at,
        )
        .run();
      return;
    }
    case "daily_stress": {
      const r = item.row;
      await db
        .prepare(
          `INSERT INTO daily_stress (
            day, source, source_day, stress_high_s, recovery_high_s, day_summary, raw_id, deleted_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (day, source) DO UPDATE SET
            source_day = excluded.source_day,
            stress_high_s = excluded.stress_high_s,
            recovery_high_s = excluded.recovery_high_s,
            day_summary = excluded.day_summary,
            raw_id = excluded.raw_id,
            deleted_at = excluded.deleted_at,
            updated_at = excluded.updated_at`,
        )
        .bind(
          r.day, r.source, r.source_day, r.stress_high_s, r.recovery_high_s,
          r.day_summary, r.raw_id, r.deleted_at, r.updated_at,
        )
        .run();
      return;
    }
    case "daily_strain": {
      const r = item.row;
      await db
        .prepare(
          `INSERT INTO daily_strain (
            day, source, source_day, strain, avg_hr, max_hr, kilojoule, raw_id, deleted_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (day, source) DO UPDATE SET
            source_day = excluded.source_day,
            strain = excluded.strain,
            avg_hr = excluded.avg_hr,
            max_hr = excluded.max_hr,
            kilojoule = excluded.kilojoule,
            raw_id = excluded.raw_id,
            deleted_at = excluded.deleted_at,
            updated_at = excluded.updated_at`,
        )
        .bind(
          r.day, r.source, r.source_day, r.strain, r.avg_hr, r.max_hr, r.kilojoule,
          r.raw_id, r.deleted_at, r.updated_at,
        )
        .run();
      return;
    }
    case "sleep_period": {
      const r = item.row;
      await db
        .prepare(
          `INSERT INTO sleep_periods (
            id, source, day, source_day, start_utc, end_utc, tz_offset_min, time_zone, period_type, is_nap,
            total_sleep_s, deep_s, rem_s, light_s, awake_s, efficiency, avg_hrv, lowest_hr, respiratory_rate,
            raw_id, deleted_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (id, source) DO UPDATE SET
            day = excluded.day,
            source_day = excluded.source_day,
            start_utc = excluded.start_utc,
            end_utc = excluded.end_utc,
            tz_offset_min = excluded.tz_offset_min,
            time_zone = excluded.time_zone,
            period_type = excluded.period_type,
            is_nap = excluded.is_nap,
            total_sleep_s = excluded.total_sleep_s,
            deep_s = excluded.deep_s,
            rem_s = excluded.rem_s,
            light_s = excluded.light_s,
            awake_s = excluded.awake_s,
            efficiency = excluded.efficiency,
            avg_hrv = excluded.avg_hrv,
            lowest_hr = excluded.lowest_hr,
            respiratory_rate = excluded.respiratory_rate,
            raw_id = excluded.raw_id,
            deleted_at = excluded.deleted_at,
            updated_at = excluded.updated_at`,
        )
        .bind(
          r.id, r.source, r.day, r.source_day, r.start_utc, r.end_utc, r.tz_offset_min, r.time_zone,
          r.period_type, r.is_nap, r.total_sleep_s, r.deep_s, r.rem_s, r.light_s, r.awake_s,
          r.efficiency, r.avg_hrv, r.lowest_hr, r.respiratory_rate, r.raw_id, r.deleted_at, r.updated_at,
        )
        .run();
      return;
    }
    case "workout": {
      const r = item.row;
      await db
        .prepare(
          `INSERT INTO workouts (
            id, source, day, source_day, start_utc, end_utc, activity, intensity, strain, calories,
            avg_hr, max_hr, raw_id, deleted_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (id, source) DO UPDATE SET
            day = excluded.day,
            source_day = excluded.source_day,
            start_utc = excluded.start_utc,
            end_utc = excluded.end_utc,
            activity = excluded.activity,
            intensity = excluded.intensity,
            strain = excluded.strain,
            calories = excluded.calories,
            avg_hr = excluded.avg_hr,
            max_hr = excluded.max_hr,
            raw_id = excluded.raw_id,
            deleted_at = excluded.deleted_at,
            updated_at = excluded.updated_at`,
        )
        .bind(
          r.id, r.source, r.day, r.source_day, r.start_utc, r.end_utc, r.activity, r.intensity,
          r.strain, r.calories, r.avg_hr, r.max_hr, r.raw_id, r.deleted_at, r.updated_at,
        )
        .run();
      return;
    }
    case "session": {
      const r = item.row;
      await db
        .prepare(
          `INSERT INTO sessions (
            id, source, start_utc, end_utc, type, mood, raw_id, deleted_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (id, source) DO UPDATE SET
            start_utc = excluded.start_utc,
            end_utc = excluded.end_utc,
            type = excluded.type,
            mood = excluded.mood,
            raw_id = excluded.raw_id,
            deleted_at = excluded.deleted_at,
            updated_at = excluded.updated_at`,
        )
        .bind(r.id, r.source, r.start_utc, r.end_utc, r.type, r.mood, r.raw_id, r.deleted_at, r.updated_at)
        .run();
      return;
    }
    case "tag": {
      const r = item.row;
      await db
        .prepare(
          `INSERT INTO tags (
            id, source, day, tag_code, comment, answered_yes, raw_id, deleted_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (id, source) DO UPDATE SET
            day = excluded.day,
            tag_code = excluded.tag_code,
            comment = excluded.comment,
            answered_yes = excluded.answered_yes,
            raw_id = excluded.raw_id,
            deleted_at = excluded.deleted_at,
            updated_at = excluded.updated_at`,
        )
        .bind(
          r.id, r.source, r.day, r.tag_code, r.comment, r.answered_yes, r.raw_id, r.deleted_at, r.updated_at,
        )
        .run();
      return;
    }
    case "user_profile": {
      const r = item.row;
      await db
        .prepare(
          `INSERT INTO user_profile (id, time_zone, oura_user_id, personal_json, updated_at)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT (id) DO UPDATE SET
             time_zone = excluded.time_zone,
             oura_user_id = excluded.oura_user_id,
             personal_json = excluded.personal_json,
             updated_at = excluded.updated_at`,
        )
        .bind(r.id, r.time_zone, r.oura_user_id, r.personal_json, r.updated_at)
        .run();
      return;
    }
    default:
      return;
  }
}

export async function tombstone(
  db: D1Database,
  table: "sleep_periods" | "workouts" | "sessions" | "tags",
  id: string,
  at: string,
): Promise<void> {
  await db
    .prepare(`UPDATE ${table} SET deleted_at = ?, updated_at = ? WHERE id = ? AND source = ?`)
    .bind(at, at, id, SOURCE_OURA)
    .run();
}
