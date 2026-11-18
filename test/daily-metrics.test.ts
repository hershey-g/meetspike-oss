import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  inclusiveDayCount,
  mergeDailyMetrics,
  parseDayRange,
} from "../src/lib/daily-metrics.ts";

describe("parseDayRange", () => {
  it("defaults to 30 inclusive days ending today", () => {
    const r = parseDayRange(undefined, undefined, "2026-09-22");
    assert.deepEqual(r, { start: "2026-08-24", end: "2026-09-22" });
    assert.ok(!("error" in r));
    if ("error" in r) return;
    assert.equal(inclusiveDayCount(r.start, r.end), 30);
  });

  it("rejects inverted and oversized ranges", () => {
    assert.deepEqual(parseDayRange("2026-09-22", "2026-09-01", "2026-09-22"), {
      error: "start must be on or before end",
    });
    assert.deepEqual(parseDayRange("2026-01-01", "2026-09-22", "2026-09-22"), {
      error: "range cannot exceed 90 days",
    });
    assert.deepEqual(parseDayRange("22-09-2026", undefined, "2026-09-22"), {
      error: "start must be YYYY-MM-DD",
    });
  });
});

describe("mergeDailyMetrics", () => {
  it("fills a continuous series and keeps nulls when a table has no row", () => {
    const days = mergeDailyMetrics({
      start: "2026-08-21",
      end: "2026-08-23",
      sleep: [
        { day: "2026-08-21", score: 74, avg_hrv: 42, lowest_hr: 51, total_sleep_s: 25000 },
        { day: "2026-08-23", score: 81, avg_hrv: 48, lowest_hr: 49, total_sleep_s: 27000 },
      ],
      readiness: [{ day: "2026-08-21", score: 68 }],
      activity: [{ day: "2026-08-22", score: 80, steps: 9000 }],
      stress: [
        { day: "2026-08-21", stress_high_s: 5400, recovery_high_s: 8000, day_summary: "stressful" },
      ],
    });
    assert.equal(days.length, 3);
    assert.equal(days[0].sleepScore, 74);
    assert.equal(days[0].readinessScore, 68);
    assert.equal(days[0].stressSummary, "stressful");
    assert.equal(days[1].sleepScore, null);
    assert.equal(days[1].activityScore, 80);
    assert.equal(days[1].steps, 9000);
    assert.equal(days[2].sleepScore, 81);
    assert.equal(days[2].readinessScore, null);
    assert.ok(!JSON.stringify(days).includes("access_token"));
  });
});
