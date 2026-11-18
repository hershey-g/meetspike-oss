import { SOURCE_OURA, type Projected } from "../../types.ts";
import { calendarDayInZone, offsetMinutesFromIso, toUtcIso } from "../../lib/time.ts";
import { endpointByKey } from "./endpoints.ts";

type Json = Record<string, unknown>;

function asRecord(doc: unknown): Json {
  if (!doc || typeof doc !== "object") throw new Error("document is not an object");
  return doc as Json;
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

function num(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v))) return Number(v);
  return null;
}

function int(v: unknown): number | null {
  const n = num(v);
  return n === null ? null : Math.round(n);
}

function jsonText(v: unknown): string | null {
  if (v === null || v === undefined) return null;
  return JSON.stringify(v);
}

function requireId(doc: Json, fallback?: string): string {
  const id = str(doc.id) ?? fallback;
  if (!id) throw new Error("document missing id");
  return id;
}

function requireDay(doc: Json): string {
  const day = str(doc.day);
  if (!day) throw new Error("document missing day");
  return day;
}

/**
 * Project one Oura document into zero or more D1 rows.
 * Heart-rate samples are archive-only (R2) — they are not written to D1.
 */
export function projectDocument(
  endpointKey: string,
  doc: unknown,
  rawId: number | null,
  updatedAt: string,
  timeZone = "America/New_York",
): Projected[] {
  const spec = endpointByKey(endpointKey);
  if (!spec) return [{ kind: "skipped", endpoint: endpointKey, reason: "unknown endpoint" }];
  if (spec.projectTo === "skipped") {
    return [{ kind: "skipped", endpoint: endpointKey, reason: "endpoint deferred" }];
  }
  if (spec.projectTo === "r2_only") {
    const rec = asRecord(doc);
    return [
      {
        kind: "archive_only",
        endpoint: endpointKey,
        documentId: str(rec.id) ?? `${endpointKey}:${str(rec.timestamp) ?? "batch"}`,
        extra: { sampleCount: Array.isArray(rec.data) ? rec.data.length : undefined },
      },
    ];
  }

  const rec = asRecord(doc);

  switch (spec.projectTo) {
    case "user_profile":
      return [
        {
          kind: "user_profile",
          row: {
            id: "self",
            time_zone: str(rec.timezone) ?? timeZone,
            oura_user_id: str(rec.id),
            personal_json: jsonText(rec),
            updated_at: updatedAt,
          },
        },
      ];
    case "daily_sleep":
      return [projectDailySleep(rec, rawId, updatedAt)];
    case "daily_readiness":
      return [projectDailyReadiness(rec, rawId, updatedAt)];
    case "daily_activity":
      return [projectDailyActivity(rec, rawId, updatedAt)];
    case "daily_stress":
      return [projectDailyStress(rec, rawId, updatedAt)];
    case "sleep_periods":
      return [projectSleepPeriod(rec, rawId, updatedAt, timeZone)];
    case "workouts":
      return [projectWorkout(rec, rawId, updatedAt)];
    case "sessions":
      return [projectSession(rec, rawId, updatedAt)];
    case "tags":
      return [projectTag(rec, rawId, updatedAt)];
    default:
      return [{ kind: "skipped", endpoint: endpointKey, reason: "unhandled projector" }];
  }
}

function projectDailySleep(doc: Json, rawId: number | null, updatedAt: string): Projected {
  const day = requireDay(doc);
  return {
    kind: "daily_sleep",
    row: {
      day,
      source: SOURCE_OURA,
      source_day: day,
      score: int(doc.score),
      total_sleep_s: null,
      time_in_bed_s: null,
      efficiency: null,
      latency_s: null,
      deep_s: null,
      rem_s: null,
      light_s: null,
      awake_s: null,
      avg_hrv: null,
      avg_hr: null,
      lowest_hr: null,
      respiratory_rate: null,
      contributors_json: jsonText(doc.contributors),
      raw_id: rawId,
      deleted_at: null,
      updated_at: updatedAt,
    },
  };
}

function projectDailyReadiness(doc: Json, rawId: number | null, updatedAt: string): Projected {
  const day = requireDay(doc);
  return {
    kind: "daily_readiness",
    row: {
      day,
      source: SOURCE_OURA,
      source_day: day,
      score: int(doc.score),
      temperature_deviation: num(doc.temperature_deviation),
      contributors_json: jsonText(doc.contributors),
      raw_id: rawId,
      deleted_at: null,
      updated_at: updatedAt,
    },
  };
}

function projectDailyActivity(doc: Json, rawId: number | null, updatedAt: string): Projected {
  const day = requireDay(doc);
  return {
    kind: "daily_activity",
    row: {
      day,
      source: SOURCE_OURA,
      source_day: day,
      score: int(doc.score),
      steps: int(doc.steps),
      active_cal: int(doc.active_calories),
      total_cal: int(doc.total_calories),
      met_minutes: num(doc.average_met_minutes),
      class_5_min: str(doc.class_5_min),
      raw_id: rawId,
      deleted_at: null,
      updated_at: updatedAt,
    },
  };
}

function projectDailyStress(doc: Json, rawId: number | null, updatedAt: string): Projected {
  const day = requireDay(doc);
  return {
    kind: "daily_stress",
    row: {
      day,
      source: SOURCE_OURA,
      source_day: day,
      stress_high_s: int(doc.stress_high),
      recovery_high_s: int(doc.recovery_high),
      day_summary: str(doc.day_summary),
      raw_id: rawId,
      deleted_at: null,
      updated_at: updatedAt,
    },
  };
}

