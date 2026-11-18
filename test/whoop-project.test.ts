import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { CalendarEventRow } from "../src/types.ts";
import {
  buildWhoopContext,
  projectWhoopCycle,
  projectWhoopDocument,
  projectWhoopRecovery,
  projectWhoopSleep,
  projectWhoopWorkout,
  whoopCycleDay,
  whoopDocumentId,
  whoopLocalDay,
  whoopOffsetMinutes,
} from "../src/sources/whoop/project.ts";
import { makeWhoopFixtures } from "../src/sources/whoop/fixtures.ts";
import { ingestWhoopBundle, whoopQueryRange } from "../src/sources/whoop/ingest.ts";
import { loadOuraSlices } from "../src/sources/calendar/query.ts";
import { joinMeetings, type OuraDaySlice } from "../src/sources/calendar/join.ts";
import { buildRangeBriefing } from "../src/sources/calendar/range.ts";
import { buildDayBriefing } from "../src/sources/calendar/meetings.ts";
import { mergeDailyMetrics } from "../src/lib/daily-metrics.ts";

const T = "2026-11-17T12:00:00.000Z";

// Shapes follow the WHOOP v2 API reference. All values are made up.
const SLEEP = {
  id: "sleep-aaaa",
  cycle_id: 9001,
  user_id: 1,
  start: "2026-11-17T04:10:00.000Z", // 23:10 on the 16th, New York
  end: "2026-11-17T11:40:00.000Z", // 06:40 on the 17th, New York
  timezone_offset: "-05:00",
  nap: false,
  score_state: "SCORED",
  score: {
    stage_summary: {
      total_in_bed_time_milli: 27_000_000,
      total_awake_time_milli: 1_800_000,
      total_no_data_time_milli: 0,
      total_light_sleep_time_milli: 12_600_000,
      total_slow_wave_sleep_time_milli: 5_400_000,
      total_rem_sleep_time_milli: 7_200_000,
      sleep_cycle_count: 5,
      disturbance_count: 9,
    },
    respiratory_rate: 15.234,
    sleep_performance_percentage: 84.6,
    sleep_consistency_percentage: 77,
    sleep_efficiency_percentage: 93.4,
  },
};

const RECOVERY = {
  cycle_id: 9001,
  sleep_id: "sleep-aaaa",
  user_id: 1,
  created_at: "2026-11-17T11:45:00.000Z",
  updated_at: "2026-11-17T11:45:00.000Z",
  score_state: "SCORED",
  score: {
    user_calibrating: false,
    recovery_score: 62,
    resting_heart_rate: 54,
    hrv_rmssd_milli: 48.26,
    spo2_percentage: 96.2,
    skin_temp_celsius: 33.5,
  },
};

const CYCLE = {
  id: 9001,
  user_id: 1,
  start: "2026-11-17T04:10:00.000Z",
  end: "2026-11-18T03:55:00.000Z",
  timezone_offset: "-05:00",
  score_state: "SCORED",
  step_count: 8421,
  score: { strain: 14.237, kilojoule: 10460, average_heart_rate: 71, max_heart_rate: 158 },
};

const WORKOUT = {
  id: "workout-bbbb",
  user_id: 1,
  start: "2026-11-17T12:30:00.000Z",
  end: "2026-11-17T13:15:00.000Z",
  timezone_offset: "-05:00",
  sport_name: "running",
  sport_id: 0,
  score_state: "SCORED",
  score: { strain: 9.84, average_heart_rate: 141, max_heart_rate: 172, kilojoule: 2092 },
};

function only<K extends string>(items: Array<{ kind: string }>, kind: K) {
  const hit = items.find((i) => i.kind === kind);
  assert.ok(hit, `expected a ${kind} row`);
  return hit as { kind: K; row: Record<string, unknown> } & Record<string, unknown>;
}

