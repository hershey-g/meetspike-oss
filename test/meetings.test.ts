import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { CalendarEventRow } from "../src/types.ts";
import { joinMeetings, type OuraDaySlice } from "../src/sources/calendar/join.ts";
import {
  GRAIN_NOTE,
  buildDayBriefing,
  buildWeekBriefing,
  composeDaySummary,
  composeWeekSummary,
  rankSleepImpactMeetings,
  rankStressedMeetings,
  toPersonMeetingJson,
} from "../src/sources/calendar/meetings.ts";
import { weekBoundsMonday } from "../src/lib/time.ts";
import type { MeetingHrStress } from "../src/lib/heartrate.ts";
import { PERSON_SERIES_MAX } from "../src/lib/heartrate.ts";
import { projectGoogleEvent } from "../src/sources/calendar/project.ts";
import { makeCalendarFixtures } from "../src/sources/calendar/fixtures.ts";

const TZ = "America/New_York";

function event(partial: Partial<CalendarEventRow> & Pick<CalendarEventRow, "id" | "day" | "kind">): CalendarEventRow {
  return {
    source: "sandbox",
    start_utc: `${partial.day}T14:00:00.000Z`,
    end_utc: `${partial.day}T15:00:00.000Z`,
    start_local: `${partial.day}T10:00:00-04:00`,
    end_local: `${partial.day}T11:00:00-04:00`,
    tz_offset_min: -240,
    duration_s: 3600,
    title: partial.title ?? partial.kind,
    client_key: null,
    project_key: null,
    attendee_count: 2,
    attendees_json: null,
    after_hours: 0,
    location: null,
    raw_id: 1,
    deleted_at: null,
    updated_at: "t",
    ...partial,
  };
}

function oura(day: string, extra: Partial<OuraDaySlice> = {}): OuraDaySlice {
  return {
    day,
    sleepScore: 80,
    readinessScore: 78,
    avgHrv: 48,
    lowestHr: 50,
    totalSleepS: 26000,
    stressHighS: 3000,
    recoveryHighS: 8000,
    stressSummary: "normal",
    ...extra,
  };
}

