import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { classifyTitle, isAfterHours } from "../src/sources/calendar/classify.ts";
import { makeCalendarFixtures } from "../src/sources/calendar/fixtures.ts";
import { projectGoogleEvent } from "../src/sources/calendar/project.ts";
import {
  joinMeeting,
  joinWorkDayToOuraMorning,
  readinessStressProxy,
  type OuraDaySlice,
} from "../src/sources/calendar/join.ts";
import {
  addCalendarDays,
  calendarDayInZone,
  localDayRangeUtc,
  localMidnightUtcIso,
  localWallInZone,
  ouraMorningDay,
  toUtcIso,
  weekBoundsMonday,
} from "../src/lib/time.ts";
import { localizeEventForZone } from "../src/sources/calendar/project.ts";
import type { CalendarEventRow } from "../src/types.ts";

const TZ = "America/New_York";

describe("classifyTitle", () => {
  it("maps title heuristics to work kinds", () => {
    assert.equal(classifyTitle("Hold for deep work"), "deep_work");
    assert.equal(classifyTitle("Weekly staff"), "internal");
    assert.equal(classifyTitle("Olive 1:1"), "internal");
    assert.equal(classifyTitle("Dentist"), "personal");
    assert.equal(classifyTitle("Invoice / bookkeep"), "admin");
    assert.equal(classifyTitle("Client pitch — Acme"), "client");
    assert.equal(classifyTitle("Ambiguous block"), "unknown");
  });

  it("treats an external attendee as client when the title is silent", () => {
    assert.equal(classifyTitle("Catch up", { externalAttendee: true }), "client");
    assert.equal(classifyTitle("Catch up"), "unknown");
  });

  it("flags after-hours at 18:00 local", () => {
    assert.equal(isAfterHours(17, 59), false);
    assert.equal(isAfterHours(18, 0), true);
    assert.equal(isAfterHours(19, 0), true);
  });
});

describe("DST-aware work day → Oura morning D+1 (America/New_York)", () => {
  it("reads EST vs EDT offsets on the 2024 spring-forward instant", () => {
    const before = localWallInZone("2024-03-10T06:30:00.000Z", TZ);
    assert.equal(before.day, "2024-03-10");
    assert.equal(before.hour, 1);
    assert.equal(before.offsetMin, -300);

    const after = localWallInZone("2024-03-10T07:30:00.000Z", TZ);
    assert.equal(after.day, "2024-03-10");
    assert.equal(after.hour, 3);
    assert.equal(after.offsetMin, -240);
  });

  it("reads the repeated 01:30 hour on 2024 fall-back", () => {
    const first = localWallInZone("2024-11-03T05:30:00.000Z", TZ);
    assert.equal(first.day, "2024-11-03");
    assert.equal(first.hour, 1);
    assert.equal(first.offsetMin, -240);

    const second = localWallInZone("2024-11-03T06:30:00.000Z", TZ);
    assert.equal(second.day, "2024-11-03");
    assert.equal(second.hour, 1);
    assert.equal(second.offsetMin, -300);
  });

  it("joins an after-hours Saturday (EST) to Sunday morning, including across spring-forward", () => {
    const utc = toUtcIso("2024-03-09T19:00:00-05:00");
    assert.equal(utc, "2024-03-10T00:00:00.000Z");
    const wall = localWallInZone(utc, TZ);
    assert.equal(wall.day, "2024-03-09");
    assert.equal(wall.hour, 19);
    assert.equal(isAfterHours(wall.hour, wall.minute), true);
    assert.equal(joinWorkDayToOuraMorning(wall.day), "2024-03-10");
    assert.equal(calendarDayInZone(utc, TZ), "2024-03-09");
  });

  it("joins a Monday 09:00 EDT standup (the morning after spring-forward) to Tuesday Oura", () => {
    const utc = toUtcIso("2024-03-10T09:00:00-04:00");
    const wall = localWallInZone(utc, TZ);
    assert.equal(wall.day, "2024-03-10");
    assert.equal(wall.hour, 9);
    assert.equal(wall.offsetMin, -240);
    assert.equal(ouraMorningDay(wall.day), "2024-03-11");
  });

  it("does not skip a calendar date when adding D+1 across DST", () => {
    assert.equal(addCalendarDays("2024-03-10", 1), "2024-03-11");
    assert.equal(addCalendarDays("2024-11-03", 1), "2024-11-04");
    assert.equal(ouraMorningDay("2024-11-02"), "2024-11-03");
  });
});

