import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { api } from "../src/routes/api.ts";
import {
  collectCompanyDomains,
  companiesForAttendees,
  companyDomain,
  companyNameFromDomain,
  isFreeMailDomain,
  normalizeCompanyDomain,
  normalizeCompanyName,
  registrableDomain,
  selfDomainsFrom,
  tagCompanies,
} from "../src/lib/companies.ts";
import { companyRoutes, summarizeCompany } from "../src/routes/companies.ts";
import { displayWearableInfo } from "../src/lib/source-display.ts";
import { summarizePerson } from "../src/lib/people.ts";
import { noHrCoverage, type MeetingHrStress } from "../src/lib/heartrate.ts";
import { fakeKv, sqliteD1 } from "./sqlite-d1.ts";

describe("company domains", () => {
  it("reduces subdomains to the registrable domain", () => {
    assert.equal(registrableDomain("acme.com"), "acme.com");
    assert.equal(registrableDomain("mail.eu.acme.com"), "acme.com");
    assert.equal(registrableDomain("ACME.COM."), "acme.com");
    assert.equal(registrableDomain("com"), null);
    assert.equal(registrableDomain("bad host.com"), null);
    assert.equal(registrableDomain(".acme.com"), null);
  });

  it("keeps three labels for common two-part suffixes", () => {
    assert.equal(registrableDomain("london.acme.co.uk"), "acme.co.uk");
    assert.equal(registrableDomain("acme.co.uk"), "acme.co.uk");
    assert.equal(registrableDomain("co.uk"), null);
    assert.equal(registrableDomain("sydney.widgets.com.au"), "widgets.com.au");
    assert.equal(registrableDomain("team.startup.co.il"), "startup.co.il");
    assert.equal(registrableDomain("x.firm.co.nz"), "firm.co.nz");
    assert.equal(registrableDomain("a.b.co.jp"), "b.co.jp");
    // A label that only looks like a suffix is not one.
    assert.equal(registrableDomain("mail.co.example.com"), "example.com");
  });

  it("never tags free or personal mail", () => {
    for (const email of [
      "a@gmail.com", "a@googlemail.com", "a@yahoo.com", "a@yahoo.co.uk", "a@ymail.com", "a@outlook.com",
      "a@hotmail.com", "a@hotmail.fr", "a@live.com", "a@msn.com", "a@icloud.com", "a@me.com", "a@mac.com",
      "a@aol.com", "a@proton.me", "a@protonmail.com", "a@gmx.de", "a@gmx.net", "a@mail.gmx.com",
      "team@googlegroups.com", "x1y2z3@privaterelay.appleid.com",
    ]) {
      assert.equal(companyDomain(email), null, email);
    }
    assert.equal(isFreeMailDomain("yahoo.com.au"), true);
    assert.equal(isFreeMailDomain("acme.com"), false);
  });

  it("never tags calendar rooms, groups or imported calendars", () => {
    assert.equal(companyDomain("c_188abc@resource.calendar.google.com"), null);
    assert.equal(companyDomain("team_abc@group.calendar.google.com"), null);
    assert.equal(companyDomain("x@group.v.calendar.google.com"), null);
    assert.equal(companyDomain("x@import.calendar.google.com"), null);
    assert.equal(companyDomain("noreply@acme.com"), null);
    assert.equal(companyDomain("not an email"), null);
  });

  it("excludes the owner's own domains, but never free mail as a self domain", () => {
    const self = selfDomainsFrom(["me@example.com", "me@mail.example.com", "me@gmail.com"]);
    assert.deepEqual([...self], ["example.com"]);
    assert.equal(companyDomain("colleague@example.com", self), null);
    assert.equal(companyDomain("colleague@eu.example.com", self), null);
    assert.equal(companyDomain("pat@acme.com", self), "acme.com");
    assert.equal(companyDomain("Pat@Sales.ACME.com", self), "acme.com");
  });

  it("builds readable names from the domain", () => {
    assert.equal(companyNameFromDomain("acme-corp.com"), "Acme Corp");
    assert.equal(companyNameFromDomain("acme.co.uk"), "Acme");
    assert.equal(companyNameFromDomain("ibm.com"), "IBM");
    assert.equal(companyNameFromDomain("big_box-stores.com"), "Big Box Stores");
    assert.equal(companyNameFromDomain("3m.com"), "3m");
  });

  it("validates domains from a URL and saved names", () => {
    const self = new Set(["example.com"]);
    assert.equal(normalizeCompanyDomain("Acme.com", self), "acme.com");
    assert.equal(normalizeCompanyDomain("acme.co.uk", self), "acme.co.uk");
    assert.equal(normalizeCompanyDomain("mail.acme.com", self), null);
    assert.equal(normalizeCompanyDomain("gmail.com", self), null);
    assert.equal(normalizeCompanyDomain("example.com", self), null);
    assert.equal(normalizeCompanyDomain("%E0%A4%A", self), null);
    assert.equal(normalizeCompanyName("  Acme   Corporation "), "Acme Corporation");
    assert.equal(normalizeCompanyName("pat@acme.com"), null);
    assert.equal(normalizeCompanyName("x".repeat(81)), null);
    assert.equal(normalizeCompanyName(""), null);
  });

  it("lists each company on a meeting once, in attendee order, with overrides", () => {
    const ctx = { selfDomains: new Set(["example.com"]), names: new Map([["acme.com", "ACME Inc"]]) };
    const companies = companiesForAttendees([
      { email: "me@example.com", self: true },
      { email: "pat@globex.io" },
      { email: "sam@acme.com" },
      { email: "lee@eu.acme.com" },
      { email: "friend@gmail.com" },
    ], ctx);
    assert.deepEqual(companies, [{ domain: "globex.io", name: "Globex" }, { domain: "acme.com", name: "ACME Inc" }]);
  });

  it("tags every attendees list in a payload and leaves existing tags alone", () => {
    const ctx = { selfDomains: new Set<string>(), names: new Map<string, string>() };
    const payload = {
      day: { calendar: { events: [
        { id: "a", attendees: [{ email: "pat@acme.com", name: null }] },
        { id: "b", attendees: [] },
        { id: "c", attendees: [{ email: "x@globex.io" }], companies: [{ domain: "kept.com", name: "Kept" }] },
      ] } },
      hits: [{ id: "a", attendees: [{ email: "sam@initech.com", name: "Sam" }] }],
    };
    assert.deepEqual([...collectCompanyDomains(payload, ctx.selfDomains)].sort(), ["acme.com", "globex.io", "initech.com"]);
    assert.equal(tagCompanies(payload, ctx), 3);
    const events = payload.day.calendar.events as Array<{ companies?: unknown }>;
    assert.deepEqual(events[0].companies, [{ domain: "acme.com", name: "Acme" }]);
    assert.deepEqual(events[1].companies, []);
    assert.deepEqual(events[2].companies, [{ domain: "kept.com", name: "Kept" }]);
    assert.deepEqual((payload.hits[0] as { companies?: unknown }).companies, [{ domain: "initech.com", name: "Initech" }]);
  });
});