describe("GET /api/meetings/stressed handler", () => {
  it("ranks a late client day with high daily_stress above a quiet internal", () => {
    const lateClient = event({
      id: "late",
      day: "2026-08-21",
      kind: "client",
      title: "Retainer check-in",
      after_hours: 1,
      start_local: "2026-08-21T18:00:00-04:00",
      start_utc: "2026-08-21T22:00:00.000Z",
      attendee_count: 5,
    });
    const quiet = event({
      id: "quiet",
      day: "2026-08-20",
      kind: "internal",
      title: "Team standup",
    });
    const byDay = new Map<string, OuraDaySlice>([
      ["2026-08-20", oura("2026-08-20", { stressHighS: 1500, stressSummary: "restorative" })],
      ["2026-08-21", oura("2026-08-21", { stressHighS: 11000, stressSummary: "stressful" })],
      ["2026-08-22", oura("2026-08-22", { readinessScore: 52, sleepScore: 60, avgHrv: 26 })],
    ]);
    const joined = joinMeetings([lateClient, quiet], byDay);
    const ranked = rankStressedMeetings(joined, 10);
    assert.equal(ranked[0].id, "late");
    assert.ok(ranked[0].score > ranked[1].score);
    assert.ok(ranked[0].flags.includes("after_hours"));
    assert.ok(ranked[0].flags.includes("low_next_readiness"));
    assert.equal(ranked[0].signals.stressSource, "daily_stress");
    assert.equal(ranked[0].ouraMorningDay, "2026-08-22");
    assert.match(GRAIN_NOTE.stress, /heart-rate from your ring/);
    assert.match(GRAIN_NOTE.stress, /not Oura's daytime stress/);
  });

  it("uses a readiness proxy when daily_stress is missing", () => {
    const ev = event({ id: "p", day: "2026-08-10", kind: "client" });
    const byDay = new Map<string, OuraDaySlice>([
      [
        "2026-08-10",
        oura("2026-08-10", { stressHighS: null, recoveryHighS: null, readinessScore: 48 }),
      ],
    ]);
    const contrib = new Map([["2026-08-10", JSON.stringify({ hrv_balance: 40 })]]);
    const [row] = joinMeetings([ev], byDay, contrib);
    const [json] = rankStressedMeetings([row], 5);
    assert.equal(json.signals.stressSource, "readiness_proxy");
    assert.ok(json.signals.readinessProxy != null);
    assert.ok(json.flags.includes("stress_proxy"));
  });
});

describe("GET /api/meetings/sleep-impact handler", () => {
  it("scores after-hours + poor next-morning sleep above a midday personal", () => {
    const late = event({
      id: "late",
      day: "2026-08-21",
      kind: "client",
      after_hours: 1,
      start_local: "2026-08-21T19:00:00-04:00",
      start_utc: "2026-08-21T23:00:00.000Z",
    });
    const personal = event({
      id: "dentist",
      day: "2026-08-22",
      kind: "personal",
      title: "Dentist",
      start_local: "2026-08-22T15:00:00-04:00",
      start_utc: "2026-08-22T19:00:00.000Z",
    });
    const byDay = new Map<string, OuraDaySlice>([
      ["2026-08-22", oura("2026-08-22", { sleepScore: 58, readinessScore: 54, totalSleepS: 19000 })],
      ["2026-08-23", oura("2026-08-23", { sleepScore: 88, readinessScore: 86 })],
    ]);
    const ranked = rankSleepImpactMeetings(joinMeetings([late, personal], byDay), 10);
    assert.equal(ranked[0].id, "late");
    assert.ok(ranked[0].flags.includes("low_next_sleep"));
    assert.ok(ranked[0].score > ranked[1].score);
  });

  it("flags an early standup as sleep-relevant even without Oura yet", () => {
    const early = event({
      id: "early",
      day: "2026-08-20",
      kind: "internal",
      start_local: "2026-08-20T07:15:00-04:00",
      start_utc: "2026-08-20T11:15:00.000Z",
    });
    const [json] = rankSleepImpactMeetings(joinMeetings([early], new Map()), 5);
    assert.ok(json.earlyStart);
    assert.ok(json.flags.includes("early_start"));
    assert.ok(json.score > 0);
  });
});

describe("GET /api/briefing/day handler", () => {
  it("returns calendar load, prior-night Oura, and flags for a heavy day", () => {
    const fixtures = makeCalendarFixtures()
      .filter((e) => e.id?.startsWith("evt-heavy"))
      .map((e) => projectGoogleEvent(e, "t", TZ, 1, "sandbox"))
      .filter((e): e is NonNullable<typeof e> => e != null);
    assert.ok(fixtures.length >= 5);

    const byDay = new Map<string, OuraDaySlice>([
      ["2026-08-21", oura("2026-08-21", { sleepScore: 62, readinessScore: 58, stressSummary: "stressful" })],
      ["2026-08-22", oura("2026-08-22", { sleepScore: 60, readinessScore: 54 })],
    ]);
    const joined = joinMeetings(fixtures, byDay);
    const briefing = buildDayBriefing({
      date: "2026-08-21",
      timeZone: TZ,
      joined,
      priorNight: byDay.get("2026-08-21") ?? null,
      nextMorning: byDay.get("2026-08-22") ?? null,
    });

    assert.equal(briefing.ok, true);
    assert.equal(briefing.date, "2026-08-21");
    assert.ok(briefing.calendar.eventCount >= 5);
    assert.ok(briefing.calendar.clientCount >= 3);
    assert.ok(briefing.calendar.afterHoursCount >= 1);
    assert.ok(briefing.flags.includes("heavy_day"));
    assert.ok(briefing.flags.includes("after_hours"));
    assert.ok(briefing.flags.includes("low_morning_readiness"));
    assert.equal(briefing.join.priorNightOuraDay, "2026-08-21");
    assert.equal(briefing.join.nextMorningOuraDay, "2026-08-22");
    assert.equal(briefing.priorNight?.sleepScore, 62);
    assert.equal(briefing.nextMorning?.sleepScore, 60);
    assert.ok(briefing.calendar.events.every((e) => e.title != null));
    assert.ok(briefing.calendar.events.every((e) => !("access_token" in e)));
    const named = briefing.calendar.events.flatMap((e) => e.attendees).find((a) => a.email === "pat@client.example");
    assert.equal(named?.name, "Pat Okonkwo");
    assert.match(briefing.summary, /meeting/i);
    assert.match(briefing.summary, /sleep 62/);
    assert.match(briefing.summary, /sleep 60/);
    assert.match(briefing.summary, /after a stressful day/);
    assert.ok(!("access_token" in briefing));
  });

  it("includes an evening ET meeting even if the stored day is the UTC date", () => {
    const late = event({
      id: "late-utc-day",
      day: "2026-09-23",
      kind: "client",
      title: "Late client call",
      start_utc: "2026-09-23T00:30:00.000Z",
      end_utc: "2026-09-23T01:00:00.000Z",
      start_local: "2026-09-23T00:30:00+00:00",
      after_hours: 0,
    });
    const briefing = buildDayBriefing({
      date: "2026-09-22",
      timeZone: TZ,
      joined: joinMeetings([late], new Map()),
      priorNight: null,
      nextMorning: null,
    });
    assert.equal(briefing.calendar.events.map((e) => e.id).join(), "late-utc-day");
  });
});

describe("GET /api/briefing/week handler", () => {
  function hr(partial: Partial<MeetingHrStress> & Pick<MeetingHrStress, "zone" | "headline" | "impact">): MeetingHrStress {
    return {
      coverage: "ok",
      method: "heartrate_proxy",
      methodNote: "note",
      sampleCount: 10,
      meanBpm: 80,
      maxBpm: 90,
      dayAwakeMeanBpm: 72,
      restingBpm: 52,
      elevatedThresholdBpm: 80,
      elevatedPct: 20,
      elevatedMinutes: 2,
      meanVsAwake: 8,
      story: "story",
      series: [],
      ...partial,
    };
  }

  it("counts zones for Mon–Sun of the selected day and names the hardest meeting", () => {
    const week = weekBoundsMonday("2026-09-22");
    assert.deepEqual(week, { start: "2026-09-21", end: "2026-09-27" });
    const mon = event({
      id: "mon",
      day: "2026-09-21",
      kind: "internal",
      title: "Standup",
      start_utc: "2026-09-21T14:00:00.000Z",
    });
    const tue = event({
      id: "tue",
      day: "2026-09-22",
      kind: "client",
      title: "Client pitch",
      start_utc: "2026-09-22T19:00:00.000Z",
    });
    const wed = event({
      id: "wed",
      day: "2026-09-23",
      kind: "internal",
      title: "1:1",
      start_utc: "2026-09-23T15:00:00.000Z",
    });
    const outside = event({
      id: "next-mon",
      day: "2026-09-28",
      kind: "client",
      title: "Next week",
      start_utc: "2026-09-28T14:00:00.000Z",
    });
    const hrByMeetingId = new Map<string, MeetingHrStress>([
      ["mon", hr({ zone: "low", headline: "Restored", impact: 1 })],
      ["tue", hr({ zone: "high", headline: "Elevated", impact: 22 })],
      ["wed", hr({ zone: "moderate", headline: "Worth watching", impact: 9 })],
    ]);
    const briefing = buildWeekBriefing({
      date: "2026-09-22",
      timeZone: TZ,
      weekStart: week.start,
      weekEnd: week.end,
      joined: joinMeetings([mon, tue, wed, outside], new Map()),
      hrByMeetingId,
    });
    assert.equal(briefing.weekDays, "monday_sunday");
    assert.equal(briefing.summary.meetingCount, 3);
    assert.equal(briefing.summary.elevated, 1);
    assert.equal(briefing.summary.watching, 1);
    assert.equal(briefing.summary.restored, 1);
    assert.equal(briefing.summary.hardest?.id, "tue");
    assert.equal(briefing.summary.hardest?.title, "Client pitch");
    assert.match(briefing.summary.line, /1 elevated/);
    assert.match(briefing.summary.line, /Highest: Client pitch/);
    assert.equal(briefing.days.length, 3);
    assert.ok(!briefing.days.some((d) => d.day === "2026-09-28"));
  });

  it("does not invent a hardest meeting when the week is empty", () => {
    const week = weekBoundsMonday("2026-09-22");
    const briefing = buildWeekBriefing({
      date: "2026-09-22",
      timeZone: TZ,
      weekStart: week.start,
      weekEnd: week.end,
      joined: [],
    });
    assert.equal(briefing.summary.meetingCount, 0);
    assert.equal(briefing.summary.hardest, null);
    assert.equal(composeWeekSummary({
      meetingCount: 0,
      elevated: 0,
      watching: 0,
      restored: 0,
      noHr: 0,
      hardest: null,
    }), "No calendar meetings this week.");
    assert.match(GRAIN_NOTE.week, /Monday–Sunday/);
  });
});

describe("composeDaySummary", () => {
  it("composes a quiet-day summary when the calendar is empty", () => {
    const text = composeDaySummary({
      date: "2026-09-22",
      calendar: {
        day: "2026-09-22",
        eventCount: 0,
        totalDurationS: 0,
        afterHoursCount: 0,
        earlyStartCount: 0,
        clientCount: 0,
        byKind: {},
      },
      priorNight: null,
      nextMorning: null,
      join: { nextMorningOuraDay: "2026-09-23" },
    });
    assert.match(text, /quiet calendar day/);
    assert.match(text, /No prior-night Oura/);
    assert.match(text, /D\+1/);
  });
});

describe("person meeting payload", () => {
  it("drops unused join fields and thins the HR series", () => {
    const series = Array.from({ length: 80 }, (_, i) => ({
      t: `2026-08-21T14:00:${String(i).padStart(2, "0")}.000Z`,
      bpm: 80,
      minutes: 0,
    }));
    const lean = toPersonMeetingJson(
      {
        id: "m1",
        title: "Discovery call",
        kind: "client",
        day: "2026-08-21",
        startUtc: "2026-08-21T13:00:00.000Z",
        endUtc: "2026-08-21T14:00:00.000Z",
        startLocal: "2026-08-21T09:00:00-04:00",
        endLocal: "2026-08-21T10:00:00-04:00",
        afterHours: false,
        earlyStart: false,
        attendeeCount: 2,
        durationS: 3600,
        ouraMorningDay: "2026-08-22",
        signals: {
          stressHighS: null,
          recoveryHighS: null,
          stressSummary: null,
          stressSource: "none",
          readinessProxy: null,
          nextSleepScore: 71,
          nextReadinessScore: 68,
          nextHrv: null,
          nextLowestHr: null,
          nextTotalSleepS: null,
        },
        score: 0.2,
        flags: [],
        hrStress: {
          coverage: "ok",
          method: "heartrate_proxy",
          methodNote: "note",
          sampleCount: 80,
          meanBpm: 80,
          maxBpm: 90,
          dayAwakeMeanBpm: 74,
          restingBpm: 52,
          elevatedThresholdBpm: 82,
          elevatedPct: 10,
          elevatedMinutes: 2,
          meanVsAwake: 6,
          zone: "moderate",
          headline: "Worth watching",
          story: "Your heart averaged about 80 beats per minute in this meeting.",
          impact: 8,
          series,
        },
        attendees: [{ email: "pat@client.example", self: false, name: "Pat Okonkwo" }],
        attendeeNote: null,
        sourceType: "calendar",
        syncReason: null,
        hasTranscript: false,
      },
      71,
      68,
    );
    assert.equal(lean.title, "Discovery call");
    assert.equal(lean.nextSleepScore, 71);
    assert.ok(!("signals" in lean));
    assert.ok(!("attendees" in lean));
    assert.ok((lean.hrStress?.series.length ?? 0) <= PERSON_SERIES_MAX);
  });
});
