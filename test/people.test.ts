import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  extractAttendees,
  normalizeEmail,
  normalizePersonName,
  parseAttendeesJson,
  pickPersonName,
  summarizePerson,
} from "../src/lib/people.ts";
import { noHrCoverage, type MeetingHrStress } from "../src/lib/heartrate.ts";

function hr(partial: Partial<MeetingHrStress> & Pick<MeetingHrStress, "zone" | "headline">): MeetingHrStress {
  return {
    coverage: "ok",
    method: "heartrate_proxy",
    methodNote: "This uses heart-rate from your ring during the meeting. It is not Oura's daytime stress score.",
    sampleCount: 10,
    meanBpm: 90,
    maxBpm: 100,
    dayAwakeMeanBpm: 74,
    restingBpm: 52,
    elevatedThresholdBpm: 82,
    elevatedPct: 60,
    elevatedMinutes: 20,
    meanVsAwake: 16,
    story: "Your heart averaged about 90 beats per minute in this meeting.",
    impact: 20,
    series: [],
    ...partial,
  };
}

describe("attendee emails", () => {
  it("keeps others and drops junk", () => {
    const list = extractAttendees({
      attendees: [
        { email: "you@example.com", self: true },
        { email: "Pat@Client.example" },
        { email: "noreply@google.com" },
        { email: "not-an-email" },
      ],
    });
    assert.deepEqual(
      list.map((a) => a.email),
      ["you@example.com", "pat@client.example"],
    );
    assert.equal(list[0].self, true);
    assert.equal(list[0].name, null);
    assert.equal(normalizeEmail("  Ada@Other.EXAMPLE "), "ada@other.example");
  });

  it("keeps Google displayName and skips conference rooms", () => {
    const list = extractAttendees({
      attendees: [
        { email: "you@example.com", self: true, displayName: "You" },
        { email: "dana.sample@lender.example", displayName: "Dana Sample" },
        { email: "room@example.com", displayName: "Boardroom", resource: true },
        { email: "no-name@client.example" },
      ],
    });
    assert.deepEqual(
      list.map((a) => ({ email: a.email, name: a.name })),
      [
        { email: "you@example.com", name: "You" },
        { email: "dana.sample@lender.example", name: "Dana Sample" },
        { email: "no-name@client.example", name: null },
      ],
    );
  });

  it("does not invent a name from an email", () => {
    assert.equal(normalizePersonName("dana.sample@lender.example"), null);
    assert.equal(normalizePersonName("  "), null);
    assert.equal(normalizePersonName("Dana Sample"), "Dana Sample");
    const parsed = parseAttendeesJson(
      JSON.stringify([{ email: "pat@client.example", self: false, name: "Pat Okonkwo" }]),
    );
    assert.equal(parsed[0].name, "Pat Okonkwo");
    assert.equal(
      pickPersonName("pat@client.example", [[{ email: "pat@client.example", self: false, name: "Pat Okonkwo" }]]),
      "Pat Okonkwo",
    );
    assert.equal(pickPersonName("pat@client.example", [[{ email: "pat@client.example", self: false, name: null }]]), null);
  });
});

describe("person trend", () => {
  it("badges someone who repeatedly lands Elevated", () => {
    const trend = summarizePerson([
      { hrStress: hr({ zone: "high", headline: "Elevated", meanBpm: 96 }) },
      { hrStress: hr({ zone: "high", headline: "Elevated", meanBpm: 92 }) },
      { hrStress: hr({ zone: "low", headline: "Restored", meanBpm: 70 }) },
    ]);
    assert.equal(trend.badge, "often spikes you");
    assert.equal(trend.elevated, 2);
    assert.equal(trend.spark.length, 3);
    assert.ok(trend.medianAvgBpm != null);
  });

  it("ignores missing coverage when badging", () => {
    const trend = summarizePerson([
      { hrStress: noHrCoverage() },
      { hrStress: hr({ zone: "low", headline: "Restored", meanBpm: 71 }) },
    ]);
    assert.equal(trend.badge, null);
    assert.equal(trend.missingHr, 1);
    assert.equal(trend.withCoverage, 1);
  });

  it("marks usually restored when covered meetings stay calm", () => {
    const trend = summarizePerson([
      { hrStress: hr({ zone: "low", headline: "Restored", meanBpm: 70 }) },
      { hrStress: hr({ zone: "low", headline: "Restored", meanBpm: 72 }) },
      { hrStress: hr({ zone: "low", headline: "Restored", meanBpm: 68 }) },
    ]);
    assert.equal(trend.badge, "usually restored");
  });
});
