import {
  SOURCE_WHOOP,
  type DailyActivityRow,
  type DailyReadinessRow,
  type DailySleepRow,
  type DailyStrainRow,
  type Projected,
  type SleepPeriodRow,
  type WorkoutRow,
} from "../../types.ts";
import { calendarDayInZone, DEFAULT_TIME_ZONE, toUtcIso } from "../../lib/time.ts";

type Json = Record<string, unknown>;

const KJ_PER_KCAL = 4.184;
const HALF_DAY_MS = 12 * 3600 * 1000;

function rec(v: unknown): Json | null {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : null;
}

function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

function int(v: unknown): number | null {
  const n = num(v);
  return n == null ? null : Math.round(n);
}

function round(v: unknown, places: number): number | null {
  const n = num(v);
  if (n == null) return null;
  const f = 10 ** places;
  return Math.round(n * f) / f;
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

function idOf(v: unknown): string | null {
  if (typeof v === "string" && v.length > 0) return v;
  if (typeof v === "number" && Number.isFinite(v)) return String(v);
  return null;
}

function seconds(milli: unknown): number | null {
  const n = num(milli);
  return n == null ? null : Math.round(n / 1000);
}

function kcal(kilojoule: unknown): number | null {
  const n = num(kilojoule);
  return n == null ? null : Math.round(n / KJ_PER_KCAL);
}

/** WHOOP only scores some records. Anything else has no `score` worth reading. */
function scoreOf(doc: Json): Json | null {
  if (doc.score_state !== "SCORED") return null;
  return rec(doc.score);
}

/** "-05:00" → -300. Null when WHOOP sent something we do not recognise. */
export function whoopOffsetMinutes(offset: unknown): number | null {
  if (typeof offset !== "string") return null;
  if (offset === "Z") return 0;
  const m = /^([+-])(\d{2}):?(\d{2})$/.exec(offset.trim());
  if (!m) return null;
  return (m[1] === "-" ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3]));
}

/**
 * Calendar day of an instant as the wearer saw it: WHOOP's own
 * `timezone_offset` when present, else the profile time zone.
 */
export function whoopLocalDay(iso: string, offset: unknown, timeZone: string = DEFAULT_TIME_ZONE): string {
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) throw new Error(`unparseable timestamp: ${iso}`);
  const offsetMin = whoopOffsetMinutes(offset);
  if (offsetMin == null) return calendarDayInZone(new Date(ms).toISOString(), timeZone);
  return new Date(ms + offsetMin * 60_000).toISOString().slice(0, 10);
}

/** The morning a sleep ended on. This is the day its scores belong to. */
export function whoopSleepDay(doc: unknown, timeZone: string = DEFAULT_TIME_ZONE): string | null {
  const d = rec(doc);
  const end = str(d?.end);
  if (!d || !end) return null;
  return whoopLocalDay(end, d.timezone_offset, timeZone);
}

/**
 * A WHOOP cycle runs from one sleep to the next, so it starts the evening
 * before the day it describes. Its day is the middle of the cycle; a cycle
 * still in progress has no end, so use twelve hours after it began.
 */
export function whoopCycleDay(doc: unknown, timeZone: string = DEFAULT_TIME_ZONE): string | null {
  const d = rec(doc);
  const start = str(d?.start);
  if (!d || !start) return null;
  const a = Date.parse(start);
  if (Number.isNaN(a)) return null;
  const end = str(d.end);
  const b = end ? Date.parse(end) : NaN;
  const mid = Number.isNaN(b) ? a + HALF_DAY_MS : a + (b - a) / 2;
  return whoopLocalDay(new Date(mid).toISOString(), d.timezone_offset, timeZone);
}

/** Recovery records have no id of their own; the cycle is their identity. */
export function whoopDocumentId(collection: string, doc: unknown): string | null {
  const d = rec(doc);
  if (!d) return null;
  if (collection === "recovery") {
    const cycle = idOf(d.cycle_id);
    return cycle ? `cycle-${cycle}` : null;
  }
  return idOf(d.id);
}

/** Morning vitals from a recovery, written onto that morning's sleep row. */
export type SleepVitals = {
  kind: "sleep_vitals";
  day: string;
  /** HRV (RMSSD) in milliseconds. */
  avg_hrv: number | null;
  /** Resting heart rate, beats per minute. */
  lowest_hr: number | null;
  raw_id: number | null;
  updated_at: string;
};

export type WhoopProjected = Projected | SleepVitals;

export type WhoopContext = {
  /** Wake day by sleep id, so a recovery lands on the same morning as its sleep. */
  sleepDayById?: Map<string, string>;
  /** Wake day of the main sleep by cycle id. */
  sleepDayByCycleId?: Map<string, string>;
  timeZone?: string;
};

