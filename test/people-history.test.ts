import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { describe, it } from "node:test";
import { api } from "../src/routes/api.ts";
import { questionRange } from "../src/lib/history-range.ts";
import { peopleRangeDates, readPeopleRange, writePeopleRange, validPeopleDates } from "../public/people-ui.js";
import { fakeKv } from "./sqlite-d1.ts";

function setup() {
  const db = new DatabaseSync(":memory:");
  const migrations = new URL("../migrations/", import.meta.url);
  const files = readdirSync(migrations).sort();
  const migrate = (filename: string) => db.exec(readFileSync(new URL(filename, migrations), "utf8"));
  for (const file of files.filter((file) => file < "0014")) migrate(file);

  const meeting = db.prepare(`INSERT INTO calendar_event
    (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, title, kind, updated_at, attendees_json, source_type)
    VALUES (?, 'google', ?, ?, ?, -300, 1800, ?, 'internal', 'now', ?, ?)`);
  const attendee = db.prepare(`INSERT INTO calendar_attendee (event_id, source, email, self, display_name)
    VALUES (?, 'google', ?, ?, ?)`);
  function add(id: string, day: string, title: string, people: Array<{ email: string; self?: boolean; name?: string }>, source = "calendar") {
    meeting.run(id, day, `${day}T18:30:00.000Z`, `${day}T19:00:00.000Z`, title, JSON.stringify(people), source);
    for (const a of people) attendee.run(id, a.email.toLowerCase().trim(), a.self ? 1 : 0, a.name ?? null);
  }

  const self = { email: "self@example.com", name: "Calendar owner", self: true };
  const jose = { email: "jose@example.com", name: "José Álvarez" };
  const jo = { email: "joe@example.com", name: "Joe Chan" };
  add("a-recording", "2026-11-12", "Meeting", [self, jose], "plaud_phone");
  add("b-original", "2026-11-12", "Meeting", [jose, self]);
  add("c-copy", "2026-11-12", "Meeting", [{ email: "JOSE@EXAMPLE.COM " }, self]);
  add("d-other", "2026-11-12", "Meeting", [self, jo]);
  add("e-title", "2026-11-12", "Another meeting", [self, jose]);
  add("f-old", "2025-02-17", "First pitch", [self, jose]);
  add("g-email", "2024-01-12", "Intro", [{ email: "pippa.smith@example.com" }]);
  add("h-fuzzy", "2025-10-01", "Catch up", [{ email: "kate@example.com", name: "Kätherine Hart" }]);
  add("i-plaud-name", "2026-10-31", "Review", [{ email: "riley@example.com" }]);
  db.exec("INSERT INTO person_name VALUES ('riley@example.com', 'Riley Ross', 'plaud', 'now')");
  db.exec("INSERT INTO daily_readiness (day, source, source_day, score, updated_at) VALUES ('2026-11-13', 'whoop', '2026-11-13', 61, 'now')");
  migrate("0014_people_search.sql");

  const bindings = {
    WEARABLE: "whoop",
    TOKENS: fakeKv({ "settings:source_display:whoop": "true" }),
    DB: {
      prepare(sql: string) {
        const stmt = db.prepare(sql.replace(/\?(\d+)/g, ":p$1"));
        const make = (args: SQLInputValue[]) => {
          const params = /\?\d+/.test(sql)
            ? [Object.fromEntries(args.map((value, i) => [`p${i + 1}`, value]))]
            : args;
          const [named, ...rest] = params;
          const all = () => params.length ? stmt.all(named, ...rest as SQLInputValue[]) : stmt.all();
          return {
            bind: (...values: SQLInputValue[]) => make(values),
            all: async () => ({ results: all() }),
            first: async () => all()[0] ?? null,
          };
        };
        return make([]);
      },
    },
  };
  const get = async (route: string) => {
    const res = await api.request(route, {}, bindings as never);
    assert.equal(res.status, 200, route);
    if (route.startsWith("/people")) assert.match(res.headers.get("cache-control") ?? "", /private/);
    return await res.json() as any;
  };
  const search = async (q: string) => (await get(`/people/search?${new URLSearchParams({ q })}`)).people;
  return { db, add, get, search, self };
}