const hr = (zone: MeetingHrStress["zone"], meanBpm: number): MeetingHrStress => ({
  ...noHrCoverage(), coverage: "ok", source: "WHOOP", zone, meanBpm,
});

describe("company heart rate summary", () => {
  it("uses the person math, worded for a company, without em dashes", () => {
    const rows = [{ hrStress: hr("high", 92) }, { hrStress: hr("low", 70) }, { hrStress: hr("moderate", 80) }, { hrStress: null }];
    const company = summarizeCompany(rows);
    const person = summarizePerson(rows);
    assert.deepEqual({ ...company, badgeNote: "" }, { ...person, badgeNote: "" });
    assert.equal(company.badge, "mixed");
    assert.doesNotMatch(company.badgeNote, /—/);
    assert.match(summarizeCompany([]).badgeNote, /company pattern/);
  });
});

function setup() {
  const { db, raw } = sqliteD1();
  const meeting = raw.prepare(`INSERT INTO calendar_event
    (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, title, kind, updated_at, attendees_json, source_type)
    VALUES (?, 'google', ?, ?, ?, -300, 1800, ?, 'client', 'now', ?, 'calendar')`);
  const attendee = raw.prepare(`INSERT INTO calendar_attendee (event_id, source, email, self, display_name)
    VALUES (?, 'google', ?, ?, ?)`);
  function add(id: string, day: string, title: string, people: Array<{ email: string; self?: boolean; displayName?: string }>) {
    meeting.run(id, day, `${day}T18:30:00.000Z`, `${day}T19:00:00.000Z`, title, JSON.stringify(people));
    for (const a of people) attendee.run(id, a.email.toLowerCase(), a.self ? 1 : 0, a.displayName ?? null);
  }
  const self = { email: "me@example.com", self: true };
  const pat = { email: "pat@acme.com", displayName: "Pat Lee" };
  const sam = { email: "sam@eu.acme.com", displayName: "Sam Ruiz" };
  const gee = { email: "gee@globex.io", displayName: "Gee Ward" };
  add("m1", "2026-11-10", "Acme kickoff", [self, pat, sam]);
  add("m2", "2026-11-11", "Acme follow up", [self, pat]);
  add("m3", "2026-11-12", "Globex intro", [self, gee, { email: "room@resource.calendar.google.com" }]);
  add("m4", "2026-11-12", "Lunch", [self, { email: "friend@gmail.com", displayName: "Friend" }]);
  add("m5", "2026-11-13", "Internal", [self, { email: "ops@example.com", displayName: "Ops" }]);
  add("m6", "2026-11-13", "Three way", [self, sam, gee]);
  raw.exec(`INSERT INTO daily_readiness (day, source, source_day, score, updated_at) VALUES
    ('2026-11-11', 'whoop', '2026-11-11', 60, 'now'), ('2026-11-12', 'whoop', '2026-11-12', 70, 'now'),
    ('2026-11-14', 'whoop', '2026-11-14', 50, 'now')`);
  const bindings = { WEARABLE: "whoop", TOKENS: fakeKv({ "settings:source_display:whoop": "true" }), DB: db };
  const call = async (route: string, init: RequestInit = {}) => {
    const res = await api.request(route, init, bindings as never);
    return { status: res.status, headers: res.headers, body: await res.json() as any };
  };
  const get = async (route: string) => {
    const res = await call(route);
    assert.equal(res.status, 200, `${route}: ${JSON.stringify(res.body)}`);
    return res.body;
  };
  return { raw, db, get, call };
}

