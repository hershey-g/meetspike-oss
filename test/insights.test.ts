import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { DailyMetricPoint } from "../src/lib/daily-metrics.ts";
import {
  badgeFor,
  buildBaseline,
  composeHitSentence,
  dayCompare,
  median,
  meetingsThatMatter,
  parseInsightsDays,
  pickNotableMeeting,
  fallbackHitTitle,
  rankHits,
  type InsightMeeting,
} from "../src/lib/insights.ts";
import { scoreMeetingHr, type HrSample } from "../src/lib/heartrate.ts";

function day(partial: Partial<DailyMetricPoint> & Pick<DailyMetricPoint, "day">): DailyMetricPoint {
  return {
    sleepScore: 76,
    readinessScore: 72,
    activityScore: 70,
    steps: 8000,
    stressHighS: 3600,
    recoveryHighS: 8000,
    stressSummary: "normal",
    avgHrv: 40,
    lowestHr: 50,
    totalSleepS: 25000,
    ...partial,
  };
}

function meeting(partial: Partial<InsightMeeting> & Pick<InsightMeeting, "id" | "day">): InsightMeeting {
  return {
    title: partial.title ?? "Catch up",
    kind: partial.kind ?? "internal",
    startLocal: partial.startLocal ?? `${partial.day}T10:00:00-04:00`,
    afterHours: false,
    earlyStart: false,
    durationS: 3600,
    attendees: partial.attendees ?? [],
    attendeeNote: partial.attendeeNote ?? null,
    sourceType: partial.sourceType ?? "calendar",
    ...partial,
  };
}

describe("median and window", () => {
  it("returns the middle value and averages an even pair", () => {
    assert.equal(median([80, 70, 76]), 76);
    assert.equal(median([70, 80]), 75);
    assert.equal(median([]), null);
  });

  it("clamps the insights window", () => {
    assert.equal(parseInsightsDays(undefined), 28);
    assert.equal(parseInsightsDays("3"), 7);
    assert.equal(parseInsightsDays("90"), 90);
    assert.equal(parseInsightsDays("730"), 730);
  });
});