describe("WHOOP days", () => {
  it("uses WHOOP's own offset to find the local day", () => {
    assert.equal(whoopOffsetMinutes("-05:00"), -300);
    assert.equal(whoopOffsetMinutes("+05:30"), 330);
    assert.equal(whoopOffsetMinutes("Z"), 0);
    assert.equal(whoopOffsetMinutes(undefined), null);
    assert.equal(whoopLocalDay("2026-11-17T03:30:00.000Z", "-05:00"), "2026-11-16");
    assert.equal(whoopLocalDay("2026-11-17T03:30:00.000Z", "+09:00"), "2026-11-17");
    // No offset: fall back to the profile time zone.
    assert.equal(whoopLocalDay("2026-11-17T03:30:00.000Z", null, "America/New_York"), "2026-11-16");
  });

  it("dates a cycle by its middle, since it starts the evening before", () => {
    assert.equal(whoopCycleDay(CYCLE), "2026-11-17");
    // Still in progress: no end yet.
    assert.equal(whoopCycleDay({ ...CYCLE, end: null }), "2026-11-17");
  });

  it("gives recoveries a stable document id from their cycle", () => {
    assert.equal(whoopDocumentId("recovery", RECOVERY), "cycle-9001");
    assert.equal(whoopDocumentId("cycle", CYCLE), "9001");
    assert.equal(whoopDocumentId("sleep", SLEEP), "sleep-aaaa");
  });
});

describe("WHOOP sleep → sleep_periods + daily_sleep", () => {
  it("lands on the morning it ended, in seconds, with WHOOP's sleep performance as the score", () => {
    const out = projectWhoopSleep(SLEEP, 7, T);
    const period = only(out, "sleep_period").row;
    assert.equal(period.id, "sleep-aaaa");
    assert.equal(period.source, "whoop");
    assert.equal(period.day, "2026-11-17");
    assert.equal(period.is_nap, 0);
    assert.equal(period.tz_offset_min, -300);
    assert.equal(period.total_sleep_s, 25_200); // light + deep + REM = 7 h
    assert.equal(period.deep_s, 5_400);
    assert.equal(period.rem_s, 7_200);
    assert.equal(period.light_s, 12_600);
    assert.equal(period.awake_s, 1_800);
    assert.equal(period.efficiency, 93);
    assert.equal(period.raw_id, 7);

    const daily = only(out, "daily_sleep").row;
    assert.equal(daily.day, "2026-11-17");
    assert.equal(daily.source, "whoop");
    assert.equal(daily.score, 85);
    assert.equal(daily.total_sleep_s, 25_200);
    assert.equal(daily.time_in_bed_s, 27_000);
    assert.equal(daily.respiratory_rate, 15.23);
    assert.equal(daily.avg_hrv, null, "HRV comes from the recovery, not the sleep");
  });

  it("keeps a nap out of the daily score, and an unscored sleep out of it too", () => {
    const nap = projectWhoopSleep({ ...SLEEP, id: "nap-1", nap: true }, 1, T);
    assert.deepEqual(nap.map((p) => p.kind), ["sleep_period"]);
    assert.equal(only(nap, "sleep_period").row.is_nap, 1);
    const pending = projectWhoopSleep({ ...SLEEP, score_state: "PENDING_SCORE", score: undefined }, 1, T);
    assert.deepEqual(pending.map((p) => p.kind), ["sleep_period"]);
    assert.equal(only(pending, "sleep_period").row.total_sleep_s, null);
  });
});

