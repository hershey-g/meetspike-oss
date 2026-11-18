import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { classifyPlaudTitle, cleanPlaudTitle } from "../src/sources/plaud/classify.ts";
import { planPlaudIngest, plaudInstantToUtc, projectPlaudRecording } from "../src/sources/plaud/project.ts";
import { matchesSourceFilter, parseSourceFilter } from "../src/lib/source-type.ts";
import { timingSafeEqual, readAdminSecret } from "../src/lib/secret.ts";

const TZ = "America/New_York";
const NOW = "2026-09-22T16:00:00.000Z";

describe("classifyPlaudTitle", () => {
  it("matches Phone Call: as plaud_phone", () => {
    const m = classifyPlaudTitle("Phone Call: Schedule Delay");
    assert.equal(m?.sourceType, "plaud_phone");
    assert.equal(m?.syncReason, "phone_title");
    assert.equal(m?.kind, "phone");
  });

  it("matches [meetspike] case-insensitively as plaud_tagged", () => {
    const m = classifyPlaudTitle("Board prep [Meetspike]");
    assert.equal(m?.sourceType, "plaud_tagged");
    assert.equal(m?.syncReason, "tag");
  });

  it("sets both when Phone Call: also has [meetspike]", () => {
    const m = classifyPlaudTitle("Phone Call: Alex [meetspike]");
    assert.equal(m?.sourceType, "plaud_both");
    assert.equal(m?.syncReason, "phone_title,tag");
  });

  it("does not match ordinary titles", () => {
    assert.equal(classifyPlaudTitle("Team standup"), null);
    assert.equal(classifyPlaudTitle("phone call later"), null);
  });

  it("trims and caps titles", () => {
    assert.equal(cleanPlaudTitle("  Phone   Call:  A  "), "Phone Call: A");
    assert.equal(cleanPlaudTitle("x".repeat(300)).length, 240);
  });
});

describe("projectPlaudRecording", () => {
  it("projects a Phone Call window and ignores transcript fields", () => {
    const result = projectPlaudRecording(
      {
        plaud_file_id: "of_00000000000000000000000000000001",
        title: "Phone Call: Schedule delay for Thursday meeting",
        start_at: "2026-09-16T14:18:50",
        duration_ms: 66000,
        has_transcript: true,
        transcript: "DO NOT STORE",
        presigned_url: "https://secret.example/audio",
      },
      { timeZone: TZ, now: NOW },
    );
    if (result.status !== "accept") throw new Error("expected accept");
    assert.equal(result.row.source, "plaud");
    assert.equal(result.row.source_type, "plaud_phone");
    assert.equal(result.row.plaud_file_id, "of_00000000000000000000000000000001");
    assert.equal(result.row.has_transcript, 1);
    assert.equal(result.row.day, "2026-09-16");
    assert.equal(result.row.duration_s, 66);
    assert.ok(!JSON.stringify(result.row).includes("DO NOT STORE"));
    assert.ok(!JSON.stringify(result.row).includes("secret.example"));
  });

  it("rejects titles that are not Phone Call: or [meetspike]", () => {
    const result = projectPlaudRecording(
      {
        plaud_file_id: "of_skip",
        title: "Grocery list",
        start_at: "2026-09-16T14:18:50Z",
        duration_ms: 60000,
      },
      { timeZone: TZ, now: NOW },
    );
    assert.equal(result.status, "rejected");
    if (result.status === "rejected") assert.equal(result.reason, "no_match");
  });

  it("accepts UTC instants and duration as Plaud `duration` milliseconds", () => {
    const result = projectPlaudRecording(
      {
        plaud_file_id: "of_utc",
        title: "Notes [meetspike]",
        start_at: "2026-09-16T18:18:50.000Z",
        duration: 120000,
      },
      { timeZone: TZ, now: NOW },
    );
    if (result.status !== "accept") throw new Error("expected accept");
    assert.equal(result.row.source_type, "plaud_tagged");
    assert.equal(result.row.end_utc, "2026-09-16T18:20:50.000Z");
  });
});

describe("planPlaudIngest", () => {
  it("accepts a backfill batch and rejects the rest", () => {
    const planned = planPlaudIngest(
      {
        recordings: [
          {
            plaud_file_id: "of_a",
            title: "Phone Call: A",
            start_at: "2026-09-16T18:00:00.000Z",
            duration_ms: 60000,
          },
          {
            plaud_file_id: "of_b",
            title: "Standup",
            start_at: "2026-09-16T19:00:00.000Z",
            duration_ms: 60000,
          },
        ],
      },
      { timeZone: TZ, now: NOW },
    );
    assert.equal(planned.accept.length, 1);
    assert.equal(planned.reject.length, 1);
    assert.equal(planned.reject[0].reason, "no_match");
  });

  it("reads a single recording object", () => {
    const planned = planPlaudIngest(
      {
        plaud_file_id: "of_one",
        title: "Phone Call: Solo",
        start_at: "2026-09-16T18:00:00.000Z",
        end_at: "2026-09-16T18:10:00.000Z",
      },
      { timeZone: TZ, now: NOW },
    );
    assert.equal(planned.accept.length, 1);
    assert.equal(planned.accept[0].duration_s, 600);
  });
});

describe("source filter", () => {
  it("puts plaud_both in Phone and Tagged", () => {
    assert.equal(matchesSourceFilter("plaud_both", "phone"), true);
    assert.equal(matchesSourceFilter("plaud_both", "tagged"), true);
    assert.equal(matchesSourceFilter("plaud_both", "calendar"), false);
    assert.equal(matchesSourceFilter("calendar", "phone"), false);
    assert.equal(parseSourceFilter("phone"), "phone");
    assert.equal(parseSourceFilter("nope"), "all");
  });
});

describe("admin secret", () => {
  it("reads x-admin-secret or Bearer and compares in constant time", () => {
    assert.equal(readAdminSecret("abc", "Bearer other"), "abc");
    assert.equal(readAdminSecret(undefined, "Bearer tok"), "tok");
    assert.equal(timingSafeEqual("secret", "secret"), true);
    assert.equal(timingSafeEqual("secret", "secreT"), false);
    assert.equal(timingSafeEqual("a", "ab"), false);
  });
});

describe("plaudInstantToUtc", () => {
  it("treats naive Plaud start_at as America/New_York", () => {
    assert.equal(plaudInstantToUtc("2026-09-16T14:18:50", TZ), "2026-09-16T18:18:50.000Z");
    assert.equal(plaudInstantToUtc("2026-09-16T18:18:50.000Z", TZ), "2026-09-16T18:18:50.000Z");
  });
});
