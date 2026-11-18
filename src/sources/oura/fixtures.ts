import { addUtcDays, formatUtcDay } from "./endpoints.ts";

type Json = Record<string, unknown>;

function mulberry32(seed: number) {
  return function next() {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function seedFromDay(day: string): number {
  let h = 2166136261;
  for (let i = 0; i < day.length; i++) {
    h ^= day.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

function lerp(rng: () => number, a: number, b: number) {
  return a + (b - a) * rng();
}

function round(n: number, digits = 0) {
  const p = 10 ** digits;
  return Math.round(n * p) / p;
}

function offsetIso(day: string, hour: number, minute: number, offset = "-04:00"): string {
  const hh = String(Math.floor(hour)).padStart(2, "0");
  const mm = String(minute).padStart(2, "0");
  return `${day}T${hh}:${mm}:00${offset}`;
}

export type FixtureBundle = {
  personal_info: Json;
  daily_sleep: Json[];
  daily_readiness: Json[];
  daily_activity: Json[];
  daily_stress: Json[];
  sleep: Json[];
  workout: Json[];
  session: Json[];
  tag: Json[];
  heartrate: Json[];
};

export function makeSandboxFixtures(days = 21, endDay?: string): FixtureBundle {
  const end = endDay ?? formatUtcDay(new Date());
  const start = addUtcDays(end, -(days - 1));
  const bundle: FixtureBundle = {
    personal_info: {
      id: "sandbox-user",
      age: 42,
      weight: 82.5,
      height: 178,
      biological_sex: "male",
      email: "sandbox@example.test",
      timezone: "America/New_York",
    },
    daily_sleep: [],
    daily_readiness: [],
    daily_activity: [],
    daily_stress: [],
    sleep: [],
    workout: [],
    session: [],
    tag: [],
    heartrate: [],
  };

  for (let i = 0; i < days; i++) {
    const day = addUtcDays(start, i);
    const rng = mulberry32(seedFromDay(day));
    const weekend = [0, 6].includes(new Date(`${day}T12:00:00Z`).getUTCDay());

    const totalSleep = Math.round(lerp(rng, weekend ? 25000 : 22000, weekend ? 31000 : 28000));
    const deep = Math.round(totalSleep * lerp(rng, 0.14, 0.22));
    const rem = Math.round(totalSleep * lerp(rng, 0.18, 0.26));
    const awake = Math.round(lerp(rng, 1200, 3200));
    const light = totalSleep - deep - rem;
    const efficiency = Math.round(((totalSleep - awake * 0.3) / (totalSleep + awake)) * 100);
    const scoreSleep = Math.round(lerp(rng, 62, 94));
    const scoreReady = Math.round(lerp(rng, 54, 92));
    const scoreAct = Math.round(lerp(rng, 60, 96));
    const lowestHr = round(lerp(rng, 46, 56), 1);
    const avgHrv = round(lerp(rng, 28, 62), 1);
    const tempDev = round(lerp(rng, -0.4, 0.35), 2);

    const prev = addUtcDays(day, -1);
    const bedStart = offsetIso(prev, 22, Math.round(lerp(rng, 10, 55)));
    const bedEndHour = lerp(rng, 6.2, 7.6);
    const bedEnd = offsetIso(day, Math.floor(bedEndHour), Math.round((bedEndHour % 1) * 60));

    bundle.daily_sleep.push({
      id: `ds-${day}`,
      day,
      score: scoreSleep,
      timestamp: `${day}T00:00:00+00:00`,
      contributors: {
        deep_sleep: Math.round(lerp(rng, 60, 95)),
        efficiency: Math.round(lerp(rng, 70, 96)),
        latency: Math.round(lerp(rng, 55, 90)),
        rem_sleep: Math.round(lerp(rng, 60, 92)),
        restfulness: Math.round(lerp(rng, 50, 88)),
        timing: Math.round(lerp(rng, 70, 95)),
        total_sleep: Math.round(lerp(rng, 60, 93)),
      },
    });

    bundle.daily_readiness.push({
      id: `dr-${day}`,
      day,
      score: scoreReady,
      temperature_deviation: tempDev,
      timestamp: `${day}T00:00:00+00:00`,
      contributors: {
        activity_balance: Math.round(lerp(rng, 60, 95)),
        body_temperature: Math.round(lerp(rng, 70, 98)),
        hrv_balance: Math.round(lerp(rng, 50, 90)),
        previous_day_activity: Math.round(lerp(rng, 60, 94)),
        previous_night: Math.round(lerp(rng, 55, 92)),
        recovery_index: Math.round(lerp(rng, 65, 96)),
        resting_heart_rate: Math.round(lerp(rng, 60, 95)),
        sleep_balance: Math.round(lerp(rng, 55, 90)),
      },
    });

    const steps = Math.round(lerp(rng, weekend ? 4000 : 7000, weekend ? 14000 : 16000));
    bundle.daily_activity.push({
      id: `da-${day}`,
      day,
      score: scoreAct,
      steps,
      active_calories: Math.round(lerp(rng, 280, 720)),
      total_calories: Math.round(lerp(rng, 2100, 3100)),
      average_met_minutes: round(lerp(rng, 1.2, 1.9), 2),
      class_5_min: "0".repeat(288),
      timestamp: `${day}T00:00:00+00:00`,
      contributors: {
        meet_daily_targets: Math.round(lerp(rng, 50, 100)),
        move_every_hour: Math.round(lerp(rng, 60, 100)),
        recovery_time: Math.round(lerp(rng, 50, 90)),
        stay_active: Math.round(lerp(rng, 55, 95)),
        training_frequency: Math.round(lerp(rng, 40, 90)),
        training_volume: Math.round(lerp(rng, 40, 90)),
      },
    });

    bundle.daily_stress.push({
      id: `dst-${day}`,
      day,
      stress_high: Math.round(lerp(rng, 1800, 9800)),
      recovery_high: Math.round(lerp(rng, 4000, 16000)),
      day_summary: rng() > 0.6 ? "restorative" : rng() > 0.3 ? "normal" : "stressful",
    });

    bundle.sleep.push({
      id: `sp-${day}`,
      day,
      type: "long_sleep",
      bedtime_start: bedStart,
      bedtime_end: bedEnd,
      total_sleep_duration: totalSleep,
      deep_sleep_duration: deep,
      rem_sleep_duration: rem,
      light_sleep_duration: light,
      awake_time: awake,
      time_in_bed: totalSleep + awake,
      efficiency,
      latency: Math.round(lerp(rng, 240, 1400)),
      average_hrv: avgHrv,
      average_heart_rate: round(lowestHr + lerp(rng, 6, 12), 1),
      lowest_heart_rate: lowestHr,
      average_breath: round(lerp(rng, 13.4, 16.2), 1),
    });

    if (rng() > 0.72) {
      const napStart = offsetIso(day, 14, Math.round(lerp(rng, 0, 40)));
      const napEnd = offsetIso(day, 14, Math.round(lerp(rng, 25, 55)));
      bundle.sleep.push({
        id: `nap-${day}`,
        day,
        type: "late_nap",
        bedtime_start: napStart,
        bedtime_end: napEnd,
        total_sleep_duration: Math.round(lerp(rng, 900, 2400)),
        deep_sleep_duration: 0,
        rem_sleep_duration: 0,
        light_sleep_duration: Math.round(lerp(rng, 800, 2000)),
        awake_time: Math.round(lerp(rng, 60, 300)),
        efficiency: Math.round(lerp(rng, 70, 90)),
        average_hrv: avgHrv - 4,
        lowest_heart_rate: lowestHr + 6,
        average_breath: 15,
      });
    }

    if (rng() > 0.45) {
      const sh = weekend ? 9 : 17;
      bundle.workout.push({
        id: `wo-${day}`,
        activity: rng() > 0.5 ? "walking" : rng() > 0.5 ? "cycling" : "running",
        calories: Math.round(lerp(rng, 180, 640)),
        day,
        distance: Math.round(lerp(rng, 1200, 9000)),
        start_datetime: offsetIso(day, sh, 0),
        end_datetime: offsetIso(day, sh + 1, Math.round(lerp(rng, 5, 40))),
        intensity: rng() > 0.7 ? "hard" : rng() > 0.4 ? "moderate" : "easy",
        source: "autodetected",
      });
    }

    if (rng() > 0.8) {
      bundle.session.push({
        id: `se-${day}`,
        day,
        start_datetime: offsetIso(day, 21, 0),
        end_datetime: offsetIso(day, 21, 20),
        type: "meditation",
        mood: rng() > 0.5 ? "good" : "worse",
      });
    }

    if (rng() > 0.65) {
      bundle.tag.push({
        id: `tg-${day}`,
        day,
        text: rng() > 0.5 ? "alcohol" : "caffeine",
        tags: [rng() > 0.5 ? "alcohol" : "caffeine"],
        timestamp: offsetIso(day, 19, 30),
        comment: null,
      });
    }

    const samples = [];
    for (let m = 0; m < 24 * 60; m += 5) {
      const hh = String(Math.floor(m / 60)).padStart(2, "0");
      const mm = String(m % 60).padStart(2, "0");
      const asleep = m < 7 * 60 || m > 22 * 60;
      samples.push({
        bpm: Math.round(asleep ? lerp(rng, 48, 62) : lerp(rng, 62, 98)),
        source: asleep ? "sleep" : "awake",
        timestamp: `${day}T${hh}:${mm}:00-04:00`,
      });
    }
    bundle.heartrate.push({
      id: `hr-${day}`,
      day,
      data: samples,
    });
  }

  return bundle;
}

export function documentsForEndpoint(bundle: FixtureBundle, key: string): Json[] {
  if (key === "personal_info") return [bundle.personal_info];
  const list = (bundle as unknown as Record<string, unknown>)[key];
  return Array.isArray(list) ? (list as Json[]) : [];
}