describe("WHOOP recovery → daily_readiness + morning vitals", () => {
  it("maps score, HRV (rmssd) and resting heart rate onto the sleep's morning", () => {
    const ctx = buildWhoopContext([SLEEP]);
    const out = projectWhoopRecovery(RECOVERY, 8, T, ctx);
    const readiness = only(out, "daily_readiness").row;
    assert.equal(readiness.day, "2026-11-17");
    assert.equal(readiness.source, "whoop");
    assert.equal(readiness.score, 62);
    assert.deepEqual(JSON.parse(String(readiness.contributors_json)), {
      hrv_rmssd_milli: 48.3,
      resting_heart_rate: 54,
      spo2_percentage: 96.2,
      skin_temp_celsius: 33.5,
      user_calibrating: false,
    });
    const vitals = out.find((p) => p.kind === "sleep_vitals");
    assert.deepEqual(vitals, { kind: "sleep_vitals", day: "2026-11-17", avg_hrv: 48.3, lowest_hr: 54, raw_id: 8, updated_at: T });
  });

  it("falls back to the day it was created when its sleep is unknown, and skips an unscored one", () => {
    const alone = projectWhoopRecovery({ ...RECOVERY, sleep_id: "elsewhere", cycle_id: 1 }, 8, T, { timeZone: "America/New_York" });
    assert.equal(only(alone, "daily_readiness").row.day, "2026-11-17");
    const pending = projectWhoopRecovery({ ...RECOVERY, score_state: "PENDING_SCORE" }, 8, T);
    assert.deepEqual(pending.map((p) => p.kind), ["skipped"]);
  });
});

describe("WHOOP cycle → daily_strain (+ steps)", () => {
  it("maps strain and average / max heart rate onto the day of its sleep", () => {
    const out = projectWhoopCycle(CYCLE, 9, T, buildWhoopContext([SLEEP]));
    const strain = only(out, "daily_strain").row;
    assert.deepEqual(
      { day: strain.day, source: strain.source, strain: strain.strain, avg_hr: strain.avg_hr, max_hr: strain.max_hr },
      { day: "2026-11-17", source: "whoop", strain: 14.2, avg_hr: 71, max_hr: 158 },
    );
    const activity = only(out, "daily_activity").row;
    assert.equal(activity.steps, 8421);
    assert.equal(activity.total_cal, 2500); // 10,460 kJ
    assert.equal(activity.score, null, "WHOOP has no 0–100 activity score; do not invent one");
  });

  it("writes no strain for a cycle WHOOP has not scored", () => {
    const out = projectWhoopCycle({ ...CYCLE, score_state: "PENDING_SCORE", score: undefined, step_count: undefined }, 9, T);
    assert.deepEqual(out.map((p) => p.kind), ["skipped"]);
  });
});

describe("WHOOP workout → workouts", () => {
  it("keeps strain, heart rate and energy", () => {
    const row = only(projectWhoopWorkout(WORKOUT, 10, T), "workout").row;
    assert.deepEqual(
      { id: row.id, source: row.source, day: row.day, activity: row.activity, strain: row.strain, avg_hr: row.avg_hr, max_hr: row.max_hr, calories: row.calories },
      { id: "workout-bbbb", source: "whoop", day: "2026-11-17", activity: "running", strain: 9.8, avg_hr: 141, max_hr: 172, calories: 500 },
    );
    assert.equal(row.start_utc, "2026-11-17T12:30:00.000Z");
  });

  it("ignores a collection it does not know", () => {
    assert.deepEqual(projectWhoopDocument("heart_rate", {}, 1, T).map((p) => p.kind), ["skipped"]);
  });
});

/** Just enough of D1 to record what ingest writes and answer what it asks. */
function recordingDb(opts: { rawExists?: boolean } = {}) {
  const writes: Array<{ sql: string; args: unknown[] }> = [];
  let nextId = 0;
  const db = {
    prepare(sql: string) {
      let args: unknown[] = [];
      const stmt = {
        bind(...a: unknown[]) {
          args = a;
          return stmt;
        },
        async first() {
          if (/FROM raw_object/.test(sql)) return opts.rawExists ? { id: 1 } : null;
          if (/INSERT INTO raw_object/.test(sql)) {
            writes.push({ sql, args });
            nextId += 1;
            return { id: nextId };
          }
          return null;
        },
        async run() {
          writes.push({ sql, args });
          return { success: true };
        },
        async all() {
          return { results: [] };
        },
      };
      return stmt;
    },
  };
  const table = (name: string) => writes.filter((w) => new RegExp(`INSERT INTO ${name}\\b`).test(w.sql));
  return { db: db as unknown as D1Database, writes, table };
}

