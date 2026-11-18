import { SOURCE_OURA, type WearableSource } from "../types.ts";
import { addCalendarDays } from "./time.ts";

export const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
export const METRICS_MAX_SPAN_DAYS = 90;

export type SleepMetricIn = {
  day: string;
  score: number | null;
  avg_hrv: number | null;
  lowest_hr: number | null;
  total_sleep_s: number | null;
};

export type ReadinessMetricIn = {
  day: string;
  score: number | null;
};

export type ActivityMetricIn = {
  day: string;
  score: number | null;
  steps: number | null;
};

export type StressMetricIn = {
  day: string;
  stress_high_s: number | null;
  recovery_high_s: number | null;
  day_summary: string | null;
};

export type DailyMetricPoint = {
  day: string;
  sleepScore: number | null;
  readinessScore: number | null;
  activityScore: number | null;
  steps: number | null;
  stressHighS: number | null;
  recoveryHighS: number | null;
  stressSummary: string | null;
  avgHrv: number | null;
  lowestHr: number | null;
  totalSleepS: number | null;
  /** Whole-day exertion, only present for wearables that report it. */
  strain?: number | null;
};

export type StrainMetricIn = {
  day: string;
  strain: number | null;
};

export function inclusiveDayCount(start: string, end: string): number {
  const a = Date.parse(`${start}T00:00:00.000Z`);
  const b = Date.parse(`${end}T00:00:00.000Z`);
  if (Number.isNaN(a) || Number.isNaN(b)) return 0;
  return Math.round((b - a) / 86_400_000) + 1;
}

export function parseDayRange(
  start: string | undefined,
  end: string | undefined,
  today: string,
): { start: string; end: string } | { error: string } {
  if (end != null && end !== "" && !DAY_RE.test(end)) return { error: "end must be YYYY-MM-DD" };
  if (start != null && start !== "" && !DAY_RE.test(start)) return { error: "start must be YYYY-MM-DD" };
  const resolvedEnd = end && DAY_RE.test(end) ? end : today;
  const resolvedStart = start && DAY_RE.test(start) ? start : addCalendarDays(resolvedEnd, -29);
  if (resolvedStart > resolvedEnd) return { error: "start must be on or before end" };
  if (inclusiveDayCount(resolvedStart, resolvedEnd) > METRICS_MAX_SPAN_DAYS) {
    return { error: `range cannot exceed ${METRICS_MAX_SPAN_DAYS} days` };
  }
  return { start: resolvedStart, end: resolvedEnd };
}

function indexByDay<T extends { day: string }>(rows: T[]): Map<string, T> {
  return new Map(rows.map((r) => [r.day, r]));
}

/** Merge per-table daily rows onto a continuous [start, end] series. Nulls stay null. */
export function mergeDailyMetrics(opts: {
  start: string;
  end: string;
  sleep?: SleepMetricIn[];
  readiness?: ReadinessMetricIn[];
  activity?: ActivityMetricIn[];
  stress?: StressMetricIn[];
  /** Omit for wearables without day strain; the points then carry no `strain` key. */
  strain?: StrainMetricIn[];
}): DailyMetricPoint[] {
  const sleepBy = indexByDay(opts.sleep ?? []);
  const readyBy = indexByDay(opts.readiness ?? []);
  const activityBy = indexByDay(opts.activity ?? []);
  const stressBy = indexByDay(opts.stress ?? []);
  const strainBy = opts.strain ? indexByDay(opts.strain) : null;
  const out: DailyMetricPoint[] = [];
  for (let day = opts.start; day <= opts.end; day = addCalendarDays(day, 1)) {
    const s = sleepBy.get(day);
    const r = readyBy.get(day);
    const a = activityBy.get(day);
    const t = stressBy.get(day);
    out.push({
      day,
      sleepScore: s?.score ?? null,
      readinessScore: r?.score ?? null,
      activityScore: a?.score ?? null,
      steps: a?.steps ?? null,
      stressHighS: t?.stress_high_s ?? null,
      recoveryHighS: t?.recovery_high_s ?? null,
      stressSummary: t?.day_summary ?? null,
      avgHrv: s?.avg_hrv ?? null,
      lowestHr: s?.lowest_hr ?? null,
      totalSleepS: s?.total_sleep_s ?? null,
      ...(strainBy ? { strain: strainBy.get(day)?.strain ?? null } : {}),
    });
  }
  return out;
}

export async function queryDailyMetrics(
  db: D1Database,
  start: string,
  end: string,
  source: WearableSource = SOURCE_OURA,
  opts: { strain?: boolean } = {},
): Promise<DailyMetricPoint[]> {
  const strainRows = opts.strain
    ? db
        .prepare(
          `SELECT day, strain FROM daily_strain
           WHERE source = ? AND day >= ? AND day <= ? AND deleted_at IS NULL`,
        )
        .bind(source, start, end)
        .all<StrainMetricIn>()
        .then((r) => r.results ?? [])
        // Table arrives with migration 0008; without it there is simply no strain.
        .catch(() => [] as StrainMetricIn[])
    : Promise.resolve(undefined);
  const [sleep, readiness, activity, stress, strain] = await Promise.all([
    db
      .prepare(
        `SELECT day, score, avg_hrv, lowest_hr, total_sleep_s
         FROM daily_sleep WHERE source = ? AND day >= ? AND day <= ? AND deleted_at IS NULL`,
      )
      .bind(source, start, end)
      .all<SleepMetricIn>(),
    db
      .prepare(
        `SELECT day, score FROM daily_readiness
         WHERE source = ? AND day >= ? AND day <= ? AND deleted_at IS NULL`,
      )
      .bind(source, start, end)
      .all<ReadinessMetricIn>(),
    db
      .prepare(
        `SELECT day, score, steps FROM daily_activity
         WHERE source = ? AND day >= ? AND day <= ? AND deleted_at IS NULL`,
      )
      .bind(source, start, end)
      .all<ActivityMetricIn>(),
    db
      .prepare(
        `SELECT day, stress_high_s, recovery_high_s, day_summary FROM daily_stress
         WHERE source = ? AND day >= ? AND day <= ? AND deleted_at IS NULL`,
      )
      .bind(source, start, end)
      .all<StressMetricIn>(),
    strainRows,
  ]);
  return mergeDailyMetrics({
    start,
    end,
    sleep: sleep.results ?? [],
    readiness: readiness.results ?? [],
    activity: activity.results ?? [],
    stress: stress.results ?? [],
    strain,
  });
}