describe("rankHits vs personal median", () => {
  it("keeps only days worse than his median and titles the notable meeting", () => {
    const days = [
      day({ day: "2026-09-01", sleepScore: 76, readinessScore: 72, stressHighS: 3600 }),
      day({ day: "2026-09-02", sleepScore: 76, readinessScore: 72, stressHighS: 3600 }),
      day({ day: "2026-09-20", sleepScore: 78, readinessScore: 74, stressHighS: 3000 }),
      day({ day: "2026-09-21", sleepScore: 74, readinessScore: 70, stressHighS: 11000 }),
      day({ day: "2026-09-22", sleepScore: 60, readinessScore: 54, stressHighS: 4000 }),
    ];
    const baseline = buildBaseline(days, 28);
    assert.ok(baseline.sleepScore != null);
    assert.ok(baseline.readinessScore != null);

    const hits = rankHits({
      days,
      meetings: [
        meeting({
          id: "late",
          day: "2026-09-21",
          title: "Client pitch — Acme",
          kind: "client",
          afterHours: true,
          startLocal: "2026-09-21T18:00:00-04:00",
        }),
        meeting({ id: "quiet", day: "2026-09-21", title: "Invoice", kind: "admin" }),
        meeting({ id: "stand", day: "2026-09-20", title: "Stand-up" }),
      ],
      baseline,
      from: "2026-09-20",
      to: "2026-09-21",
      limit: 8,
    });

    assert.equal(hits.length, 1);
    assert.equal(hits[0].id, "late");
    assert.equal(hits[0].title, "Client pitch — Acme");
    assert.equal(hits[0].badge, "worse than usual");
    assert.match(hits[0].sentence, /readiness/i);
    assert.match(hits[0].sentence, /below your median/);
    assert.ok(hits[0].compare.some((c) => c.key === "nextSleep" && c.worse));
    assert.ok(hits[0].impact > 0);
  });

  it("ranks a larger readiness drop above a milder one", () => {
    const days = [
      day({ day: "2026-09-10", sleepScore: 76, readinessScore: 72, stressHighS: 3600 }),
      day({ day: "2026-09-11", sleepScore: 70, readinessScore: 50, stressHighS: 3600 }),
      day({ day: "2026-09-12", sleepScore: 70, readinessScore: 64, stressHighS: 3600 }),
    ];
    const baseline = buildBaseline(
      [
        ...days,
        day({ day: "2026-09-01", sleepScore: 76, readinessScore: 72 }),
        day({ day: "2026-09-02", sleepScore: 76, readinessScore: 72 }),
      ],
      28,
    );
    const hits = rankHits({
      days,
      meetings: [
        meeting({ id: "bad", day: "2026-09-10", title: "Board" }),
        meeting({ id: "mild", day: "2026-09-11", title: "1:1" }),
      ],
      baseline,
      from: "2026-09-10",
      to: "2026-09-11",
    });
    assert.equal(hits[0].id, "bad");
    assert.ok(hits[0].impact > hits[1].impact);
  });

  it("skips a typical day even if a client meeting happened", () => {
    const days = [
      day({ day: "2026-09-08", sleepScore: 76, readinessScore: 72, stressHighS: 3600 }),
      day({ day: "2026-09-09", sleepScore: 77, readinessScore: 73, stressHighS: 3500 }),
    ];
    const hits = rankHits({
      days,
      meetings: [meeting({ id: "client", day: "2026-09-08", title: "Pitch", kind: "client" })],
      baseline: buildBaseline(days, 14),
      from: "2026-09-08",
      to: "2026-09-08",
    });
    assert.equal(hits.length, 0);
  });

  it("titles a recovery day with no meetings in plain English", () => {
    const days = [
      day({ day: "2026-09-01", sleepScore: 76, readinessScore: 72, stressHighS: 3600 }),
      day({ day: "2026-09-02", sleepScore: 76, readinessScore: 72, stressHighS: 3600 }),
      day({ day: "2026-09-20", sleepScore: 78, readinessScore: 74, stressHighS: 3000 }),
      day({ day: "2026-09-21", sleepScore: 58, readinessScore: 50, stressHighS: 4000 }),
    ];
    const hits = rankHits({
      days,
      meetings: [],
      baseline: buildBaseline(days, 14),
      from: "2026-09-20",
      to: "2026-09-20",
    });
    assert.equal(hits.length, 1);
    assert.equal(hits[0].title, "Quiet calendar — still a hard recovery day");
    assert.doesNotMatch(hits[0].title, /thin night|heavy calendar/i);
  });

  it("uses a date-based title when meetings have no names", () => {
    const days = [
      day({ day: "2026-09-01", sleepScore: 76, readinessScore: 72, stressHighS: 3600 }),
      day({ day: "2026-09-20", sleepScore: 78, readinessScore: 74, stressHighS: 3000 }),
      day({ day: "2026-09-21", sleepScore: 58, readinessScore: 50, stressHighS: 4000 }),
    ];
    const hits = rankHits({
      days,
      meetings: [meeting({ id: "x", day: "2026-09-20", title: "   " })],
      baseline: buildBaseline(days, 14),
      from: "2026-09-20",
      to: "2026-09-20",
    });
    assert.equal(hits[0].title, "Meetings on Sep 20");
    assert.doesNotMatch(JSON.stringify(hits), /thin night|heavy calendar/i);
  });

  it("ranks the meeting with elevated in-window HR first", () => {
    const days = [
      day({ day: "2026-09-20", sleepScore: 76, readinessScore: 72, stressHighS: 3600 }),
      day({ day: "2026-09-21", sleepScore: 76, readinessScore: 72, stressHighS: 3600 }),
    ];
    const spike: HrSample[] = [];
    const calm: HrSample[] = [];
    const daySamples: HrSample[] = [];
    for (let m = 0; m < 60; m += 5) {
      const mm = String(m).padStart(2, "0");
      spike.push({
        bpm: 98,
        timestamp: `2026-09-21T10:${mm}:00-04:00`,
        timestampMs: Date.parse(`2026-09-21T10:${mm}:00-04:00`),
        source: "awake",
      });
      calm.push({
        bpm: 70,
        timestamp: `2026-09-21T14:${mm}:00-04:00`,
        timestampMs: Date.parse(`2026-09-21T14:${mm}:00-04:00`),
        source: "awake",
      });
    }
    for (let h = 8; h < 17; h++) {
      daySamples.push({
        bpm: h === 10 ? 98 : 70,
        timestamp: `2026-09-21T${String(h).padStart(2, "0")}:00:00-04:00`,
        timestampMs: Date.parse(`2026-09-21T${String(h).padStart(2, "0")}:00:00-04:00`),
        source: "awake",
      });
    }
    const hrByMeetingId = new Map([
      ["pitch", scoreMeetingHr(spike, [...daySamples, ...spike, ...calm], 52)],
      ["stand", scoreMeetingHr(calm, [...daySamples, ...spike, ...calm], 52)],
    ]);
    const hits = rankHits({
      days,
      meetings: [
        meeting({ id: "pitch", day: "2026-09-21", title: "Client pitch" }),
        meeting({ id: "stand", day: "2026-09-21", title: "Stand-up" }),
      ],
      baseline: buildBaseline(days, 14),
      from: "2026-09-21",
      to: "2026-09-21",
      hrByMeetingId,
    });
    assert.ok(hits.length >= 1);
    assert.equal(hits[0].id, "pitch");
    assert.equal(hits[0].hrStress?.headline, "Elevated");
    assert.match(hits[0].sentence, /Elevated/);
    assert.match(hits[0].sentence, /beats per minute/i);
    assert.doesNotMatch(hits[0].sentence, /\bmean\b/i);
  });
});