function fakeEnv(db: D1Database) {
  const objects = new Map<string, string>();
  return {
    env: { DB: db, RAW: { put: async (k: string, v: string) => void objects.set(k, v) } } as never,
    objects,
  };
}

describe("WHOOP ingest", () => {
  const bundle = { sleep: [SLEEP], recovery: [RECOVERY], cycle: [CYCLE], workout: [WORKOUT] };

  it("archives each record and writes provider-neutral rows tagged whoop", async () => {
    const { db, table } = recordingDb();
    const { env, objects } = fakeEnv(db);
    const tally = await ingestWhoopBundle(env, bundle, T);
    assert.deepEqual(tally, { written: 4, skipped: 0 });
    assert.equal(objects.size, 4);
    assert.ok([...objects.keys()].every((k) => k.startsWith("whoop/")));
    assert.equal(table("raw_object").length, 4);
    assert.ok(table("raw_object").every((w) => w.args[0] === "whoop"));

    assert.equal(table("sleep_periods").length, 1);
    assert.equal(table("daily_readiness").length, 1);
    assert.equal(table("daily_strain").length, 1);
    assert.equal(table("daily_activity").length, 1);
    assert.equal(table("workouts").length, 1);
    // The sleep's own row, then the recovery's HRV / resting heart rate for the same morning.
    const sleepWrites = table("daily_sleep");
    assert.equal(sleepWrites.length, 2);
    assert.deepEqual(sleepWrites[1].args.slice(0, 5), ["2026-11-17", "whoop", "2026-11-17", 48.3, 54]);
    assert.deepEqual(table("daily_strain")[0].args.slice(0, 6), ["2026-11-17", "whoop", "2026-11-17", 14.2, 71, 158]);
    assert.deepEqual(table("daily_readiness")[0].args.slice(0, 4), ["2026-11-17", "whoop", "2026-11-17", 62]);
  });

  it("skips records it already has, so a re-run writes nothing", async () => {
    const { db, writes } = recordingDb({ rawExists: true });
    const { env, objects } = fakeEnv(db);
    assert.deepEqual(await ingestWhoopBundle(env, bundle, T), { written: 0, skipped: 4 });
    assert.equal(writes.length, 0);
    assert.equal(objects.size, 0);
  });

  it("reaches a day either side of the window, because WHOOP filters by start time", () => {
    assert.deepEqual(whoopQueryRange({ start: "2026-11-10", end: "2026-11-16" }), {
      startIso: "2026-11-09T00:00:00.000Z",
      endIso: "2026-11-18T00:00:00.000Z",
    });
  });

  it("ships fixtures that are deterministic and all projectable", () => {
    const a = makeWhoopFixtures(21, "2026-11-17");
    assert.deepEqual(a, makeWhoopFixtures(21, "2026-11-17"));
    assert.equal(a.sleep.length, 21);
    assert.equal(a.recovery.length, 21);
    assert.equal(a.cycle.length, 21);
    const ctx = buildWhoopContext(a.sleep);
    const days = a.recovery.map((r) => only(projectWhoopRecovery(r, 1, T, ctx), "daily_readiness").row.day);
    assert.equal(days[days.length - 1], "2026-11-17");
    assert.equal(new Set(days).size, 21, "one recovery per morning");
    for (const c of a.cycle) assert.equal(only(projectWhoopCycle(c, 1, T, ctx), "daily_strain").row.source, "whoop");
  });
});

/** D1 stand-in that answers the slice queries from rows, filtered by the bound source. */
function sliceDb(rows: Record<string, Array<Record<string, unknown>>>) {
  const asked: string[] = [];
  const db = {
    prepare(sql: string) {
      let source: unknown;
      const stmt = {
        bind(...a: unknown[]) {
          source = a[0];
          return stmt;
        },
        async all() {
          const m = /FROM (\w+)/.exec(sql);
          const table = m ? m[1] : "";
          asked.push(table);
          return { results: (rows[table] ?? []).filter((r) => r.source === source) };
        },
        async first() {
          return null;
        },
      };
      return stmt;
    },
  };
  return { db: db as unknown as D1Database, asked };
}