const RANGE = "start=2026-11-01&end=2026-11-20";

describe("company endpoints", () => {
  it("lists companies with meeting, people and day counts and the next-morning average", async () => {
    const { raw, get, call } = setup();
    try {
      const res = await call(`/companies?${RANGE}`);
      assert.match(res.headers.get("cache-control") ?? "", /private/);
      const list = res.body;
      assert.equal(list.ok, true);
      assert.equal(list.start, "2026-11-01");
      assert.deepEqual(list.companies.map(({ domain, name, meetings, people, days, avg }: any) =>
        [domain, name, meetings, people, days, avg]), [
        ["acme.com", "Acme", 3, 2, 3, 60],
        ["globex.io", "Globex", 2, 1, 2, 50],
      ]);
      assert.equal(list.companies[0].trend, null);
      assert.ok("usualRecovery" in list);
    } finally {
      raw.close();
    }
  });

  it("searches companies by name and domain", async () => {
    const { raw, get } = setup();
    try {
      assert.deepEqual((await get("/companies/search?q=acm")).companies, [{ domain: "acme.com", name: "Acme" }]);
      assert.deepEqual((await get("/companies/search?q=globex.io")).companies, [{ domain: "globex.io", name: "Globex" }]);
      assert.deepEqual((await get("/companies/search?q=gmail")).companies, []);
      assert.deepEqual((await get("/companies/search?q=example")).companies, []);
      assert.deepEqual((await get("/companies/search?q=")).companies, []);
    } finally {
      raw.close();
    }
  });

  it("returns a company's meetings in the person shape, with its people and tags", async () => {
    const { raw, get } = setup();
    try {
      const company = await get(`/companies/acme.com/meetings?${RANGE}`);
      assert.equal(company.domain, "acme.com");
      assert.equal(company.name, "Acme");
      assert.deepEqual(company.meetings.map((m: any) => m.id), ["m6", "m2", "m1"]);
      assert.equal(company.trend.meetingCount, 3);
      assert.deepEqual(company.people, [
        { email: "pat@acme.com", name: "Pat Lee", meetings: 2 },
        { email: "sam@eu.acme.com", name: "Sam Ruiz", meetings: 2 },
      ]);
      const m6 = company.meetings[0];
      assert.deepEqual(m6.companyAttendees, [{ email: "sam@eu.acme.com", name: "Sam Ruiz" }]);
      assert.deepEqual(m6.companies, [{ domain: "acme.com", name: "Acme" }, { domain: "globex.io", name: "Globex" }]);
      for (const key of ["id", "title", "day", "startUtc", "startLocal", "hrStress", "nextReadinessScore"]) {
        assert.ok(key in m6, key);
      }
      assert.ok(!("attendees" in m6));
      assert.equal(company.meetings[2].nextReadinessScore, 60);
    } finally {
      raw.close();
    }
  });

  it("refuses free mail, the owner's own domain and junk", async () => {
    const { raw, call } = setup();
    try {
      for (const domain of ["gmail.com", "example.com", "eu.acme.com", "not a domain"]) {
        const res = await call(`/companies/${encodeURIComponent(domain)}/meetings?${RANGE}`);
        assert.equal(res.status, 404, domain);
      }
    } finally {
      raw.close();
    }
  });

  it("matches the person page when a company has one person", async () => {
    const { raw, get } = setup();
    try {
      const company = await get(`/companies/globex.io/meetings?${RANGE}`);
      const person = await get(`/people/gee%40globex.io/meetings?${RANGE}`);
      assert.deepEqual(company.meetings.map((m: any) => m.id), person.meetings.map((m: any) => m.id));
      assert.deepEqual({ ...company.trend, badgeNote: "" }, { ...person.trend, badgeNote: "" });
      assert.deepEqual(
        company.meetings.map(({ companyAttendees, ...rest }: any) => rest),
        person.meetings,
      );
    } finally {
      raw.close();
    }
  });

  it("tags companies on person meetings, the day view and the day briefing", async () => {
    const { raw, get } = setup();
    try {
      const person = await get(`/people/pat%40acme.com/meetings?${RANGE}`);
      assert.deepEqual(person.meetings.map((m: any) => m.companies), [
        [{ domain: "acme.com", name: "Acme" }],
        [{ domain: "acme.com", name: "Acme" }],
      ]);
      const view = await get("/view?date=2026-11-12");
      const events = view.day.calendar.events;
      assert.deepEqual(events.map((e: any) => [e.id, e.companies.map((c: any) => c.domain)]), [
        ["m3", ["globex.io"]], ["m4", []],
      ]);
      const briefing = await get("/briefing/day?date=2026-11-13");
      assert.deepEqual(briefing.calendar.events.map((e: any) => [e.id, e.companies.map((c: any) => c.domain)]), [
        ["m5", []], ["m6", ["acme.com", "globex.io"]],
      ]);
    } finally {
      raw.close();
    }
  });

  it("renames a company and goes back to the domain name", async () => {
    const { raw, get, call } = setup();
    try {
      const put = (domain: string, body: unknown) => call(`/companies/${domain}/name`, {
        method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
      });
      const saved = await put("acme.com", { name: "  Acme Corporation " });
      assert.equal(saved.status, 200);
      assert.deepEqual(saved.body, { ok: true, domain: "acme.com", name: "Acme Corporation" });
      assert.equal((await get(`/companies?${RANGE}`)).companies[0].name, "Acme Corporation");
      assert.equal((await get(`/companies/acme.com/meetings?${RANGE}`)).name, "Acme Corporation");
      assert.deepEqual((await get("/companies/search?q=corporation")).companies, [{ domain: "acme.com", name: "Acme Corporation" }]);
      const view = await get("/view?date=2026-11-13");
      const m6 = view.day.calendar.events.find((e: any) => e.id === "m6");
      assert.equal(m6.companies[0].name, "Acme Corporation");
      assert.equal((await put("acme.com", { name: "x@y.com" })).status, 400);
      assert.equal((await put("acme.com", {})).status, 400);
      assert.equal((await put("gmail.com", { name: "Google" })).status, 404);
      const cleared = await put("acme.com", { name: "" });
      assert.deepEqual(cleared.body, { ok: true, domain: "acme.com", name: "Acme" });
    } finally {
      raw.close();
    }
  });

  it("summarizes heart rate per company with the same numbers on the list and the company page", async () => {
    const { raw, db } = setup();
    try {
      const zones: Record<string, MeetingHrStress> = {
        m1: hr("high", 95), m2: hr("high", 91), m3: hr("low", 68), m6: hr("moderate", 82),
      };
      const w = { ...displayWearableInfo("whoop"), hasIntradayHr: true, whoopWebHr: true, ouraHr: false };
      const routes = companyRoutes({
        dashboardWearable: async () => w as never,
        meetingHrMap: async (_env, _w, events) => new Map(events.flatMap((e) => zones[e.id] ? [[e.id, zones[e.id]]] : [])),
        labelsFor: () => ({ provider: "WHOOP", readiness: "recovery", strain: null, intradayHr: true, hrProvider: "WHOOP" }),
        methodNoteFor: () => "note",
      });
      const env = { WEARABLE: "whoop", TOKENS: fakeKv({ "settings:source_display:whoop": "true" }), DB: db };
      const list = await (await routes.request(`/?${RANGE}`, {}, env as never)).json() as any;
      const acme = list.companies.find((c: any) => c.domain === "acme.com");
      assert.equal(acme.trend.elevated, 2);
      assert.equal(acme.trend.watching, 1);
      assert.equal(acme.trend.badge, "often spikes you");
      const page = await (await routes.request(`/acme.com/meetings?${RANGE}`, {}, env as never)).json() as any;
      assert.deepEqual(page.trend, acme.trend);
      assert.deepEqual(page.trendsByHrSource.map((t: any) => [t.source, t.withCoverage]), [["WHOOP", 3]]);
      const globex = list.companies.find((c: any) => c.domain === "globex.io");
      assert.equal(globex.trend.restored, 1);
      assert.equal(globex.trend.watching, 1);
      const skipped = await (await routes.request(`/?${RANGE}&hr=0`, {}, env as never)).json() as any;
      assert.equal(skipped.companies[0].trend, null);
    } finally {
      raw.close();
    }
  });

  it("still answers when the company_name table is missing", async () => {
    const { raw, get, call } = setup();
    try {
      raw.exec("DROP TABLE company_name");
      assert.equal((await get(`/companies?${RANGE}`)).companies[0].name, "Acme");
      const res = await call("/companies/acme.com/name", {
        method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ name: "Acme Co" }),
      });
      assert.equal(res.status, 503);
    } finally {
      raw.close();
    }
  });

  it("reads the owner's own addresses from a small index, not every attendee row", () => {
    const { raw } = setup();
    try {
      const plan = raw.prepare("EXPLAIN QUERY PLAN SELECT DISTINCT email FROM calendar_attendee WHERE self = 1").all() as
        Array<{ detail: string }>;
      assert.match(plan.map((r) => r.detail).join(" "), /idx_calendar_attendee_self_email/);
    } finally {
      raw.close();
    }
  });
});
