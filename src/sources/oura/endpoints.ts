import type { OuraEndpoint } from "../../types.ts";

/**
 * Registry of Oura v2 usercollection endpoints.
 * heartrate is the only one that uses start_datetime/end_datetime.
 * Endpoints marked projectTo: "skipped" are documented omissions — do not
 * request their scopes until a projector exists (Oura returns empty arrays,
 * not errors, on missing scopes).
 */
export const OURA_ENDPOINTS: readonly OuraEndpoint[] = [
  {
    key: "personal_info",
    path: "personal_info",
    dateStyle: "none",
    scope: "personal",
    projectTo: "user_profile",
    maxDays: 0,
    webhook: false,
  },
  {
    key: "daily_sleep",
    path: "daily_sleep",
    dateStyle: "date",
    scope: "daily",
    projectTo: "daily_sleep",
    maxDays: 30,
    webhook: true,
  },
  {
    key: "daily_readiness",
    path: "daily_readiness",
    dateStyle: "date",
    scope: "daily",
    projectTo: "daily_readiness",
    maxDays: 30,
    webhook: true,
  },
  {
    key: "daily_activity",
    path: "daily_activity",
    dateStyle: "date",
    scope: "daily",
    projectTo: "daily_activity",
    maxDays: 30,
    webhook: true,
  },
  {
    key: "daily_stress",
    path: "daily_stress",
    dateStyle: "date",
    scope: "daily",
    projectTo: "daily_stress",
    maxDays: 30,
    webhook: true,
  },
  {
    key: "sleep",
    path: "sleep",
    dateStyle: "date",
    scope: "daily",
    projectTo: "sleep_periods",
    maxDays: 30,
    webhook: true,
  },
  {
    key: "workout",
    path: "workout",
    dateStyle: "date",
    scope: "workout",
    projectTo: "workouts",
    maxDays: 30,
    webhook: true,
  },
  {
    key: "session",
    path: "session",
    dateStyle: "date",
    scope: "session",
    projectTo: "sessions",
    maxDays: 30,
    webhook: true,
  },
  {
    key: "tag",
    path: "tag",
    dateStyle: "date",
    scope: "tag",
    projectTo: "tags",
    maxDays: 30,
    webhook: true,
  },
  {
    key: "heartrate",
    path: "heartrate",
    dateStyle: "datetime",
    scope: "heartrate",
    projectTo: "r2_only",
    maxDays: 7,
    webhook: false,
  },
  {
    key: "daily_spo2",
    path: "daily_spo2",
    dateStyle: "date",
    scope: "spo2Daily",
    projectTo: "skipped",
    maxDays: 30,
    webhook: false,
  },
  {
    key: "vo2_max",
    path: "vO2_max",
    dateStyle: "date",
    scope: "daily",
    projectTo: "skipped",
    maxDays: 30,
    webhook: false,
  },
  {
    key: "daily_cardiovascular_age",
    path: "daily_cardiovascular_age",
    dateStyle: "date",
    scope: "daily",
    projectTo: "skipped",
    maxDays: 30,
    webhook: false,
  },
  {
    key: "daily_resilience",
    path: "daily_resilience",
    dateStyle: "date",
    scope: "daily",
    projectTo: "skipped",
    maxDays: 30,
    webhook: false,
  },
];

export const ACTIVE_ENDPOINTS = OURA_ENDPOINTS.filter((e) => e.projectTo !== "skipped");

export const OAUTH_SCOPES = [
  "email",
  "personal",
  "daily",
  "heartrate",
  "workout",
  "session",
  "tag",
] as const;

export const WEBHOOK_DATA_TYPES = ACTIVE_ENDPOINTS.filter((e) => e.webhook).map((e) => e.key);

export const OURA_AUTHORIZE = "https://cloud.ouraring.com/oauth/authorize";
export const OURA_TOKEN = "https://api.ouraring.com/oauth/token";
export const OURA_API = "https://api.ouraring.com";

export function endpointByKey(key: string): OuraEndpoint | undefined {
  return OURA_ENDPOINTS.find((e) => e.key === key);
}

export function endpointByDataType(dataType: string): OuraEndpoint | undefined {
  return OURA_ENDPOINTS.find((e) => e.key === dataType || e.path === dataType);
}

/** Inclusive date windows aligned to UTC calendar days, deterministic on retry. */
export function chunkWindows(
  startDay: string,
  endDay: string,
  maxDays: number,
): Array<{ start: string; end: string }> {
  if (maxDays <= 0) return [{ start: startDay, end: endDay }];
  const out: Array<{ start: string; end: string }> = [];
  let cursor = parseUtcDay(startDay);
  const last = parseUtcDay(endDay);
  while (cursor <= last) {
    const chunkEnd = new Date(cursor);
    chunkEnd.setUTCDate(chunkEnd.getUTCDate() + maxDays - 1);
    const end = chunkEnd <= last ? chunkEnd : last;
    out.push({ start: formatUtcDay(cursor), end: formatUtcDay(end) });
    cursor = new Date(end);
    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }
  return out;
}

export function parseUtcDay(day: string): Date {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day);
  if (!m) throw new Error(`invalid day ${day}`);
  return new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
}

export function formatUtcDay(d: Date): string {
  return d.toISOString().slice(0, 10);
}

export function addUtcDays(day: string, n: number): string {
  const d = parseUtcDay(day);
  d.setUTCDate(d.getUTCDate() + n);
  return formatUtcDay(d);
}