/** Index the sleeps of a batch so recoveries and cycles can share their day. */
export function buildWhoopContext(sleeps: unknown[], timeZone: string = DEFAULT_TIME_ZONE): Required<WhoopContext> {
  const sleepDayById = new Map<string, string>();
  const sleepDayByCycleId = new Map<string, string>();
  for (const doc of sleeps) {
    const d = rec(doc);
    const day = whoopSleepDay(doc, timeZone);
    const id = idOf(d?.id);
    if (!d || !day || !id) continue;
    sleepDayById.set(id, day);
    const cycle = idOf(d.cycle_id);
    if (cycle && d.nap !== true) sleepDayByCycleId.set(cycle, day);
  }
  return { sleepDayById, sleepDayByCycleId, timeZone };
}

/** Sleep → one `sleep_periods` row, plus the morning's `daily_sleep` when it is not a nap. */
export function projectWhoopSleep(doc: unknown, rawId: number | null, updatedAt: string, ctx: WhoopContext = {}): WhoopProjected[] {
  const d = rec(doc);
  const id = idOf(d?.id);
  const start = str(d?.start);
  const end = str(d?.end);
  if (!d || !id || !start || !end) return [{ kind: "skipped", endpoint: "sleep", reason: "missing id, start or end" }];
  const day = whoopLocalDay(end, d.timezone_offset, ctx.timeZone);
  const score = scoreOf(d);
  const stages = rec(score?.stage_summary);
  const light = seconds(stages?.total_light_sleep_time_milli);
  const deep = seconds(stages?.total_slow_wave_sleep_time_milli);
  const rem = seconds(stages?.total_rem_sleep_time_milli);
  const asleep = light == null && deep == null && rem == null ? null : (light ?? 0) + (deep ?? 0) + (rem ?? 0);
  const isNap = d.nap === true;
  const period: SleepPeriodRow = {
    id,
    source: SOURCE_WHOOP,
    day,
    source_day: day,
    start_utc: toUtcIso(start),
    end_utc: toUtcIso(end),
    tz_offset_min: whoopOffsetMinutes(d.timezone_offset) ?? 0,
    time_zone: null,
    period_type: isNap ? "nap" : "long_sleep",
    is_nap: isNap ? 1 : 0,
    total_sleep_s: asleep,
    deep_s: deep,
    rem_s: rem,
    light_s: light,
    awake_s: seconds(stages?.total_awake_time_milli),
    efficiency: int(score?.sleep_efficiency_percentage),
    avg_hrv: null,
    lowest_hr: null,
    respiratory_rate: round(score?.respiratory_rate, 2),
    raw_id: rawId,
    deleted_at: null,
    updated_at: updatedAt,
  };
  const out: WhoopProjected[] = [{ kind: "sleep_period", row: period }];
  if (isNap || !score) return out;
  const daily: DailySleepRow = {
    day,
    source: SOURCE_WHOOP,
    source_day: day,
    // WHOOP's 0–100 "sleep performance": sleep you got against sleep you needed.
    score: int(score.sleep_performance_percentage),
    total_sleep_s: asleep,
    time_in_bed_s: seconds(stages?.total_in_bed_time_milli),
    efficiency: int(score.sleep_efficiency_percentage),
    latency_s: null,
    deep_s: deep,
    rem_s: rem,
    light_s: light,
    awake_s: seconds(stages?.total_awake_time_milli),
    // HRV and resting heart rate arrive with the recovery (see SleepVitals).
    avg_hrv: null,
    avg_hr: null,
    lowest_hr: null,
    respiratory_rate: round(score.respiratory_rate, 2),
    contributors_json: JSON.stringify({
      sleep_consistency_percentage: num(score.sleep_consistency_percentage),
      sleep_cycle_count: num(stages?.sleep_cycle_count),
      disturbance_count: num(stages?.disturbance_count),
    }),
    raw_id: rawId,
    deleted_at: null,
    updated_at: updatedAt,
  };
  out.push({ kind: "daily_sleep", row: daily });
  return out;
}

/**
 * Recovery → the morning's 0–100 score in `daily_readiness`, plus HRV and
 * resting heart rate for that morning's sleep row.
 */
