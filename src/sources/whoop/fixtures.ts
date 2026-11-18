import { addCalendarDays } from "../../lib/time.ts";
import type { WhoopCollectionKey } from "./endpoints.ts";

export type WhoopBundle = Record<WhoopCollectionKey, unknown[]>;

function pad(n: number): string {
  return String(n).padStart(2, "0");
}

/**
 * Made-up WHOOP v2 records for `days` mornings ending on `endDay`.
 * Shapes follow the public API reference; every value is synthetic and
 * depends only on the date, so loading them twice writes nothing new.
 */
export function makeWhoopFixtures(days = 21, endDay: string = new Date().toISOString().slice(0, 10)): WhoopBundle {
  const bundle: WhoopBundle = { sleep: [], recovery: [], cycle: [], workout: [] };
  for (let i = days - 1; i >= 0; i -= 1) {
    const day = addCalendarDays(endDay, -i);
    const prev = addCalendarDays(day, -1);
    const seed = Number(day.slice(8, 10)) + Number(day.slice(5, 7)) * 3;
    const cycleId = Number(day.replaceAll("-", ""));
    const sleepId = `fixture-sleep-${day}`;
    const sleepStart = `${prev}T23:${pad((seed * 7) % 50)}:00.000-05:00`;
    const sleepEnd = `${day}T06:${pad((seed * 11) % 55)}:00.000-05:00`;
    const stamp = `${day}T12:00:00.000Z`;
    const recovery = 35 + ((seed * 13) % 60);
    const strain = Math.round((6 + ((seed * 5) % 120) / 10) * 10) / 10;
    const light = (3.2 + (seed % 5) * 0.2) * 3_600_000;
    const deep = (1.2 + (seed % 3) * 0.2) * 3_600_000;
    const rem = (1.5 + (seed % 4) * 0.2) * 3_600_000;
    const awake = (0.4 + (seed % 3) * 0.1) * 3_600_000;

    bundle.sleep.push({
      id: sleepId,
      cycle_id: cycleId,
      user_id: 1,
      created_at: stamp,
      updated_at: stamp,
      start: sleepStart,
      end: sleepEnd,
      timezone_offset: "-05:00",
      nap: false,
      score_state: "SCORED",
      score: {
        stage_summary: {
          total_in_bed_time_milli: Math.round(light + deep + rem + awake),
          total_awake_time_milli: Math.round(awake),
          total_no_data_time_milli: 0,
          total_light_sleep_time_milli: Math.round(light),
          total_slow_wave_sleep_time_milli: Math.round(deep),
          total_rem_sleep_time_milli: Math.round(rem),
          sleep_cycle_count: 4 + (seed % 2),
          disturbance_count: 6 + (seed % 7),
        },
        sleep_needed: {
          baseline_milli: 27_000_000,
          need_from_sleep_debt_milli: 600_000,
          need_from_recent_strain_milli: 300_000,
          need_from_recent_nap_milli: 0,
        },
        respiratory_rate: 14 + (seed % 20) / 10,
        sleep_performance_percentage: 62 + ((seed * 7) % 36),
        sleep_consistency_percentage: 70 + (seed % 25),
        sleep_efficiency_percentage: 86 + (seed % 10),
      },
    });

    bundle.recovery.push({
      cycle_id: cycleId,
      sleep_id: sleepId,
      user_id: 1,
      created_at: stamp,
      updated_at: stamp,
      score_state: "SCORED",
      score: {
        user_calibrating: false,
        recovery_score: recovery,
        resting_heart_rate: 50 + (seed % 12),
        hrv_rmssd_milli: 38 + ((seed * 3) % 45) + 0.5,
        spo2_percentage: 96.5,
        skin_temp_celsius: 33.4,
      },
    });

    bundle.cycle.push({
      id: cycleId,
      user_id: 1,
      created_at: stamp,
      updated_at: stamp,
      start: sleepStart,
      end: `${day}T23:${pad((seed * 3) % 50)}:00.000-05:00`,
      timezone_offset: "-05:00",
      score_state: "SCORED",
      step_count: 5_000 + ((seed * 311) % 7_000),
      score: {
        strain,
        kilojoule: 8_000 + ((seed * 97) % 4_000),
        average_heart_rate: 62 + (seed % 14),
        max_heart_rate: 130 + ((seed * 3) % 45),
      },
    });

    if (seed % 3 === 0) {
      bundle.workout.push({
        id: `fixture-workout-${day}`,
        user_id: 1,
        created_at: stamp,
        updated_at: stamp,
        start: `${day}T07:30:00.000-05:00`,
        end: `${day}T08:15:00.000-05:00`,
        timezone_offset: "-05:00",
        sport_name: seed % 2 ? "running" : "cycling",
        sport_id: seed % 2 ? 0 : 1,
        score_state: "SCORED",
        score: {
          strain: Math.round((7 + (seed % 60) / 10) * 10) / 10,
          average_heart_rate: 132 + (seed % 20),
          max_heart_rate: 160 + (seed % 22),
          kilojoule: 1_500 + ((seed * 41) % 1_200),
          percent_recorded: 100,
        },
      });
    }
  }
  return bundle;
}
