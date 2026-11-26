import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import {
  cacheNames,
  collectUnnamedEmails,
  fillNames,
  loadNameLookup,
  matchSpeakersToAttendees,
  parseSpeakers,
  resolveName,
  resolvePayloadNames,
  type NameLookup,
} from "../src/lib/person-names.ts";
import { extractPlaudSpeakers } from "../src/sources/plaud/project.ts";
import type { Attendee } from "../src/lib/people.ts";
import { GOOGLE_SCOPES } from "../src/sources/calendar/endpoints.ts";

function lookup(partial: Partial<NameLookup> = {}): NameLookup {
  return { calendar: new Map(), cached: new Map(), ...partial };
}

describe("name resolution order", () => {
  const L = lookup({
    calendar: new Map([["pat@client.example", "Pat Lee"]]),
    cached: new Map([
      ["pat@client.example", { name: "Pat (plaud)", source: "plaud" as const }],
      ["sam@client.example", { name: "Sam Okafor", source: "calendar" as const }],
      ["jo@client.example", { name: "Jo Park", source: "plaud" as const }],
    ]),
  });

  it("a. the meeting's own displayName wins", () => {
    assert.equal(resolveName("pat@client.example", "Patricia Lee", L), "Patricia Lee");
  });
  it("b. then the name that email had on another stored meeting", () => {
    assert.equal(resolveName("PAT@client.example", null, L), "Pat Lee");
    assert.equal(resolveName("sam@client.example", null, L), "Sam Okafor");
  });
  it("d. then a cleanly-mapped Plaud speaker name", () => {
    assert.equal(resolveName("jo@client.example", null, L), "Jo Park");
  });
  it("e. otherwise nothing — the UI shows the email address", () => {
    assert.equal(resolveName("nobody@client.example", null, L), null);
    assert.equal(resolveName("nobody@client.example", "  ", L), null);
  });
  it("c. contacts lookup is not attempted: calendar.readonly is the only scope", () => {
    assert.deepEqual([...GOOGLE_SCOPES], ["https://www.googleapis.com/auth/calendar.readonly"]);
  });
});

describe("filling names into API payloads", () => {
  const payload = () => ({
    email: "pat@client.example",
    name: null,
    meetings: [
      { title: "Sync", attendees: [{ email: "sam@client.example", self: false, name: null }, { email: "ann@x.example", name: "Ann" }] },
    ],
    people: [{ email: "jo@client.example", name: null, heavyDays: 2 }],
    // Not a person slot: no `name` key, so it is left alone.
    status: { email: "ops@x.example" },
  });

  it("collects only emails sitting next to an empty name", () => {
    assert.deepEqual([...collectUnnamedEmails(payload())].sort(), [
      "jo@client.example",
      "pat@client.example",
      "sam@client.example",
    ]);
  });

  it("fills them and never overwrites a name that is there", () => {
    const p = payload();
    const n = fillNames(p, new Map([
      ["pat@client.example", "Pat Lee"],
      ["sam@client.example", "Sam Okafor"],
      ["ann@x.example", "Wrong"],
    ]));
    assert.equal(n, 2);
    assert.equal(p.name, "Pat Lee");
    assert.equal(p.meetings[0].attendees[0].name, "Sam Okafor");
    assert.equal(p.meetings[0].attendees[1].name, "Ann");
    assert.equal(p.people[0].name, null);
    assert.equal("name" in p.status, false);
  });
});

function namesDb(opts: { attendees?: Array<{ email: string; display_name: string }>; cache?: Array<{ email: string; name: string; source: string }> | "missing" }) {
  const writes: unknown[][] = [];
  const db = {
    prepare(sql: string) {
      let args: unknown[] = [];
      const stmt = {
        sql,
        bind: (...a: unknown[]) => ((args = a), stmt),
        args: () => args,
        all: async () => {
          if (/FROM calendar_attendee/.test(sql)) {
            return { results: (opts.attendees ?? []).filter((r) => args.includes(r.email)) };
          }
          if (/FROM person_name/.test(sql)) {
            if (opts.cache === "missing") throw new Error("D1_ERROR: no such table: person_name");
            return { results: (opts.cache ?? []).filter((r) => args.includes(r.email)) };
          }
          return { results: [] };
        },
      };
      return stmt;
    },
    async batch(stmts: Array<{ sql: string; args: () => unknown[] }>) {
      if (opts.cache === "missing") throw new Error("D1_ERROR: no such table: person_name");
      for (const s of stmts) writes.push([/'plaud'/.test(s.sql) ? "plaud" : "calendar", ...s.args()]);
      return [];
    },
  };
  return { db: db as unknown as D1Database, writes };
}