describe("plain insight titles", () => {
  it("never returns the old cute copy", () => {
    assert.equal(fallbackHitTitle([], "2026-09-21", true), "Quiet calendar — still a hard recovery day");
    assert.equal(fallbackHitTitle([], "2026-09-21", false), "No calendar meeting that day");
    assert.equal(
      fallbackHitTitle([{ ...meeting({ id: "a", day: "2026-09-21" }), title: null }], "2026-09-21", true),
      "Meetings on Sep 21",
    );
    const blob = `${fallbackHitTitle([], "2026-09-21", true)} ${fallbackHitTitle([meeting({ id: "a", day: "2026-09-21", title: "  " })], "2026-09-21", true)}`;
    assert.doesNotMatch(blob, /thin night|heavy calendar/i);
  });
});

describe("copy and meeting pick", () => {
  it("prefers after-hours over a longer midday block", () => {
    const pick = pickNotableMeeting([
      meeting({ id: "long", day: "2026-09-21", title: "Workshop", durationS: 7200 }),
      meeting({
        id: "late",
        day: "2026-09-21",
        title: "Acme",
        afterHours: true,
        durationS: 1800,
      }),
    ]);
    assert.equal(pick?.id, "late");
  });

  it("limits briefing meetings to late/early/client, else the longest", () => {
    const matter = meetingsThatMatter([
      meeting({ id: "a", day: "d", title: "Staff", durationS: 900 }),
      meeting({ id: "b", day: "d", title: "Deep work", kind: "deep_work", durationS: 7200 }),
    ]);
    assert.equal(matter[0].id, "b");
    assert.equal(matter.length, 2);
  });

  it("writes a one-line hit sentence from worse axes only", () => {
    const baseline = buildBaseline(
      [
        day({ day: "2026-09-01", sleepScore: 76, readinessScore: 72, stressHighS: 3600 }),
        day({ day: "2026-09-02", sleepScore: 76, readinessScore: 72, stressHighS: 3600 }),
      ],
      14,
    );
    const compare = dayCompare(
      day({ day: "2026-09-21", stressHighS: 11000 }),
      day({ day: "2026-09-22", sleepScore: 60, readinessScore: 54 }),
      baseline,
    );
    const sentence = composeHitSentence(compare);
    assert.match(sentence, /sleep 16 below your median/i);
    assert.match(sentence, /readiness/i);
    assert.match(sentence, /stress/i);
    assert.equal(badgeFor(compare), "worse than usual");
  });
});