function projectSleepPeriod(
  doc: Json,
  rawId: number | null,
  updatedAt: string,
  timeZone: string,
): Projected {
  const id = requireId(doc);
  const startRaw = str(doc.bedtime_start) ?? str(doc.start_datetime);
  const endRaw = str(doc.bedtime_end) ?? str(doc.end_datetime);
  if (!startRaw || !endRaw) throw new Error(`sleep ${id} missing bedtime`);
  const startUtc = toUtcIso(startRaw);
  const endUtc = toUtcIso(endRaw);
  const sourceDay = str(doc.day);
  const periodType = str(doc.type);
  const isNap = periodType !== "long_sleep" && periodType !== "rest" ? 1 : 0;
  const day = sourceDay ?? calendarDayInZone(endUtc, timeZone);
  return {
    kind: "sleep_period",
    row: {
      id,
      source: SOURCE_OURA,
      day,
      source_day: sourceDay,
      start_utc: startUtc,
      end_utc: endUtc,
      tz_offset_min: offsetMinutesFromIso(startRaw),
      time_zone: timeZone,
      period_type: periodType,
      is_nap: isNap,
      total_sleep_s: int(doc.total_sleep_duration),
      deep_s: int(doc.deep_sleep_duration),
      rem_s: int(doc.rem_sleep_duration),
      light_s: int(doc.light_sleep_duration),
      awake_s: int(doc.awake_time),
      efficiency: int(doc.efficiency),
      avg_hrv: num(doc.average_hrv),
      lowest_hr: num(doc.lowest_heart_rate),
      respiratory_rate: num(doc.average_breath),
      raw_id: rawId,
      deleted_at: null,
      updated_at: updatedAt,
    },
  };
}

function projectWorkout(doc: Json, rawId: number | null, updatedAt: string): Projected {
  const id = requireId(doc);
  const startRaw = str(doc.start_datetime);
  const endRaw = str(doc.end_datetime);
  if (!startRaw || !endRaw) throw new Error(`workout ${id} missing datetimes`);
  const day = str(doc.day) ?? toUtcIso(startRaw).slice(0, 10);
  return {
    kind: "workout",
    row: {
      id,
      source: SOURCE_OURA,
      day,
      source_day: str(doc.day),
      start_utc: toUtcIso(startRaw),
      end_utc: toUtcIso(endRaw),
      activity: str(doc.activity),
      intensity: str(doc.intensity),
      strain: null,
      calories: int(doc.calories),
      avg_hr: int(doc.average_heart_rate),
      max_hr: int(doc.max_heart_rate),
      raw_id: rawId,
      deleted_at: null,
      updated_at: updatedAt,
    },
  };
}

function projectSession(doc: Json, rawId: number | null, updatedAt: string): Projected {
  const id = requireId(doc);
  const startRaw = str(doc.start_datetime);
  const endRaw = str(doc.end_datetime);
  if (!startRaw || !endRaw) throw new Error(`session ${id} missing datetimes`);
  return {
    kind: "session",
    row: {
      id,
      source: SOURCE_OURA,
      start_utc: toUtcIso(startRaw),
      end_utc: toUtcIso(endRaw),
      type: str(doc.type),
      mood: str(doc.mood),
      raw_id: rawId,
      deleted_at: null,
      updated_at: updatedAt,
    },
  };
}

function projectTag(doc: Json, rawId: number | null, updatedAt: string): Projected {
  const id = requireId(doc);
  const day = str(doc.day) ?? (str(doc.timestamp) ? toUtcIso(str(doc.timestamp)!) .slice(0, 10) : "unknown");
  const tags = Array.isArray(doc.tags) ? (doc.tags as unknown[]).map(String).join(",") : str(doc.tag_type_code);
  return {
    kind: "tag",
    row: {
      id,
      source: SOURCE_OURA,
      day,
      tag_code: tags,
      comment: str(doc.comment) ?? str(doc.text),
      answered_yes: null,
      raw_id: rawId,
      deleted_at: null,
      updated_at: updatedAt,
    },
  };
}

/**
 * Merge period-level physiology onto the daily_sleep row for the same day
 * (Oura's daily_sleep document is score + contributors only).
 */
export function enrichDailySleepFromPeriod(
  daily: Extract<Projected, { kind: "daily_sleep" }>["row"],
  period: Extract<Projected, { kind: "sleep_period" }>["row"],
): Extract<Projected, { kind: "daily_sleep" }>["row"] {
  if (period.is_nap) return daily;
  return {
    ...daily,
    total_sleep_s: period.total_sleep_s ?? daily.total_sleep_s,
    time_in_bed_s: period.total_sleep_s != null && period.awake_s != null
      ? period.total_sleep_s + period.awake_s
      : daily.time_in_bed_s,
    efficiency: period.efficiency ?? daily.efficiency,
    deep_s: period.deep_s ?? daily.deep_s,
    rem_s: period.rem_s ?? daily.rem_s,
    light_s: period.light_s ?? daily.light_s,
    awake_s: period.awake_s ?? daily.awake_s,
    avg_hrv: period.avg_hrv ?? daily.avg_hrv,
    lowest_hr: period.lowest_hr ?? daily.lowest_hr,
    respiratory_rate: period.respiratory_rate ?? daily.respiratory_rate,
  };
}
