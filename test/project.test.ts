import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { projectDocument, enrichDailySleepFromPeriod } from "../src/sources/oura/project.ts";
import { makeSandboxFixtures } from "../src/sources/oura/fixtures.ts";
import { chunkWindows } from "../src/sources/oura/endpoints.ts";
import { offsetMinutesFromIso, toUtcIso, wallClockToUtcIso, calendarDayInZone } from "../src/lib/time.ts";
import { sha256Hex, canonicalJson } from "../src/lib/hash.ts";

describe("projectDocument", () => {
  it("projects a known sandbox day to expected sleep values", () => {
    const bundle = makeSandboxFixtures(1, "2026-08-20");
    const sleep = bundle.sleep.find((s) => s.type === "long_sleep")!;
    const [row] = projectDocument("sleep", sleep, 1, "2026-08-20T12:00:00.000Z");
    assert.equal(row.kind, "sleep_period");
    if (row.kind !== "sleep_period") return;
    assert.equal(row.row.source, "oura");
    assert.equal(row.row.day, "2026-08-20");
    assert.equal(row.row.is_nap, 0);
    assert.equal(row.row.tz_offset_min, -240);
    assert.ok((row.row.total_sleep_s ?? 0) > 10000);
    assert.equal(row.row.start_utc.endsWith("Z"), true);
  });

  it("marks late_nap as a nap", () => {
    const bundle = makeSandboxFixtures(8, "2026-08-20");
    const nap = bundle.sleep.find((s) => s.type === "late_nap");
    if (!nap) return;
    const [row] = projectDocument("sleep", nap, 1, "t");
    assert.equal(row.kind, "sleep_period");
    if (row.kind === "sleep_period") assert.equal(row.row.is_nap, 1);
  });

  it("does not put heart rate samples into D1 rows", () => {
    const [row] = projectDocument(
      "heartrate",
      { id: "hr-1", data: [{ bpm: 60, timestamp: "2026-08-20T00:00:00-04:00" }] },
      null,
      "t",
    );
    assert.equal(row.kind, "archive_only");
  });

  it("skips spo2 until a projector exists", () => {
    const [row] = projectDocument("daily_spo2", { id: "x", day: "2026-08-20" }, null, "t");
    assert.equal(row.kind, "skipped");
  });

  it("is idempotent on the same document hash", async () => {
    const bundle = makeSandboxFixtures(1, "2026-08-20");
    const doc = bundle.daily_readiness[0];
    const h1 = await sha256Hex(canonicalJson(doc));
    const h2 = await sha256Hex(canonicalJson(doc));
    assert.equal(h1, h2);
    const a = projectDocument("daily_readiness", doc, 1, "t");
    const b = projectDocument("daily_readiness", doc, 1, "t");
    assert.deepEqual(a, b);
  });

  it("enriches daily sleep from the long-sleep period", () => {
    const bundle = makeSandboxFixtures(1, "2026-08-20");
    const [daily] = projectDocument("daily_sleep", bundle.daily_sleep[0], 1, "t");
    const sleepDoc = bundle.sleep.find((s) => s.type === "long_sleep")!;
    const [period] = projectDocument("sleep", sleepDoc, 2, "t");
    assert.equal(daily.kind, "daily_sleep");
    assert.equal(period.kind, "sleep_period");
    if (daily.kind !== "daily_sleep" || period.kind !== "sleep_period") return;
    const merged = enrichDailySleepFromPeriod(daily.row, period.row);
    assert.equal(merged.total_sleep_s, period.row.total_sleep_s);
    assert.equal(merged.avg_hrv, period.row.avg_hrv);
  });
});

describe("time", () => {
  it("reads offsets from ISO strings", () => {
    assert.equal(offsetMinutesFromIso("2024-03-10T01:30:00-05:00"), -300);
    assert.equal(offsetMinutesFromIso("2024-03-10T03:30:00-04:00"), -240);
    assert.equal(offsetMinutesFromIso("2024-11-03T01:30:00Z"), 0);
  });

  it("converts DST-boundary wall clocks with an explicit offset", () => {
    assert.equal(wallClockToUtcIso("2024-03-10 01:30:00", -300), "2024-03-10T06:30:00.000Z");
    assert.equal(wallClockToUtcIso("2024-03-10 03:30:00", -240), "2024-03-10T07:30:00.000Z");
    assert.equal(wallClockToUtcIso("2024-11-03 01:30:00", -240), "2024-11-03T05:30:00.000Z");
    assert.equal(wallClockToUtcIso("2024-11-03 01:30:00", -300), "2024-11-03T06:30:00.000Z");
  });

  it("never stores a local wall-clock as UTC", () => {
    const utc = toUtcIso("2026-08-20T22:15:00-04:00");
    assert.equal(utc, "2026-08-21T02:15:00.000Z");
    assert.equal(calendarDayInZone(utc, "America/New_York"), "2026-08-20");
  });
});

describe("chunkWindows", () => {
  it("is deterministic and inclusive", () => {
    const a = chunkWindows("2026-01-01", "2026-03-15", 30);
    const b = chunkWindows("2026-01-01", "2026-03-15", 30);
    assert.deepEqual(a, b);
    assert.equal(a[0].start, "2026-01-01");
    assert.equal(a[0].end, "2026-01-30");
    assert.equal(a.at(-1)?.end, "2026-03-15");
  });
});