describe("loading and caching names in D1", () => {
  it("takes the most recent displayName per email (rows arrive newest first)", async () => {
    const { db } = namesDb({
      attendees: [
        { email: "pat@client.example", display_name: "Pat Lee" },
        { email: "pat@client.example", display_name: "Patty" },
      ],
    });
    const L = await loadNameLookup(db, ["Pat@Client.example"]);
    assert.equal(L.calendar.get("pat@client.example"), "Pat Lee");
  });

  it("works before migration 0009 is applied (no person_name table)", async () => {
    const { db } = namesDb({ attendees: [{ email: "pat@client.example", display_name: "Pat Lee" }], cache: "missing" });
    const p = { attendees: [{ email: "pat@client.example", name: null }, { email: "x@y.example", name: null }] };
    assert.equal(await resolvePayloadNames(db, p), 1);
    assert.equal(p.attendees[0].name, "Pat Lee");
    assert.equal(p.attendees[1].name, null);
    assert.equal(await cacheNames(db, [{ email: "a@b.example", name: "A B" }], "calendar"), 0);
  });

  it("caches a name learned from another meeting, and uses a plaud name only as a fallback", async () => {
    const { db, writes } = namesDb({
      attendees: [{ email: "pat@client.example", display_name: "Pat Lee" }],
      cache: [{ email: "jo@client.example", name: "Jo Park", source: "plaud" }],
    });
    const p = { attendees: [{ email: "pat@client.example", name: null }, { email: "jo@client.example", name: null }] };
    assert.equal(await resolvePayloadNames(db, p), 2);
    assert.deepEqual(p.attendees.map((a) => a.name), ["Pat Lee", "Jo Park"]);
    assert.equal(writes.length, 1);
    assert.equal(writes[0][0], "calendar");
    assert.equal(writes[0][1], "pat@client.example");
  });

  it("drops junk before writing", async () => {
    const { db, writes } = namesDb({});
    const n = await cacheNames(db, [{ email: "not-an-email", name: "X" }, { email: "a@b.example", name: "a@b.example" }], "plaud");
    assert.equal(n, 0);
    assert.equal(writes.length, 0);
  });

  it("a plaud write never replaces a calendar name (SQL guard)", () => {
    const src = readFileSync(new URL("../src/lib/person-names.ts", import.meta.url), "utf8");
    assert.match(src, /WHERE person_name\.source = 'plaud'/);
    const mig = readFileSync(new URL("../migrations/0009_person_name.sql", import.meta.url), "utf8");
    assert.match(mig, /CREATE TABLE IF NOT EXISTS person_name/);
  });
});

describe("Plaud speakers → attendees (only clean mappings)", () => {
  const att = (email: string, extra: Partial<Attendee> = {}): Attendee => ({ email, self: false, name: null, ...extra });

  it("drops generic labels and keeps names", () => {
    assert.deepEqual(parseSpeakers(["Speaker 1", "SPEAKER_2", "Jane Doe", { name: "Pat Lee", email: "PAT@client.example" }, 7, null]), [
      { name: "Jane Doe", email: null },
      { name: "Pat Lee", email: "pat@client.example" },
    ]);
  });

  it("maps a speaker that carries the attendee's email", () => {
    const m = matchSpeakersToAttendees([att("pat@client.example")], [{ name: "Pat Lee", email: "pat@client.example" }]);
    assert.equal(m.get("pat@client.example"), "Pat Lee");
  });

  it("maps a name that spells the email's local part", () => {
    const m = matchSpeakersToAttendees(
      [att("jane.doe@acme.example"), att("jsmith@acme.example"), att("ops@acme.example")],
      [{ name: "Jane Doe", email: null }, { name: "John Smith", email: null }, { name: "Hershey", email: null }],
    );
    assert.equal(m.get("jane.doe@acme.example"), "Jane Doe");
    assert.equal(m.get("jsmith@acme.example"), "John Smith");
    assert.equal(m.has("ops@acme.example"), false);
  });

  it("refuses an ambiguous mapping", () => {
    // "Jane Doe" could be jane@ or jane.doe@ — neither is taken.
    const m = matchSpeakersToAttendees([att("jane@a.example"), att("jane.doe@b.example")], [{ name: "Jane Doe", email: null }]);
    assert.equal(m.size, 0);
    // Two Janes and one jane@ — also skipped.
    const m2 = matchSpeakersToAttendees([att("jane@a.example")], [{ name: "Jane Doe", email: null }, { name: "Jane Roe", email: null }]);
    assert.equal(m2.size, 0);
  });

  it("never names yourself or an attendee who already has a Google name", () => {
    const m = matchSpeakersToAttendees(
      [att("me@x.example", { self: true }), att("pat.lee@x.example", { name: "Pat Lee" })],
      [{ name: "Me Person", email: "me@x.example" }, { name: "Pat Lee", email: null }],
    );
    assert.equal(m.size, 0);
  });

  it("reads speakers per recording from the ingest body", () => {
    const map = extractPlaudSpeakers({
      recordings: [
        { plaud_file_id: "f1", title: "Phone Call: Acme", speakers: ["Speaker 1", "Jane Doe"] },
        { plaud_file_id: "f2", title: "Phone Call: Beta" },
      ],
    });
    assert.deepEqual(map.get("f1"), [{ name: "Jane Doe", email: null }]);
    assert.equal(map.has("f2"), false);
  });
});

describe("app shows a name, else the full email", () => {
  it("never shows a bare email local part for an attendee", () => {
    const appJs = readFileSync(new URL("../public/app.js", import.meta.url), "utf8");
    assert.doesNotMatch(appJs, /a\.name \|\| a\.email\.split\("@"\)/);
  });
});
