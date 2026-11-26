import type { ResolvedOverride } from "./lib/meeting-override.ts";

export const SOURCE_OURA = "oura" as const;
export const SOURCE_WHOOP = "whoop" as const;
/** A wearable that writes daily / sleep / workout rows. Every such row carries its source. */
export type WearableSource = typeof SOURCE_OURA | typeof SOURCE_WHOOP;
export const SOURCE_GOOGLE = "google" as const;
export const SOURCE_SANDBOX_CAL = "sandbox" as const;
export const SOURCE_PLAUD = "plaud" as const;

export type OuraDateStyle = "date" | "datetime" | "none";

export type OuraEndpointKey =
  | "personal_info"
  | "daily_sleep"
  | "daily_readiness"
  | "daily_activity"
  | "daily_stress"
  | "sleep"
  | "workout"
  | "session"
  | "tag"
  | "heartrate"
  | "daily_spo2"
  | "vo2_max"
  | "daily_cardiovascular_age"
  | "daily_resilience";

export type OuraEndpoint = {
  key: OuraEndpointKey;
  path: string;
  dateStyle: OuraDateStyle;
  scope: string;
  projectTo:
    | "user_profile"
    | "daily_sleep"
    | "daily_readiness"
    | "daily_activity"
    | "daily_stress"
    | "sleep_periods"
    | "workouts"
    | "sessions"
    | "tags"
    | "r2_only"
    | "skipped";
  /** Max inclusive-day span per backfill step. */
  maxDays: number;
  webhook: boolean;
};

export type TokenBundle = {
  access_token: string;
  refresh_token?: string;
  expires_at: string;
  scope?: string;
};

export type IngestQueueMessage = {
  event_id?: string;
  data_type: string;
  object_id: string;
  event_type: "create" | "update" | "delete";
  event_time?: string;
};

export type DailySleepRow = {
  day: string;
  source: WearableSource;
  source_day: string | null;
  score: number | null;
  total_sleep_s: number | null;
  time_in_bed_s: number | null;
  efficiency: number | null;
  latency_s: number | null;
  deep_s: number | null;
  rem_s: number | null;
  light_s: number | null;
  awake_s: number | null;
  avg_hrv: number | null;
  avg_hr: number | null;
  lowest_hr: number | null;
  respiratory_rate: number | null;
  contributors_json: string | null;
  raw_id: number | null;
  deleted_at: string | null;
  updated_at: string;
};

export type DailyReadinessRow = {
  day: string;
  source: WearableSource;
  source_day: string | null;
  score: number | null;
  temperature_deviation: number | null;
  contributors_json: string | null;
  raw_id: number | null;
  deleted_at: string | null;
  updated_at: string;
};

export type DailyActivityRow = {
  day: string;
  source: WearableSource;
  source_day: string | null;
  score: number | null;
  steps: number | null;
  active_cal: number | null;
  total_cal: number | null;
  met_minutes: number | null;
  class_5_min: string | null;
  raw_id: number | null;
  deleted_at: string | null;
  updated_at: string;
};

export type DailyStressRow = {
  day: string;
  source: WearableSource;
  source_day: string | null;
  stress_high_s: number | null;
  recovery_high_s: number | null;
  day_summary: string | null;
  raw_id: number | null;
  deleted_at: string | null;
  updated_at: string;
};

/**
 * Whole-day exertion for wearables that report it (WHOOP day strain, 0–21).
 * Kept in its own table (migration 0008) so sources without it are untouched.
 */
export type DailyStrainRow = {
  day: string;
  source: WearableSource;
  source_day: string | null;
  strain: number | null;
  avg_hr: number | null;
  max_hr: number | null;
  kilojoule: number | null;
  raw_id: number | null;
  deleted_at: string | null;
  updated_at: string;
};

export type SleepPeriodRow = {
  id: string;
  source: WearableSource;
  day: string;
  source_day: string | null;
  start_utc: string;
  end_utc: string;
  tz_offset_min: number;
  time_zone: string | null;
  period_type: string | null;
  is_nap: number;
  total_sleep_s: number | null;
  deep_s: number | null;
  rem_s: number | null;
  light_s: number | null;
  awake_s: number | null;
  efficiency: number | null;
  avg_hrv: number | null;
  lowest_hr: number | null;
  respiratory_rate: number | null;
  raw_id: number | null;
  deleted_at: string | null;
  updated_at: string;
};

export type WorkoutRow = {
  id: string;
  source: WearableSource;
  day: string;
  source_day: string | null;
  start_utc: string;
  end_utc: string;
  activity: string | null;
  intensity: string | null;
  strain: number | null;
  calories: number | null;
  avg_hr: number | null;
  max_hr: number | null;
  raw_id: number | null;
  deleted_at: string | null;
  updated_at: string;
};

export type SessionRow = {
  id: string;
  source: WearableSource;
  start_utc: string;
  end_utc: string;
  type: string | null;
  mood: string | null;
  raw_id: number | null;
  deleted_at: string | null;
  updated_at: string;
};

export type TagRow = {
  id: string;
  source: WearableSource;
  day: string;
  tag_code: string | null;
  comment: string | null;
  answered_yes: number | null;
  raw_id: number | null;
  deleted_at: string | null;
  updated_at: string;
};

export type UserProfileRow = {
  id: "self";
  time_zone: string;
  oura_user_id: string | null;
  personal_json: string | null;
  updated_at: string;
};

export type CalendarEventRow = {
  id: string;
  source: typeof SOURCE_GOOGLE | typeof SOURCE_SANDBOX_CAL | typeof SOURCE_PLAUD;
  day: string;
  start_utc: string;
  end_utc: string;
  start_local: string | null;
  end_local: string | null;
  tz_offset_min: number;
  duration_s: number;
  title: string | null;
  kind: string;
  client_key: string | null;
  project_key: string | null;
  attendee_count: number | null;
  attendees_json: string | null;
  after_hours: number;
  location: string | null;
  raw_id: number | null;
  deleted_at: string | null;
  updated_at: string;
  source_type?: string;
  plaud_file_id?: string | null;
  sync_reason?: string | null;
  has_transcript?: number | null;
  synced_at?: string | null;
  /** The owner's choices for this meeting (src/lib/meeting-override.ts), set by the loaders. Not a column. */
  override?: ResolvedOverride;
};

export type Projected =
  | { kind: "daily_sleep"; row: DailySleepRow }
  | { kind: "daily_readiness"; row: DailyReadinessRow }
  | { kind: "daily_activity"; row: DailyActivityRow }
  | { kind: "daily_stress"; row: DailyStressRow }
  | { kind: "daily_strain"; row: DailyStrainRow }
  | { kind: "sleep_period"; row: SleepPeriodRow }
  | { kind: "workout"; row: WorkoutRow }
  | { kind: "session"; row: SessionRow }
  | { kind: "tag"; row: TagRow }
  | { kind: "user_profile"; row: UserProfileRow }
  | { kind: "archive_only"; endpoint: string; documentId: string; extra?: Record<string, unknown> }
  | { kind: "skipped"; endpoint: string; reason: string };