describe("local day bounds (America/New_York)", () => {
  it("uses ET midnight, not UTC midnight", () => {
    const edt = localDayRangeUtc("2026-08-21", "2026-08-21", TZ);
    assert.equal(edt.startUtc, "2026-08-21T04:00:00.000Z");
    assert.equal(edt.endUtcExclusive, "2026-08-22T04:00:00.000Z");

    const est = localDayRangeUtc("2026-01-15", "2026-01-15", TZ);
    assert.equal(est.startUtc, "2026-01-15T05:00:00.000Z");
    assert.equal(est.endUtcExclusive, "2026-01-16T05:00:00.000Z");
  });

  it("keeps DST spring-forward and fall-back midnights", () => {
    assert.equal(localMidnightUtcIso("2024-03-10", TZ), "2024-03-10T05:00:00.000Z");
    assert.equal(localMidnightUtcIso("2024-11-03", TZ), "2024-11-03T04:00:00.000Z");
  });

  it("includes a 20:00 ET meeting that is the next UTC date", () => {
    const range = localDayRangeUtc("2026-09-22", "2026-09-22", TZ);
    const late = "2026-09-23T00:30:00.000Z"; // 20:30 ET Sep 22
    assert.ok(late >= range.startUtc && late < range.endUtcExclusive);
    assert.equal(calendarDayInZone(late, TZ), "2026-09-22");
  });
});

describe("weekBoundsMonday", () => {
  it("returns Mon–Sun containing the selected day", () => {
    assert.deepEqual(weekBoundsMonday("2026-09-22"), { start: "2026-09-21", end: "2026-09-27" });
    assert.deepEqual(weekBoundsMonday("2026-09-21"), { start: "2026-09-21", end: "2026-09-27" });
    assert.deepEqual(weekBoundsMonday("2026-09-27"), { start: "2026-09-21", end: "2026-09-27" });
  });
});

describe("projectGoogleEvent", () => {
  it("projects fixture events onto local day D, kind, and after_hours", () => {
    const fixtures = makeCalendarFixtures();
    const byId = new Map(
      fixtures.map((e) => [e.id, projectGoogleEvent(e, "t", TZ, 1, "sandbox")]),
    );

    const late = byId.get("evt-dst-spring-late");
    if (!late) throw new Error("missing evt-dst-spring-late");
    assert.equal(late.day, "2024-03-09");
    assert.equal(late.kind, "client");
    assert.equal(late.after_hours, 1);
    assert.equal(late.start_local, "2024-03-09T19:00:00-05:00");
    assert.equal(joinWorkDayToOuraMorning(late.day), "2024-03-10");

    const standup = byId.get("evt-dst-spring-morning");
    if (!standup) throw new Error("missing evt-dst-spring-morning");
    assert.equal(standup.day, "2024-03-10");
    assert.equal(standup.kind, "internal");
    assert.equal(standup.after_hours, 0);
    assert.equal(standup.tz_offset_min, -240);

    const fallLate = byId.get("evt-dst-fall-late");
    if (!fallLate) throw new Error("missing evt-dst-fall-late");
    assert.equal(fallLate.day, "2024-11-02");
    assert.equal(fallLate.after_hours, 1);
    assert.equal(joinWorkDayToOuraMorning(fallLate.day), "2024-11-03");

    const cancelled = byId.get("evt-cancelled");
    if (!cancelled) throw new Error("missing evt-cancelled");
    assert.equal(cancelled.deleted_at, "t");
    assert.equal(cancelled.kind, "deep_work");

    const attendees = JSON.parse(late.attendees_json ?? "[]") as Array<{ email: string; name: string | null }>;
    const alex = attendees.find((a) => a.email === "alex@client.example");
    assert.equal(alex?.name, "Alex Rivera");
  });

  it("assigns the operator-local day even when Google labels the event UTC", () => {
    const row = projectGoogleEvent(
      {
        id: "evt-utc-label",
        summary: "Late client call",
        start: { dateTime: "2026-09-23T00:30:00Z", timeZone: "UTC" },
        end: { dateTime: "2026-09-23T01:00:00Z", timeZone: "UTC" },
      },
      "t",
      TZ,
      1,
      "sandbox",
    );
    if (!row) throw new Error("expected projection");
    assert.equal(row.day, "2026-09-22");
    assert.equal(row.after_hours, 1);
    assert.equal(row.start_local, "2026-09-22T20:30:00-04:00");
  });

  it("re-localizes a row whose stored day is the UTC date", () => {
    const stored: CalendarEventRow = {
      id: "wrong-day",
      source: "sandbox",
      day: "2026-09-23",
      start_utc: "2026-09-23T00:30:00.000Z",
      end_utc: "2026-09-23T01:00:00.000Z",
      start_local: "2026-09-23T00:30:00+00:00",
      end_local: "2026-09-23T01:00:00+00:00",
      tz_offset_min: 0,
      duration_s: 1800,
      title: "Late client call",
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
    };
    const fixed = localizeEventForZone(stored, TZ);
    assert.equal(fixed.day, "2026-09-22");
    assert.equal(fixed.after_hours, 1);
    assert.equal(fixed.start_local, "2026-09-22T20:30:00-04:00");
  });
});