function event(day: string, id: string, extra: Partial<CalendarEventRow> = {}): CalendarEventRow {
  return {
    id,
    source: "sandbox",
    day,
    start_utc: `${day}T15:00:00.000Z`,
    end_utc: `${day}T16:00:00.000Z`,
    start_local: `${day}T10:00:00-05:00`,
    end_local: `${day}T11:00:00-05:00`,
    tz_offset_min: -300,
    duration_s: 3600,
    title: id,
    kind: "client",
    client_key: null,
    project_key: null,
    attendee_count: 2,
    attendees_json: null,
    after_hours: 0,
    location: null,
    raw_id: 1,
    deleted_at: null,
    updated_at: "t",
    ...extra,
  };
}

describe("WHOOP rows in the provider-neutral aggregator", () => {
  const rows = {
    daily_sleep: [
      { source: "whoop", day: "2026-11-17", score: 85, avg_hrv: 48.3, lowest_hr: 54, total_sleep_s: 25_200 },
      { source: "whoop", day: "2026-11-18", score: 61, avg_hrv: 39, lowest_hr: 58, total_sleep_s: 19_800 },
      { source: "oura", day: "2026-11-17", score: 99, avg_hrv: 1, lowest_hr: 1, total_sleep_s: 1 },
    ],
    daily_readiness: [
      { source: "whoop", day: "2026-11-17", score: 62, contributors_json: null },
      { source: "whoop", day: "2026-11-18", score: 31, contributors_json: null },
      { source: "oura", day: "2026-11-17", score: 99, contributors_json: null },
    ],
    daily_stress: [{ source: "oura", day: "2026-11-17", stress_high_s: 3600, recovery_high_s: 0, day_summary: "normal" }],
    daily_strain: [
      { source: "whoop", day: "2026-11-17", strain: 14.2, avg_hr: 71, max_hr: 158 },
      { source: "whoop", day: "2026-11-18", strain: 9.2, avg_hr: 66, max_hr: 140 },
    ],
  };

  it("reads only the active source, and adds strain only for a wearable that has it", async () => {
    const whoop = sliceDb(rows);
    const { byDay } = await loadOuraSlices(whoop.db, "2026-11-17", "2026-11-18", "whoop");
    assert.deepEqual(byDay.get("2026-11-17"), {
      day: "2026-11-17",
      sleepScore: 85,
      readinessScore: 62,
      avgHrv: 48.3,
      lowestHr: 54,
      totalSleepS: 25_200,
      stressHighS: null,
      recoveryHighS: null,
      stressSummary: null,
      strain: 14.2,
      dayAvgHr: 71,
      dayMaxHr: 158,
    });

    const oura = sliceDb(rows);
    const o = await loadOuraSlices(oura.db, "2026-11-17", "2026-11-18", "oura");
    assert.equal(o.byDay.get("2026-11-17")?.sleepScore, 99);
    assert.equal(o.byDay.get("2026-11-17")?.stressHighS, 3600);
    assert.equal("strain" in (o.byDay.get("2026-11-17") ?? {}), false);
    assert.equal(oura.asked.includes("daily_strain"), false, "Oura never touches the strain table");
    assert.equal(o.byDay.has("2026-11-18"), false);

    // Default source is Oura: callers that predate WEARABLE behave as before.
    const legacy = await loadOuraSlices(sliceDb(rows).db, "2026-11-17", "2026-11-18");
    assert.equal(legacy.byDay.get("2026-11-17")?.sleepScore, 99);
  });

  it("joins a work day to the next morning's recovery and averages strain over a range", async () => {
    const { byDay } = await loadOuraSlices(sliceDb(rows).db, "2026-11-17", "2026-11-18", "whoop");
    const joined = joinMeetings([event("2026-11-17", "a"), event("2026-11-17", "b", { after_hours: 1 })], byDay);
    assert.equal(joined[0].signals.nextReadinessScore, 31);
    assert.equal(joined[0].signals.nextSleepScore, 61);
    assert.equal(joined[0].signals.nextHrv, 39);

    const range = buildRangeBriefing({
      start: "2026-11-17",
      end: "2026-11-18",
      timeZone: "America/New_York",
      joined,
      recoveryByDay: byDay,
      intradayHr: false,
    });
    assert.deepEqual(range.days[0].morning, { sleepScore: 85, readinessScore: 62, strain: 14.2 });
    assert.deepEqual(range.days[0].nextMorning, { sleepScore: 61, readinessScore: 31, strain: 9.2 });
    assert.equal(range.recovery.avgReadinessScore, 46.5);
    assert.equal(range.recovery.nStrain, 2);
    assert.equal(range.recovery.avgStrain, 11.7);
    assert.equal(range.summary.noHr, 2);
    assert.equal(range.summary.line, "2 meetings across 1 day from Nov 17 to Nov 18: 2 hours in meetings, 1 after hours.");
    assert.doesNotMatch(range.summary.line, /ring|invent/i);
  });

  it("leaves Oura's range shape and wording exactly as it was", () => {
    const byDay = new Map<string, OuraDaySlice>([
      ["2026-11-17", { day: "2026-11-17", sleepScore: 80, readinessScore: 75, avgHrv: 50, lowestHr: 52, totalSleepS: 25_000, stressHighS: null, recoveryHighS: null, stressSummary: null }],
    ]);
    const joined = joinMeetings([event("2026-11-17", "a")], byDay);
    const range = buildRangeBriefing({ start: "2026-11-17", end: "2026-11-17", timeZone: "America/New_York", joined, recoveryByDay: byDay });
    assert.deepEqual(range.days[0].morning, { sleepScore: 80, readinessScore: 75 });
    assert.equal("nStrain" in range.recovery, false);
    assert.match(range.summary.line, /No ring HR in those windows/);
  });

  it("words the day summary for the wearable and mentions strain", () => {
    const byDay = new Map<string, OuraDaySlice>([
      ["2026-11-17", { day: "2026-11-17", sleepScore: 85, readinessScore: 62, avgHrv: 48, lowestHr: 54, totalSleepS: 25_200, stressHighS: null, recoveryHighS: null, stressSummary: null, strain: 14.2 }],
    ]);
    const joined = joinMeetings([event("2026-11-17", "a")], byDay);
    const base = { date: "2026-11-17", timeZone: "America/New_York", joined, priorNight: byDay.get("2026-11-17") ?? null, nextMorning: null };
    const whoop = buildDayBriefing({ ...base, labels: { provider: "WHOOP", readiness: "recovery", strain: "strain", intradayHr: false } });
    assert.match(whoop.summary, /sleep 85 \/ recovery 62/);
    assert.match(whoop.summary, /Day strain reached 14\.2\./);
    assert.match(whoop.summary, /Next-morning WHOOP/);
    assert.doesNotMatch(whoop.summary, /Oura|readiness/);
    assert.equal(whoop.hr, null);
    const oura = buildDayBriefing(base);
    assert.match(oura.summary, /sleep 85 \/ readiness 62/);
    assert.match(oura.summary, /Next-morning Oura/);
    assert.doesNotMatch(oura.summary, /strain/i);
  });

  it("adds strain to daily metrics only when asked", () => {
    const withStrain = mergeDailyMetrics({ start: "2026-11-17", end: "2026-11-18", strain: [{ day: "2026-11-17", strain: 14.2 }] });
    assert.deepEqual(withStrain.map((d) => d.strain), [14.2, null]);
    const without = mergeDailyMetrics({ start: "2026-11-17", end: "2026-11-17" });
    assert.equal("strain" in without[0], false);
  });
});
