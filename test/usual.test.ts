import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  buildDayRows,
  buildUsual,
  costliestDays,
  heavyEffect,
  isHeavy,
  median,
  peopleOnHeavyDays,
  type DayRow,
} from "../src/lib/usual.ts";
import type { OuraDaySlice } from "../src/sources/calendar/join.ts";
import type { CalendarEventRow } from "../src/types.ts";

const TZ = "America/New_York";

function slice(day: string, readiness: number | null, extra: Partial<OuraDaySlice> = {}): OuraDaySlice {
  return {
    day,
    sleepScore: 80,
    readinessScore: readiness,
    avgHrv: 40,
    lowestHr: 58,
    totalSleepS: 28000,
    stressHighS: null,
    recoveryHighS: null,
    stressSummary: null,
    strain: 8,
    ...extra,
  };
}

function event(id: string, startUtc: string, minutes: number, attendees: Array<[string, string | null]> = []): CalendarEventRow {
  const end = new Date(Date.parse(startUtc) + minutes * 60_000).toISOString();
  return {
    id,
    source: "google",
    day: startUtc.slice(0, 10),
    start_utc: startUtc,
    end_utc: end,
    start_local: null,
    end_local: null,
    tz_offset_min: -300,
    duration_s: minutes * 60,
    title: id,
    kind: "client",
    client_key: null,
    project_key: null,
    attendee_count: attendees.length,
    attendees_json: JSON.stringify(attendees.map(([email, name]) => ({ email, displayName: name ?? undefined }))),
    after_hours: 0,
    location: null,
  } as CalendarEventRow;
}

function row(day: string, hours: number, count: number, nextReadiness: number | null, people: DayRow["people"] = []): DayRow {
  return {
    day,
    weekday: true,
    meetingCount: count,
    meetingS: hours * 3600,
    afterHours: 0,
    morning: null,
    next: nextReadiness == null ? null : { sleepScore: 75, readinessScore: nextReadiness, avgHrv: null, lowestHr: null },
    people,
  };
}

describe("usual numbers", () => {
  it("median handles even, odd, empty and nulls", () => {
    assert.equal(median([3, 1, 2]), 2);
    assert.equal(median([4, 1, 3, 2]), 2.5);
    assert.equal(median([null, undefined]), null);
  });

  it("heavy means 4+ hours or 5+ meetings", () => {
    assert.equal(isHeavy({ meetingS: 4 * 3600, meetingCount: 1 }), true);
    assert.equal(isHeavy({ meetingS: 3600, meetingCount: 5 }), true);
    assert.equal(isHeavy({ meetingS: 3 * 3600, meetingCount: 4 }), false);
  });

  it("builds one row per day, counts meetings by local day, attaches mornings and people", () => {
    const byDay = new Map([
      ["2026-11-16", slice("2026-11-16", 70)],
      ["2026-11-17", slice("2026-11-17", 55)],
    ]);
    const events = [
      // 9 pm Monday in New York is 02:00 UTC Tuesday: still Monday's meeting.
      event("late", "2026-11-17T02:00:00.000Z", 60, [["sam@x.com", "Sam"]]),
      event("am", "2026-11-16T14:00:00.000Z", 30, [["sam@x.com", null], ["me@x.com", "Me"]]),
      event("am", "2026-11-16T14:00:00.000Z", 30),
    ];
    const rows = buildDayRows(events, byDay, "2026-11-15", "2026-11-17", TZ);
    assert.deepEqual(rows.map((r) => r.day), ["2026-11-15", "2026-11-16", "2026-11-17"]);
    const mon = rows[1];
    assert.equal(mon.meetingCount, 2, "duplicate ids count once");
    assert.equal(mon.meetingS, 90 * 60);
    assert.equal(mon.morning?.readinessScore, 70);
    assert.equal(mon.next?.readinessScore, 55);
    assert.equal(mon.weekday, true);
    assert.equal(rows[0].weekday, false);
    const sam = mon.people.find((p) => p.email === "sam@x.com");
    assert.equal(sam?.meetings, 2);
    assert.equal(sam?.name, "Sam");
  });

  it("usual takes medians, and meeting hours from weekdays only", () => {
    const rows = [row("2026-11-16", 2, 2, 70), row("2026-11-17", 4, 5, 50), row("2026-11-18", 6, 6, 60)];
    rows[0].morning = { sleepScore: 90, readinessScore: 80, avgHrv: 50, lowestHr: 55, strain: 10 };
    rows[1].morning = { sleepScore: 70, readinessScore: 60, avgHrv: 30, lowestHr: 61, strain: 6 };
    const weekend = { ...row("2026-11-21", 9, 9, 40), weekday: false };
    const u = buildUsual([...rows, weekend]);
    assert.equal(u.recovery, 70);
    assert.equal(u.sleep, 80);
    assert.equal(u.hrv, 40);
    assert.equal(u.restingHr, 58);
    assert.equal(u.strain, 8);
    assert.equal(u.meetingHours, 4, "weekend 9 h ignored");
  });

  it("heavy effect compares next-morning recovery after heavy days with the rest", () => {
    const e = heavyEffect([row("a", 5, 3, 50), row("b", 1, 6, 54), row("c", 1, 1, 80), row("d", 2, 2, 74), row("e", 6, 6, null)]);
    assert.deepEqual(e.heavy, { days: 2, nextRecovery: 52 });
    assert.deepEqual(e.lighter, { days: 2, nextRecovery: 77 });
    assert.equal(e.cost, 25);
    assert.equal(heavyEffect([row("a", 1, 1, 70)]).cost, null, "no heavy days, no cost");
  });

  it("costliest days are meeting days with the lowest next-morning recovery", () => {
    const days = costliestDays([row("a", 5, 3, 50), row("b", 0, 0, 30), row("c", 2, 2, 49), row("d", 3, 3, 80)], 2);
    assert.deepEqual(days.map((d) => d.day), ["c", "a"]);
    assert.equal(days[0].meetingHours, 2);
  });

  it("people on heavy days are ranked by heavy days, then meetings", () => {
    const sam = { email: "sam@x.com", name: "Sam", meetings: 2 };
    const dana = { email: "dana@x.com", name: null, meetings: 3 };
    const people = peopleOnHeavyDays([
      row("a", 5, 5, 50, [sam, dana]),
      row("b", 6, 6, 50, [sam]),
      row("c", 1, 1, 80, [dana, dana]),
    ]);
    assert.deepEqual(people.map((p) => [p.email, p.heavyDays, p.meetings]), [["sam@x.com", 2, 4], ["dana@x.com", 1, 3]]);
  });
});