describe("readiness stress proxy", () => {
  it("rises when readiness and hrv_balance fall", () => {
    const high = readinessStressProxy({
      readinessScore: 90,
      contributorsJson: JSON.stringify({ hrv_balance: 88 }),
    });
    const low = readinessStressProxy({
      readinessScore: 50,
      contributorsJson: JSON.stringify({ hrv_balance: 40 }),
    });
    if (high == null || low == null) throw new Error("proxy should be numeric");
    assert.ok(low > high);
  });
});

describe("joinMeeting", () => {
  it("attaches same-day daily_stress and next-morning sleep/readiness", () => {
    const event: CalendarEventRow = {
      id: "e1",
      source: "sandbox",
      day: "2026-08-21",
      start_utc: "2026-08-21T22:00:00.000Z",
      end_utc: "2026-08-21T23:00:00.000Z",
      start_local: "2026-08-21T18:00:00-04:00",
      end_local: "2026-08-21T19:00:00-04:00",
      tz_offset_min: -240,
      duration_s: 3600,
      title: "Client kickoff",
      kind: "client",
      client_key: null,
      project_key: null,
      attendee_count: 3,
      attendees_json: null,
      after_hours: 1,
      location: null,
      raw_id: 1,
      deleted_at: null,
      updated_at: "t",
    };
    const oura = new Map<string, OuraDaySlice>([
      [
        "2026-08-21",
        {
          day: "2026-08-21",
          sleepScore: 80,
          readinessScore: 70,
          avgHrv: 45,
          lowestHr: 50,
          totalSleepS: 25000,
          stressHighS: 9000,
          recoveryHighS: 4000,
          stressSummary: "stressful",
        },
      ],
      [
        "2026-08-22",
        {
          day: "2026-08-22",
          sleepScore: 61,
          readinessScore: 55,
          avgHrv: 28,
          lowestHr: 54,
          totalSleepS: 20000,
          stressHighS: null,
          recoveryHighS: null,
          stressSummary: null,
        },
      ],
    ]);
    const joined = joinMeeting(event, oura, [event]);
    assert.equal(joined.signals.ouraMorningDay, "2026-08-22");
    assert.equal(joined.signals.stressSource, "daily_stress");
    assert.equal(joined.signals.stressHighS, 9000);
    assert.equal(joined.signals.nextSleepScore, 61);
    assert.equal(joined.signals.nextReadinessScore, 55);
  });
});
