import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { CalendarEventRow } from "../src/types.ts";
import type { MeetingHrStress } from "../src/lib/heartrate.ts";
import { PERSON_SERIES_MAX } from "../src/lib/heartrate.ts";
import { buildBaseline } from "../src/lib/insights.ts";
import { joinMeetings } from "../src/sources/calendar/join.ts";
import { buildDayBriefing } from "../src/sources/calendar/meetings.ts";
import { buildRangeBriefing, composeRangeSummary, type RecoveryDay } from "../src/sources/calendar/range.ts";
import { api } from "../src/routes/api.ts";

const TZ = "America/New_York";

function event(partial: Partial<CalendarEventRow> & Pick<CalendarEventRow, "id" | "day" | "kind">): CalendarEventRow {
  return {
    source: "sandbox",
    start_utc: `${partial.day}T15:00:00.000Z`,
    end_utc: `${partial.day}T16:00:00.000Z`,
    start_local: `${partial.day}T10:00:00-05:00`,
    end_local: `${partial.day}T11:00:00-05:00`,
    tz_offset_min: -300,
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

function hr(partial: Partial<MeetingHrStress> & Pick<MeetingHrStress, "zone" | "impact">): MeetingHrStress {
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
    headline: partial.zone === "high" ? "Elevated" : partial.zone === "moderate" ? "Worth watching" : "Restored",
    story: "story",
    series: [],
    ...partial,
  };
}

const EVENTS = [
  event({ id: "before", day: "2026-11-01", kind: "client", title: "Before the range" }),
  event({ id: "a1", day: "2026-11-02", kind: "client", title: "Client pitch" }),
  event({
    id: "a2",
    day: "2026-11-02",
    kind: "internal",
    title: "Late sync",
    start_utc: "2026-11-02T23:30:00.000Z",
    end_utc: "2026-11-03T00:00:00.000Z",
    start_local: "2026-11-02T18:30:00-05:00",
    end_local: "2026-11-02T19:00:00-05:00",
    duration_s: 1800,
    after_hours: 1,
  }),
  event({ id: "c1", day: "2026-11-04", kind: "internal", title: "1:1" }),
  event({ id: "c2", day: "2026-11-04", kind: "phone", title: "Phone Call: vendor" }),
  event({ id: "after", day: "2026-11-06", kind: "client", title: "After the range" }),
];

const HR = new Map<string, MeetingHrStress>([
  ["before", hr({ zone: "high", impact: 99 })],
  ["a1", hr({ zone: "high", impact: 22, meanBpm: 96 })],
  ["a2", hr({ zone: "moderate", impact: 9, meanBpm: 84 })],
  ["c1", hr({ zone: "low", impact: 1, meanBpm: 72 })],
  ["after", hr({ zone: "high", impact: 99 })],
]);

const RECOVERY = new Map<string, RecoveryDay>([
  ["2026-11-02", { sleepScore: 80, readinessScore: 75 }],
  ["2026-11-03", { sleepScore: 60, readinessScore: 62 }],
  ["2026-11-05", { sleepScore: 70, readinessScore: null }],
  // Morning after the range: feeds the last day's nextMorning, never the averages.
  ["2026-11-06", { sleepScore: 10, readinessScore: 10 }],
]);

function build(start: string, end: string) {
  return buildRangeBriefing({
    start,
    end,
    timeZone: TZ,
    joined: joinMeetings(EVENTS, new Map()),
    recoveryByDay: RECOVERY,
    hrByMeetingId: HR,
  });
}

describe("buildRangeBriefing — aggregation", () => {
  const b = build("2026-11-02", "2026-11-05");

  it("lists every day in the range, including empty ones", () => {
    assert.equal(b.spanDays, 4);
    assert.equal(b.singleDay, false);
    assert.deepEqual(
      b.days.map((d) => [d.day, d.meetingCount]),
      [
        ["2026-11-02", 2],
        ["2026-11-03", 0],
        ["2026-11-04", 2],
        ["2026-11-05", 0],
      ],
    );
  });

  it("excludes meetings outside the range", () => {
    const ids = b.days.flatMap((d) => d.meetings.map((m) => m.id));
    assert.deepEqual(ids, ["a1", "a2", "c1", "c2"]);
  });

  it("aggregates per-day load and zones", () => {
    const d = b.days[0];
    assert.equal(d.totalDurationS, 5400);
    assert.equal(d.afterHoursCount, 1);
    assert.deepEqual([d.elevated, d.watching, d.restored, d.noHr], [1, 1, 0, 0]);
    assert.equal(d.meanBpm, 90);
    assert.deepEqual(d.morning, { sleepScore: 80, readinessScore: 75 });
    assert.deepEqual(d.nextMorning, { sleepScore: 60, readinessScore: 62 });
    const wed = b.days[2];
    assert.deepEqual([wed.elevated, wed.watching, wed.restored, wed.noHr], [0, 0, 1, 1]);
    assert.equal(wed.meanBpm, 72);
    assert.equal(wed.morning, null);
    assert.equal(b.days[3].nextMorning?.sleepScore, 10);
  });

  it("sums per-meeting results across the range", () => {
    const s = b.summary;
    assert.equal(s.meetingCount, 4);
    assert.equal(s.daysWithMeetings, 2);
    assert.equal(s.totalDurationS, 3 * 3600 + 1800);
    assert.equal(s.afterHoursCount, 1);
    assert.deepEqual([s.elevated, s.watching, s.restored, s.noHr], [1, 1, 1, 1]);
    assert.deepEqual(s.byKind, { client: 1, internal: 2, phone: 1 });
    assert.equal(s.meanBpm, 84);
    assert.equal(s.hardest?.id, "a1");
    assert.match(s.line, /^4 meetings across 2 days from Nov 2 to Nov 5: 1 elevated, 1 worth watching, 1 restored\./);
    assert.match(s.line, /Highest: Client pitch on Nov 2\./);
  });

  it("averages recovery over mornings inside the range only", () => {
    assert.deepEqual(b.recovery, {
      nSleep: 3,
      nReadiness: 2,
      avgSleepScore: 70,
      avgReadinessScore: 68.5,
      lowSleepDays: 1,
      lowReadinessDays: 1,
    });
  });

  it("thins meeting HR series so a quarter of meetings stays shippable", () => {
    const series = Array.from({ length: 80 }, (_, i) => ({ t: `2026-11-02T15:${String(i % 60).padStart(2, "0")}:00Z`, bpm: 80, minutes: i }));
    const big = buildRangeBriefing({
      start: "2026-11-02",
      end: "2026-11-02",
      timeZone: TZ,
      joined: joinMeetings(EVENTS, new Map()),
      hrByMeetingId: new Map([["a1", hr({ zone: "high", impact: 22, series })]]),
    });
    assert.equal(big.days[0].meetings[0].hrStress?.series.length, PERSON_SERIES_MAX);
  });

  it("stays honest when the range is empty or has no ring HR", () => {
    const empty = build("2026-11-07", "2026-11-09");
    assert.equal(empty.summary.meetingCount, 0);
    assert.equal(empty.summary.hardest, null);
    assert.equal(empty.summary.meanBpm, null);
    assert.equal(empty.recovery.avgSleepScore, null);
    assert.equal(empty.summary.line, "No meetings from Nov 7 to Nov 9.");
    assert.match(
      composeRangeSummary({
        start: "2026-11-02",
        end: "2026-11-05",
        meetingCount: 2,
        daysWithMeetings: 1,
        elevated: 0,
        watching: 0,
        restored: 0,
        noHr: 2,
        hardest: null,
      }),
      /No ring HR in those windows/,
    );
  });
});

describe("buildRangeBriefing — single-day compatibility", () => {
  it("a one-day range matches the day briefing's meetings and scores", () => {
    const joined = joinMeetings(EVENTS, new Map());
    const range = build("2026-11-02", "2026-11-02");
    const day = buildDayBriefing({
      date: "2026-11-02",
      timeZone: TZ,
      joined,
      priorNight: null,
      nextMorning: null,
      hrByMeetingId: HR,
    });
    assert.equal(range.singleDay, true);
    assert.equal(range.spanDays, 1);
    assert.equal(range.days.length, 1);
    assert.deepEqual(
      range.days[0].meetings.map((m) => m.id).sort(),
      day.calendar.events.map((m) => m.id).sort(),
    );
    assert.equal(range.days[0].meetingCount, day.calendar.eventCount);
    assert.equal(range.days[0].totalDurationS, day.calendar.totalDurationS);
    assert.equal(range.summary.meetingCount, day.calendar.eventCount);
    assert.match(range.summary.line, /^2 meetings on Nov 2:/);
  });
});

describe("buildBaseline — explicit range", () => {
  it("describes the range instead of a rolling window, without naming a provider", () => {
    const rolling = buildBaseline([], 28);
    assert.match(rolling.note, /last 28 days/);
    const ranged = buildBaseline([], 61, { from: "2026-11-01", to: "2026-12-31" });
    assert.equal(ranged.windowDays, 61);
    assert.match(ranged.note, /Your usual from Nov 1 to Dec 31 \(61 days\)/);
    assert.doesNotMatch(ranged.note, /oura/i);
  });
});

/** D1 stand-in with no rows: enough to drive the routes end to end. */
function emptyDb(): D1Database {
  const stmt = {
    bind: () => stmt,
    all: async () => ({ results: [] }),
    first: async () => null,
    run: async () => ({ success: true }),
  };
  return { prepare: () => stmt } as unknown as D1Database;
}

async function get(path: string): Promise<{ status: number; body: Record<string, any> }> {
  const res = await api.request(path, {}, { DB: emptyDb() } as never);
  return { status: res.status, body: (await res.json()) as Record<string, any> };
}

describe("date-scoped routes", () => {
  it("reject invalid ranges with a clear 400", async () => {
    const cases: Array<[string, RegExp]> = [
      ["/briefing/range?start=2026-11-10&end=2026-11-01", /end must be on or after start/],
      ["/briefing/range?start=2026-01-01&end=2026-12-31", /range cannot exceed 92 days \(got 365\)/],
      ["/briefing/range?start=garbage&end=2026-11-01", /start must be a valid YYYY-MM-DD date/],
      ["/briefing/day?date=2026-02-30", /date must be a valid YYYY-MM-DD date/],
      ["/briefing/day?start=2026-11-10&end=2026-11-01", /end must be on or after start/],
      ["/briefing/day?date=2026-11-05&end=2026-11-06", /either date or start\/end/],
      ["/briefing/week?date=2026-13-40", /date must be a valid YYYY-MM-DD date/],
      ["/insights/hits?start=2026-01-01&end=2026-12-31", /range cannot exceed 92 days/],
      ["/insights/hits?start=2026-11-10&end=2026-11-01", /end must be on or after start/],
      ["/meetings/stressed?from=2026-11-10&to=2026-11-01", /end must be on or after start/],
      ["/meetings/stressed?start=2026-01-01&end=2026-12-31", /range cannot exceed 92 days/],
      ["/meetings/sleep-impact?from=nope", /start must be a valid YYYY-MM-DD date/],
      ["/people/a%40example.com/meetings?start=2026-11-10&end=2026-11-01", /end must be on or after start/],
    ];
    for (const [path, message] of cases) {
      const { status, body } = await get(path);
      assert.equal(status, 400, path);
      assert.match(body.error, message, path);
    }
  });

  it("keep single-day calls working: date, and start = end, give the day briefing", async () => {
    const legacy = await get("/briefing/day?date=2026-11-05");
    const asRange = await get("/briefing/day?start=2026-11-05&end=2026-11-05");
    assert.equal(legacy.status, 200);
    assert.equal(legacy.body.date, "2026-11-05");
    assert.ok(legacy.body.calendar, "day briefing shape");
    assert.deepEqual(asRange.body, legacy.body);
  });

  it("aggregate a span on /briefing/range, and on /briefing/day when it is multi-day", async () => {
    const range = await get("/briefing/range?start=2026-11-01&end=2026-12-31");
    assert.equal(range.status, 200);
    assert.equal(range.body.spanDays, 61);
    assert.equal(range.body.days.length, 61);
    assert.equal(range.body.days[0].day, "2026-11-01");
    assert.equal(range.body.days[60].day, "2026-12-31");
    const viaDay = await get("/briefing/day?start=2026-11-01&end=2026-12-31");
    assert.deepEqual(viaDay.body, range.body);
    const oneDay = await get("/briefing/range?date=2026-11-05");
    assert.equal(oneDay.body.singleDay, true);
    assert.equal(oneDay.body.days.length, 1);
  });

  it("scope hits and person history to start/end, and keep the rolling default", async () => {
    const hits = await get("/insights/hits?start=2026-11-01&end=2026-11-30");
    assert.equal(hits.status, 200);
    assert.deepEqual([hits.body.from, hits.body.to], ["2026-11-01", "2026-11-30"]);
    assert.equal(hits.body.baseline.windowDays, 30);
    const rolling = await get("/insights/hits?days=28");
    assert.equal(rolling.body.baseline.windowDays, 28);
    const person = await get("/people/a%40example.com/meetings?start=2026-11-01&end=2026-11-30");
    assert.deepEqual([person.body.from, person.body.to], ["2026-11-01", "2026-11-30"]);
  });
});