export function projectWhoopRecovery(doc: unknown, rawId: number | null, updatedAt: string, ctx: WhoopContext = {}): WhoopProjected[] {
  const d = rec(doc);
  if (!d) return [{ kind: "skipped", endpoint: "recovery", reason: "not an object" }];
  const score = scoreOf(d);
  if (!score) return [{ kind: "skipped", endpoint: "recovery", reason: "not scored yet" }];
  const sleepId = idOf(d.sleep_id);
  const cycleId = idOf(d.cycle_id);
  const created = str(d.created_at);
  const day =
    (sleepId ? ctx.sleepDayById?.get(sleepId) : undefined) ??
    (cycleId ? ctx.sleepDayByCycleId?.get(cycleId) : undefined) ??
    (created ? whoopLocalDay(created, null, ctx.timeZone) : null);
  if (!day) return [{ kind: "skipped", endpoint: "recovery", reason: "no day" }];
  const hrv = round(score.hrv_rmssd_milli, 1);
  const resting = round(score.resting_heart_rate, 1);
  const readiness: DailyReadinessRow = {
    day,
    source: SOURCE_WHOOP,
    source_day: day,
    score: int(score.recovery_score),
    temperature_deviation: null,
    contributors_json: JSON.stringify({
      hrv_rmssd_milli: hrv,
      resting_heart_rate: resting,
      spo2_percentage: num(score.spo2_percentage),
      skin_temp_celsius: num(score.skin_temp_celsius),
      user_calibrating: score.user_calibrating === true,
    }),
    raw_id: rawId,
    deleted_at: null,
    updated_at: updatedAt,
  };
  return [
    { kind: "daily_readiness", row: readiness },
    { kind: "sleep_vitals", day, avg_hrv: hrv, lowest_hr: resting, raw_id: rawId, updated_at: updatedAt },
  ];
}

/** Cycle → the day's strain and average / max heart rate, plus steps and energy. */
export function projectWhoopCycle(doc: unknown, rawId: number | null, updatedAt: string, ctx: WhoopContext = {}): WhoopProjected[] {
  const d = rec(doc);
  const id = idOf(d?.id);
  if (!d || !id) return [{ kind: "skipped", endpoint: "cycle", reason: "missing id" }];
  const day = ctx.sleepDayByCycleId?.get(id) ?? whoopCycleDay(d, ctx.timeZone);
  if (!day) return [{ kind: "skipped", endpoint: "cycle", reason: "no day" }];
  const score = scoreOf(d);
  const out: WhoopProjected[] = [];
  if (score) {
    const strain: DailyStrainRow = {
      day,
      source: SOURCE_WHOOP,
      source_day: day,
      strain: round(score.strain, 1),
      avg_hr: int(score.average_heart_rate),
      max_hr: int(score.max_heart_rate),
      kilojoule: round(score.kilojoule, 1),
      raw_id: rawId,
      deleted_at: null,
      updated_at: updatedAt,
    };
    out.push({ kind: "daily_strain", row: strain });
  }
  const steps = int(d.step_count);
  const totalCal = kcal(score?.kilojoule);
  if (steps != null || totalCal != null) {
    const activity: DailyActivityRow = {
      day,
      source: SOURCE_WHOOP,
      source_day: day,
      score: null,
      steps,
      active_cal: null,
      total_cal: totalCal,
      met_minutes: null,
      class_5_min: null,
      raw_id: rawId,
      deleted_at: null,
      updated_at: updatedAt,
    };
    out.push({ kind: "daily_activity", row: activity });
  }
  if (!out.length) return [{ kind: "skipped", endpoint: "cycle", reason: "not scored yet" }];
  return out;
}

export function projectWhoopWorkout(doc: unknown, rawId: number | null, updatedAt: string, ctx: WhoopContext = {}): WhoopProjected[] {
  const d = rec(doc);
  const id = idOf(d?.id);
  const start = str(d?.start);
  const end = str(d?.end);
  if (!d || !id || !start || !end) return [{ kind: "skipped", endpoint: "workout", reason: "missing id, start or end" }];
  const score = scoreOf(d);
  const day = whoopLocalDay(start, d.timezone_offset, ctx.timeZone);
  const row: WorkoutRow = {
    id,
    source: SOURCE_WHOOP,
    day,
    source_day: day,
    start_utc: toUtcIso(start),
    end_utc: toUtcIso(end),
    activity: str(d.sport_name),
    intensity: null,
    strain: round(score?.strain, 1),
    calories: kcal(score?.kilojoule),
    avg_hr: int(score?.average_heart_rate),
    max_hr: int(score?.max_heart_rate),
    raw_id: rawId,
    deleted_at: null,
    updated_at: updatedAt,
  };
  return [{ kind: "workout", row }];
}

export function projectWhoopDocument(
  collection: string,
  doc: unknown,
  rawId: number | null,
  updatedAt: string,
  ctx: WhoopContext = {},
): WhoopProjected[] {
  switch (collection) {
    case "sleep":
      return projectWhoopSleep(doc, rawId, updatedAt, ctx);
    case "recovery":
      return projectWhoopRecovery(doc, rawId, updatedAt, ctx);
    case "cycle":
      return projectWhoopCycle(doc, rawId, updatedAt, ctx);
    case "workout":
      return projectWhoopWorkout(doc, rawId, updatedAt, ctx);
    default:
      return [{ kind: "skipped", endpoint: collection, reason: "unknown collection" }];
  }
}