describe("People URL and Ask range parsing", () => {
  it("preserves rolling presets and inclusive custom dates in URLs", () => {
    const today = "2026-11-21";
    for (const [preset, start] of Object.entries({ "7d": "2026-11-15", "28d": "2026-10-25", "90d": "2026-08-24", year: "2025-11-22" })) {
      const params = new URLSearchParams();
      writePeopleRange(params, { preset });
      assert.deepEqual(peopleRangeDates(readPeopleRange(params), today), { start, end: today });
    }
    const range = { preset: "custom", start: "2023-01-01", end: "2024-02-29" };
    const params = new URLSearchParams("start=2026-11-01&end=2026-11-05");
    writePeopleRange(params, range);
    assert.deepEqual(readPeopleRange(params), range);
    assert.equal(params.get("start"), "2026-11-01");
    params.set("peopleEnd", "2024-02-30");
    assert.deepEqual(readPeopleRange(params), { preset: "28d" });
    assert.equal(validPeopleDates("2026-11-14", "2026-11-13"), false);
    assert.equal(validPeopleDates(today, today), true);
  });

  it("resolves past three months using calendar arithmetic", () => {
    assert.deepEqual(questionRange("What happened in the past three months?", "2026-11-21"), { start: "2026-08-22", end: "2026-11-21" });
    assert.deepEqual(questionRange("Over the past 2 weeks", "2026-11-03"), { start: "2026-10-21", end: "2026-11-03" });
    assert.deepEqual(questionRange("In the last year", "2028-02-29"), { start: "2027-03-01", end: "2028-02-29" });
    assert.equal(questionRange("Which meetings cost me the most?", "2026-11-21"), null);
  });
});

describe("People search index and meeting counts", () => {
  it("backfills names and emails, ranks prefixes above typos, and updates with row changes", async () => {
    const { db, add, search, self } = setup();
    try {
      assert.equal((await search("jOSe aLv"))[0].name, "José Álvarez");
      assert.equal((await search("joe"))[0].email, "joe@example.com");
      assert.equal((await search("jsoe"))[0].email, "jose@example.com");
      assert.equal((await search("Catherine"))[0].email, "kate@example.com");
      assert.equal((await search("pippa.smi"))[0].email, "pippa.smith@example.com");
      assert.equal((await search("RILEY"))[0].name, "Riley Ross");
      assert.deepEqual(await search("Calendar owner"), []);
      assert.deepEqual(await search('"*"'), []);
      add("j-new", "2026-11-19", "Review", [self, { email: "megan@example.com", name: "Mégane Briand" }]);
      assert.equal((await search("megane briand"))[0].email, "megan@example.com");
      db.exec("UPDATE calendar_attendee SET display_name = 'Maggie' WHERE email = 'megan@example.com'");
      assert.equal((await search("maggie"))[0].email, "megan@example.com");
      assert.deepEqual(await search("megane briand"), []);
      db.exec("UPDATE calendar_event SET deleted_at = 'now' WHERE id = 'j-new'");
      assert.deepEqual(await search("maggie"), []);
      db.exec("UPDATE calendar_event SET deleted_at = NULL WHERE id = 'j-new'");
      assert.equal((await search("maggie"))[0].email, "megan@example.com");
      db.exec("DELETE FROM calendar_attendee WHERE event_id = 'j-new'");
      assert.deepEqual(await search("maggie"), []);
    } finally {
      db.close();
    }
  });

  it("deduplicates three copies in People, person history, and the day briefing", async () => {
    const { db, get } = setup();
    try {
      const people = await get("/people?start=2026-11-12&end=2026-11-12");
      assert.deepEqual(people.people.map(({ email, meetings, days, avg }) => [email, meetings, days, avg]), [
        ["jose@example.com", 2, 1, 61], ["joe@example.com", 1, 1, 61],
      ]);
      const person = await get("/people/jose%40example.com/meetings?start=2025-01-01&end=2026-11-21");
      assert.equal(person.trend.meetingCount, 3);
      assert.deepEqual(person.meetings.map(({ id }) => id), ["b-original", "e-title", "f-old"]);
      const day = await get("/briefing/day?date=2026-11-12");
      assert.deepEqual(day.calendar.events.map(({ id }) => id), ["b-original", "d-other", "e-title"]);
    } finally {
      db.close();
    }
  });
});
