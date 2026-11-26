import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { afterEach, describe, it } from "node:test";
import type { Env } from "../src/env.ts";
import { syncCalendarIncremental } from "../src/sources/calendar/ingest.ts";
import { runScheduledCalendarSync } from "../src/sources/calendar/scheduled.ts";
import {
  disconnectAccount,
  listAccounts,
  migrateLegacyGoogleTokens,
  setCalendarSelected,
} from "../src/sources/calendar/accounts.ts";
import { GOOGLE_TOKEN_KEY, googleTokenKey } from "../src/sources/calendar/endpoints.ts";
import { getGoogleTokens } from "../src/lib/tokens.ts";
import { loadSelfDomains } from "../src/lib/companies.ts";
import { api } from "../src/routes/api.ts";
import { auth } from "../src/routes/auth.ts";
import { sqliteD1 } from "./sqlite-d1.ts";
import {
  addAccount,
  activeEventIds,
  BUNDLE,
  calendarRow,
  eventRow,
  gEvent,
  GOOGLE_BUNDLE,
  makeGoogleEnv,
  setSyncToken,
  stubGoogle,
  type EventsCall,
  type Row,
} from "./google-stub.ts";

// Made-up addresses only.
const GMAIL = "owner@gmail.example";
const WORK = "owner@work.example";
const NOW = new Date("2026-11-17T21:00:00.000Z");
const TEAM_CAL = "team@group.calendar.example";

let restore: (() => void) | null = null;
afterEach(() => {
  restore?.();
  restore = null;
});

function stub(opts: Parameters<typeof stubGoogle>[0]) {
  const s = stubGoogle(opts);
  restore = s.restore;
  return s;
}

function origins(raw: import("node:sqlite").DatabaseSync): Row[] {
  return raw.prepare(
    `SELECT account_email, calendar_id, google_event_id, event_id, ical_uid FROM calendar_event_origin
     ORDER BY account_email, calendar_id, google_event_id`,
  ).all().map((r) => ({ ...r })) as Row[];
}

function attendeeRows(raw: import("node:sqlite").DatabaseSync, eventId: string): Row[] {
  return raw.prepare(`SELECT email, self FROM calendar_attendee WHERE event_id = ? AND source = 'google' ORDER BY email`)
    .all(eventId).map((r) => ({ ...r })) as Row[];
}

/** Events per (account, calendar), as Google would list them. */
function byCalendar(map: Record<string, Row[]>) {
  return (call: EventsCall) => ({ items: map[`${call.account}|${call.calendarId}`] ?? [], nextSyncToken: `tok-${call.calendarId}` });
}

const AT = (h: number, m = 0) => `2026-11-17T${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:00-05:00`;

describe("moving the single Google token (no new sign-in)", () => {
  it("migration 0018 records stored meetings as the old account's primary calendar", () => {
    const { raw } = sqliteD1({
      before: "0018",
      seed: (r) => {
        for (const [id, deleted] of [["kept", null], ["gone", "2026-11-01"]] as const) {
          r.prepare(
            `INSERT INTO calendar_event (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, kind,
               after_hours, deleted_at, updated_at) VALUES (?, 'google', '2026-11-10', '2026-11-10T15:00:00.000Z',
               '2026-11-10T15:30:00.000Z', -300, 1800, 'meeting', 0, ?, '2026-11-10')`,
          ).run(id, deleted);
        }
        r.prepare(
          `INSERT INTO calendar_event (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, kind,
             after_hours, updated_at) VALUES ('fx', 'sandbox', '2026-11-10', '2026-11-10T15:00:00.000Z',
             '2026-11-10T15:30:00.000Z', -300, 1800, 'meeting', 0, '2026-11-10')`,
        ).run();
      },
    });
    assert.deepEqual(origins(raw), [
      { account_email: "", calendar_id: "", google_event_id: "kept", event_id: "kept", ical_uid: null },
    ]);
  });

  it("names the account from its primary calendar, moves the token, claims old meetings and keeps them visible", async () => {
    const t = makeGoogleEnv({ [GOOGLE_TOKEN_KEY]: GOOGLE_BUNDLE, "google:calendar-sync-token": "old-tok" });
    t.raw.prepare(
      `INSERT INTO calendar_event (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, kind, after_hours,
         attendees_json, updated_at)
       VALUES ('old', 'google', '2026-11-17', '2026-11-17T15:00:00.000Z', '2026-11-17T15:30:00.000Z', -300, 1800,
         'meeting', 0, ?, '2026-11-10')`,
    ).run(JSON.stringify([{ email: GMAIL, self: true, name: null }, { email: "pat@client.example", self: false, name: "Pat" }]));
    t.raw.prepare(
      `INSERT INTO calendar_event_origin (account_email, calendar_id, google_event_id, event_id, start_utc, updated_at)
       VALUES ('', '', 'old', 'old', '2026-11-17T15:00:00.000Z', '2026-11-10')`,
    ).run();
    const s = stub({
      primary: () => ({ id: GMAIL }),
      events: () => ({ items: [gEvent("old", AT(10), AT(10, 30))], nextSyncToken: "tok-new" }),
    });

    const r = await syncCalendarIncremental(t.env, "test", { now: NOW });

    assert.equal(t.tokens.store.has(GOOGLE_TOKEN_KEY), false, "legacy key moved");
    assert.equal(t.tokens.store.has("google:calendar-sync-token"), false, "legacy sync token dropped");
    assert.deepEqual(JSON.parse(t.tokens.store.get(googleTokenKey(GMAIL)) ?? "null"), BUNDLE);
    assert.deepEqual((await listAccounts(t.env.DB)).map((a) => a.email), [GMAIL]);
    assert.equal(calendarRow(t.raw, GMAIL, GMAIL)?.selected, 1, "primary is chosen by default");
    assert.equal(r.mode, "full", "one full listing replaces the old token");
    assert.equal(s.calls[0].calendarId, GMAIL);
    assert.deepEqual(origins(t.raw).map((o) => [o.account_email, o.calendar_id, o.event_id]), [[GMAIL, GMAIL, "old"]]);
    assert.deepEqual(activeEventIds(t.raw), ["old"]);
    assert.equal(calendarRow(t.raw, GMAIL, GMAIL)?.sync_token, "tok-new");
  });

  it("refreshes an expired legacy token before asking whose it is", async () => {
    const t = makeGoogleEnv({
      [GOOGLE_TOKEN_KEY]: JSON.stringify({ ...BUNDLE, expires_at: "2000-01-01T00:00:00.000Z" }),
    });
    const seen: string[] = [];
    stub({ primary: (authz) => (seen.push(authz), { id: GMAIL }) });
    assert.equal(await migrateLegacyGoogleTokens(t.env), GMAIL);
    assert.deepEqual(seen, ["Bearer at-refreshed"]);
    const stored = JSON.parse(t.tokens.store.get(googleTokenKey(GMAIL)) ?? "{}");
    assert.equal(stored.access_token, "at-refreshed");
    assert.equal(stored.refresh_token, "rt", "refresh token kept");
  });

  it("leaves the legacy token alone when Google cannot be reached, and the cron reports it", async () => {
    const t = makeGoogleEnv({ [GOOGLE_TOKEN_KEY]: GOOGLE_BUNDLE });
    stub({ primary: () => new Response("down", { status: 503 }) });
    const r = await runScheduledCalendarSync(t.env);
    assert.ok("error" in r && /503/.test(r.error));
    assert.equal(t.tokens.store.has(GOOGLE_TOKEN_KEY), true);
    assert.ok(await getGoogleTokens(t.env), "still counts as connected");
  });

  it("does nothing when there is no legacy token", async () => {
    const t = makeGoogleEnv();
    assert.equal(await migrateLegacyGoogleTokens(t.env), null);
  });
});

describe("several accounts and calendars", () => {
  it("syncs the primary of every account, and a new calendar starts unchosen", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, GMAIL);
    await addAccount(t.env, WORK);
    const s = stub({
      calendarList: (account) => ({
        items: [
          { id: account, summary: account, primary: true, accessRole: "owner" },
          ...(account === WORK ? [{ id: TEAM_CAL, summary: "Team", accessRole: "reader", backgroundColor: "#16a765" }] : []),
          { id: "busy@x.example", summary: "Busy only", accessRole: "freeBusyReader" },
        ],
      }),
      events: byCalendar({
        [`${GMAIL}|${GMAIL}`]: [gEvent("g1", AT(9), AT(9, 30))],
        [`${WORK}|${WORK}`]: [gEvent("w1", AT(11), AT(11, 30))],
        [`${WORK}|${TEAM_CAL}`]: [gEvent("t1", AT(13), AT(13, 30))],
      }),
    });

    const r = await syncCalendarIncremental(t.env, "test", { now: NOW, force: true });

    assert.deepEqual(s.calls.map((c) => `${c.account}|${c.calendarId}`).sort(), [`${GMAIL}|${GMAIL}`, `${WORK}|${WORK}`]);
    assert.equal(r.calendars.length, 2);
    assert.equal(calendarRow(t.raw, WORK, TEAM_CAL)?.selected, 0);
    assert.equal(calendarRow(t.raw, WORK, TEAM_CAL)?.summary, "Team");
    assert.equal(calendarRow(t.raw, WORK, "busy@x.example"), undefined, "free/busy calendars cannot be read");
    assert.deepEqual(activeEventIds(t.raw), ["g1", "w1"]);
    assert.deepEqual(
      origins(t.raw).map((o) => [o.account_email, o.calendar_id, o.event_id]),
      [[GMAIL, GMAIL, "g1"], [WORK, WORK, "w1"]],
    );
    assert.equal(calendarRow(t.raw, GMAIL, GMAIL)?.sync_token, `tok-${GMAIL}`);
    assert.equal(calendarRow(t.raw, WORK, WORK)?.sync_token, `tok-${WORK}`);
  });

  it("one failing account does not stop the other, and its error is kept", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, GMAIL);
    await addAccount(t.env, WORK);
    stub({
      events: (call) => call.account === WORK
        ? new Response("forbidden", { status: 403 })
        : { items: [gEvent("g1", AT(9), AT(9, 30))], nextSyncToken: "ok" },
    });
    const r = await syncCalendarIncremental(t.env, "test", { now: NOW });
    assert.equal(r.written, 1);
    assert.equal(r.errors?.length, 1);
    assert.equal(r.errors?.[0].account, WORK);
    assert.match(String(calendarRow(t.raw, WORK, WORK)?.last_error), /403/);
    const acct = (await listAccounts(t.env.DB)).find((a) => a.email === WORK);
    assert.match(String(acct?.last_error), /403/);
    assert.equal((await listAccounts(t.env.DB)).find((a) => a.email === GMAIL)?.last_error, null);
  });

  it("a 401 refreshes only that account's token", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, GMAIL);
    await addAccount(t.env, WORK);
    let first = true;
    stub({
      events: (call) => {
        if (call.account === WORK && first) {
          first = false;
          return new Response("expired", { status: 401 });
        }
        return { items: [], nextSyncToken: "ok" };
      },
    });
    await syncCalendarIncremental(t.env, "test", { now: NOW });
    assert.equal(JSON.parse(t.tokens.store.get(googleTokenKey(WORK)) ?? "{}").access_token, "at-refreshed");
    assert.equal(JSON.parse(t.tokens.store.get(googleTokenKey(GMAIL)) ?? "{}").access_token, `at-${GMAIL}`);
  });
});

describe("the same meeting on two calendars counts once", () => {
  const attendees = [
    { email: GMAIL, self: true },
    { email: WORK },
    { email: "pat@client.example", displayName: "Pat" },
  ];
  const attendeesWork = [
    { email: GMAIL },
    { email: WORK, self: true },
    { email: "pat@client.example", displayName: "Pat" },
  ];

  it("same Google event id in two accounts: one meeting, two origins, people once", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, GMAIL);
    await addAccount(t.env, WORK);
    stub({
      events: byCalendar({
        [`${GMAIL}|${GMAIL}`]: [gEvent("shared", AT(10), AT(10, 30), { attendees, iCalUID: "shared@google.com" })],
        [`${WORK}|${WORK}`]: [gEvent("shared", AT(10), AT(10, 30), { attendees: attendeesWork, iCalUID: "shared@google.com" })],
      }),
    });
    await syncCalendarIncremental(t.env, "test", { now: NOW });
    assert.deepEqual(activeEventIds(t.raw), ["shared"]);
    assert.equal(origins(t.raw).length, 2);
    assert.deepEqual(attendeeRows(t.raw, "shared"), [
      { email: GMAIL, self: 1 },
      { email: WORK, self: 1 },
      { email: "pat@client.example", self: 0 },
    ]);
    const people = t.raw.prepare(`SELECT email FROM people_directory ORDER BY email`).all() as Row[];
    assert.deepEqual(people.map((p) => p.email), ["pat@client.example"]);
  });

  it("different event ids with the same iCalUID and start: one meeting", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, GMAIL);
    await addAccount(t.env, WORK);
    stub({
      events: byCalendar({
        [`${GMAIL}|${GMAIL}`]: [gEvent("copy-a", AT(10), AT(10, 30), { iCalUID: "ext-123@outlook.example" })],
        [`${WORK}|${WORK}`]: [gEvent("copy-b", AT(10), AT(10, 30), { iCalUID: "ext-123@outlook.example" })],
      }),
    });
    await syncCalendarIncremental(t.env, "test", { now: NOW });
    assert.deepEqual(activeEventIds(t.raw), ["copy-a"]);
    assert.deepEqual(origins(t.raw).map((o) => [o.google_event_id, o.event_id]), [["copy-a", "copy-a"], ["copy-b", "copy-a"]]);
  });

  it("the same iCalUID at another start (a repeating meeting) stays separate", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, GMAIL);
    await addAccount(t.env, WORK);
    stub({
      events: byCalendar({
        [`${GMAIL}|${GMAIL}`]: [gEvent("r-1", AT(10), AT(10, 30), { iCalUID: "weekly@x.example" })],
        [`${WORK}|${WORK}`]: [gEvent("r-2", AT(12), AT(12, 30), { iCalUID: "weekly@x.example" })],
      }),
    });
    await syncCalendarIncremental(t.env, "test", { now: NOW });
    assert.deepEqual(activeEventIds(t.raw), ["r-1", "r-2"]);
  });

  it("cancelled on one calendar stays while the other has it; gone when both drop it", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, GMAIL);
    await addAccount(t.env, WORK);
    stub({
      events: byCalendar({
        [`${GMAIL}|${GMAIL}`]: [gEvent("shared", AT(10), AT(10, 30))],
        [`${WORK}|${WORK}`]: [gEvent("shared", AT(10), AT(10, 30))],
      }),
    });
    await syncCalendarIncremental(t.env, "test", { now: NOW });
    setSyncToken(t.raw, GMAIL, GMAIL, "tg");
    setSyncToken(t.raw, WORK, WORK, "tw");

    stub({
      events: byCalendar({ [`${GMAIL}|${GMAIL}`]: [{ id: "shared", status: "cancelled" }] }),
    });
    await syncCalendarIncremental(t.env, "test", { now: NOW });
    assert.deepEqual(activeEventIds(t.raw), ["shared"], "work calendar still has it");

    stub({
      events: byCalendar({ [`${WORK}|${WORK}`]: [{ id: "shared", status: "cancelled" }] }),
    });
    await syncCalendarIncremental(t.env, "test", { now: NOW });
    assert.deepEqual(activeEventIds(t.raw), []);
  });

  it("a moved copy follows the meeting it already belongs to", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, GMAIL);
    await addAccount(t.env, WORK);
    stub({
      events: byCalendar({
        [`${GMAIL}|${GMAIL}`]: [gEvent("a", AT(10), AT(10, 30), { iCalUID: "m@x.example" })],
        [`${WORK}|${WORK}`]: [gEvent("b", AT(10), AT(10, 30), { iCalUID: "m@x.example" })],
      }),
    });
    await syncCalendarIncremental(t.env, "test", { now: NOW });
    setSyncToken(t.raw, GMAIL, GMAIL, "tg");
    setSyncToken(t.raw, WORK, WORK, "tw");
    // Only the work copy has been told about the move so far.
    stub({ events: byCalendar({ [`${WORK}|${WORK}`]: [gEvent("b", AT(15), AT(15, 30), { iCalUID: "m@x.example" })] }) });
    await syncCalendarIncremental(t.env, "test", { now: NOW });
    assert.deepEqual(activeEventIds(t.raw), ["a"]);
    assert.equal(eventRow(t.raw, "a")?.start_utc, "2026-11-17T20:00:00.000Z");
  });
});

describe("choosing calendars", () => {
  async function withTeam() {
    const t = makeGoogleEnv();
    await addAccount(t.env, WORK);
    stub({
      calendarList: () => ({
        items: [
          { id: WORK, summary: WORK, primary: true, accessRole: "owner" },
          { id: TEAM_CAL, summary: "Team", accessRole: "reader" },
        ],
      }),
      events: byCalendar({
        [`${WORK}|${WORK}`]: [gEvent("mine", AT(9), AT(9, 30)), gEvent("both", AT(14), AT(14, 30))],
        [`${WORK}|${TEAM_CAL}`]: [gEvent("team", AT(11), AT(11, 30)), gEvent("both", AT(14), AT(14, 30))],
      }),
    });
    await syncCalendarIncremental(t.env, "test", { now: NOW, force: true });
    return t;
  }

  async function put(env: Env, body: unknown) {
    const res = await api.request("/calendars/selection", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }, env);
    return { status: res.status, json: (await res.json()) as Row };
  }

  it("selecting a calendar syncs it; deselecting hides only what no chosen calendar has", async () => {
    const t = await withTeam();
    assert.deepEqual(activeEventIds(t.raw), ["both", "mine"]);

    const on = await put(t.env, { selections: [{ account: WORK, calendarId: TEAM_CAL, selected: true }] });
    assert.equal(on.status, 200);
    assert.equal(on.json.changed, 1);
    assert.deepEqual(activeEventIds(t.raw), ["both", "mine", "team"]);
    assert.equal(calendarRow(t.raw, WORK, TEAM_CAL)?.sync_token, `tok-${TEAM_CAL}`);

    const off = await put(t.env, { selections: [{ account: WORK, calendarId: TEAM_CAL, selected: false }] });
    assert.equal(off.json.hidden, 1);
    assert.deepEqual(activeEventIds(t.raw), ["both", "mine"], "the shared meeting stays: the primary has it");
    assert.equal(calendarRow(t.raw, WORK, TEAM_CAL)?.sync_token, null, "a new choice starts with a full listing");
    const accounts = off.json.accounts as Array<{ calendars: Array<{ id: string; selected: boolean }> }>;
    assert.deepEqual(accounts[0].calendars.map((c) => [c.id, c.selected]), [[WORK, true], [TEAM_CAL, false]]);
  });

  it("choosing a calendar again shows its stored meetings at once", async () => {
    const t = await withTeam();
    await setCalendarSelected(t.env.DB, WORK, TEAM_CAL, true);
    await syncCalendarIncremental(t.env, "test", { now: NOW });
    await setCalendarSelected(t.env.DB, WORK, TEAM_CAL, false);
    assert.deepEqual(activeEventIds(t.raw), ["both", "mine"]);
    const r = await setCalendarSelected(t.env.DB, WORK, TEAM_CAL, true);
    assert.equal(r.shown, 1);
    assert.deepEqual(activeEventIds(t.raw), ["both", "mine", "team"]);
  });

  it("dropping the primary hides its meetings too", async () => {
    const t = await withTeam();
    await setCalendarSelected(t.env.DB, WORK, WORK, false);
    assert.deepEqual(activeEventIds(t.raw), []);
  });

  it("rejects a bad body and an unknown calendar", async () => {
    const t = await withTeam();
    assert.equal((await put(t.env, { selections: [{ account: WORK, calendarId: TEAM_CAL }] })).status, 400);
    assert.equal((await put(t.env, { nope: true })).status, 400);
    assert.equal((await put(t.env, { selections: [{ account: WORK, calendarId: "nope", selected: true }] })).status, 404);
  });

  it("a calendar that leaves the account's list is forgotten and its meetings hidden", async () => {
    const t = await withTeam();
    await setCalendarSelected(t.env.DB, WORK, TEAM_CAL, true);
    await syncCalendarIncremental(t.env, "test", { now: NOW });
    stub({
      calendarList: () => ({ items: [{ id: WORK, summary: WORK, primary: true, accessRole: "owner" }] }),
      events: () => ({ items: [] }),
    });
    const res = await api.request("/calendars", {}, t.env);
    assert.equal(res.status, 200);
    assert.equal(calendarRow(t.raw, WORK, TEAM_CAL), undefined);
    assert.deepEqual(activeEventIds(t.raw), ["both", "mine"]);
  });
});

describe("GET /api/calendars", () => {
  it("lists accounts with their calendars, choices, last sync and errors", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, GMAIL);
    await addAccount(t.env, WORK, "2026-11-02T00:00:00.000Z");
    stub({
      calendarList: (account) => account === WORK
        ? new Response("nope", { status: 500 })
        : { items: [
          { id: GMAIL, summary: "Owner", summaryOverride: "Personal", primary: true, accessRole: "owner", backgroundColor: "#9fd3c7" },
          { id: "holidays@group.v.calendar.example", summary: "Holidays", accessRole: "reader" },
        ] },
    });
    const res = await api.request("/calendars", {}, t.env);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("cache-control"), "private, no-store");
    const json = (await res.json()) as {
      ok: boolean;
      connectPath: string;
      setupPath: string;
      legacyError: string | null;
      accounts: Array<{ email: string; error: string | null; connectedAt: string; calendars: Row[] }>;
    };
    assert.equal(json.ok, true);
    assert.equal(json.connectPath, "/auth/google/start");
    assert.equal(json.setupPath, "/setup#calendars");
    assert.equal(json.legacyError, null);
    assert.deepEqual(json.accounts.map((a) => a.email), [GMAIL, WORK]);
    assert.deepEqual(json.accounts[0].calendars, [
      { id: GMAIL, name: "Personal", primary: true, selected: true, color: "#9fd3c7", accessRole: "owner", lastSyncAt: null, error: null },
      { id: "holidays@group.v.calendar.example", name: "Holidays", primary: false, selected: false, color: null, accessRole: "reader", lastSyncAt: null, error: null },
    ]);
    assert.match(String(json.accounts[1].error), /calendar list: google 500/);
    assert.equal(json.accounts[1].calendars.length, 1, "the stored primary is still shown");
  });

  it("refresh=0 answers from storage without calling Google", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, GMAIL);
    const s = stub({});
    const res = await api.request("/calendars?refresh=0", {}, t.env);
    assert.equal(res.status, 200);
    assert.equal(s.listCalls.length, 0);
  });
});

describe("disconnecting an account", () => {
  it("deletes its tokens and calendars and hides the meetings only it had", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, GMAIL);
    await addAccount(t.env, WORK);
    stub({
      events: byCalendar({
        [`${GMAIL}|${GMAIL}`]: [gEvent("g-only", AT(9), AT(9, 30)), gEvent("shared", AT(10), AT(10, 30))],
        [`${WORK}|${WORK}`]: [gEvent("w-only", AT(11), AT(11, 30)), gEvent("shared", AT(10), AT(10, 30))],
      }),
    });
    await syncCalendarIncremental(t.env, "test", { now: NOW });

    const res = await api.request(`/calendars/accounts/${encodeURIComponent(WORK)}`, { method: "DELETE" }, t.env);
    assert.equal(res.status, 200);
    const json = (await res.json()) as { removed: boolean; hidden: number; accounts: Array<{ email: string }> };
    assert.equal(json.removed, true);
    assert.equal(json.hidden, 1);
    assert.deepEqual(json.accounts.map((a) => a.email), [GMAIL]);
    assert.equal(t.tokens.store.has(googleTokenKey(WORK)), false);
    assert.equal(calendarRow(t.raw, WORK, WORK), undefined);
    assert.deepEqual(activeEventIds(t.raw), ["g-only", "shared"]);
    assert.ok(origins(t.raw).every((o) => o.account_email === GMAIL));
  });

  it("404 for an account that is not connected; the last account leaves Google disconnected", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, GMAIL);
    assert.equal((await api.request(`/calendars/accounts/${encodeURIComponent(WORK)}`, { method: "DELETE" }, t.env)).status, 404);
    assert.equal((await api.request(`/calendars/accounts/not-an-address`, { method: "DELETE" }, t.env)).status, 400);
    assert.deepEqual(await disconnectAccount(t.env, GMAIL), { removed: true, hidden: 0 });
    assert.equal(await getGoogleTokens(t.env), null);
    const sync = await api.request("/calendar/sync", { method: "POST", body: "{}" }, t.env);
    assert.equal(sync.status, 409);
  });
});

describe("every connected account is the owner", () => {
  it("marks the other account's address as self on meetings read through either account", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, GMAIL);
    await addAccount(t.env, WORK);
    stub({
      events: byCalendar({
        [`${GMAIL}|${GMAIL}`]: [gEvent("m", AT(10), AT(10, 30), {
          attendees: [{ email: GMAIL, self: true }, { email: WORK }, { email: "pat@client.example" }],
          organizer: { email: WORK },
        })],
      }),
    });
    await syncCalendarIncremental(t.env, "test", { now: NOW });
    assert.deepEqual(attendeeRows(t.raw, "m"), [
      { email: GMAIL, self: 1 },
      { email: WORK, self: 1 },
      { email: "pat@client.example", self: 0 },
    ]);
    const json = JSON.parse(String(eventRow(t.raw, "m")?.attendees_json)) as Array<{ email: string; self: boolean }>;
    assert.equal(json.find((a) => a.email === WORK)?.self, true);
  });

  it("connecting a second account re-marks meetings stored before it", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, GMAIL);
    stub({
      events: byCalendar({
        [`${GMAIL}|${GMAIL}`]: [gEvent("m", AT(10), AT(10, 30), {
          attendees: [{ email: GMAIL, self: true }, { email: WORK, displayName: "Work me" }, { email: "pat@client.example" }],
        })],
      }),
    });
    await syncCalendarIncremental(t.env, "test", { now: NOW });
    assert.ok((t.raw.prepare(`SELECT 1 FROM people_directory WHERE email = ?`).get(WORK)), "a person before");
    assert.equal((await loadSelfDomains(t.env.DB)).has("work.example"), false);

    await addAccount(t.env, WORK);

    assert.deepEqual(attendeeRows(t.raw, "m").find((a) => a.email === WORK), { email: WORK, self: 1 });
    const json = JSON.parse(String(eventRow(t.raw, "m")?.attendees_json)) as Array<{ email: string; self: boolean }>;
    assert.equal(json.find((a) => a.email === WORK)?.self, true);
    assert.equal(t.raw.prepare(`SELECT 1 FROM people_directory WHERE email = ?`).get(WORK), undefined, "not a person any more");
    assert.equal((await loadSelfDomains(t.env.DB)).has("work.example"), true, "its domain is the owner's company");
  });

  it("a connected account's domain is the owner's even before any meeting mentions it", async () => {
    const { env } = makeGoogleEnv();
    await addAccount(env, WORK);
    assert.deepEqual([...(await loadSelfDomains(env.DB))], ["work.example"]);
  });
});

describe("Google sign-in adds accounts", () => {
  function oauthEnv() {
    const t = makeGoogleEnv();
    return t;
  }

  async function signIn(env: Env, email: string, tokens: Row = { access_token: `at-${email}`, refresh_token: `rt-${email}`, expires_in: 3600 }) {
    const start = await auth.request("https://app.example/google/start", {}, env);
    assert.equal(start.status, 302);
    const to = new URL(start.headers.get("location") ?? "");
    assert.equal(to.searchParams.get("prompt"), "select_account consent");
    assert.equal(to.searchParams.get("scope"), "https://www.googleapis.com/auth/calendar.readonly", "no new scope");
    assert.equal(to.searchParams.get("code_challenge_method"), "S256");
    const state = to.searchParams.get("state") ?? "";
    const real = globalThis.fetch;
    const s = stubGoogle({});
    const inner = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input).startsWith("https://oauth2.googleapis.com/token")) {
        return new Response(JSON.stringify(tokens), { status: 200 });
      }
      return inner(input, init);
    }) as typeof fetch;
    try {
      const cb = await auth.request(`https://app.example/google/callback?code=c&state=${encodeURIComponent(state)}`, {}, env);
      return { status: cb.status, text: await cb.text(), calls: s.calls };
    } finally {
      globalThis.fetch = real;
    }
  }

  it("stores each account under its own key and keeps the first when a second signs in", async () => {
    const t = oauthEnv();
    const one = await signIn(t.env, GMAIL);
    assert.equal(one.status, 200);
    assert.match(one.text, /owner@gmail\.example is connected/);
    const two = await signIn(t.env, WORK);
    assert.equal(two.status, 200);
    assert.deepEqual((await listAccounts(t.env.DB)).map((a) => a.email), [GMAIL, WORK].sort());
    assert.equal(JSON.parse(t.tokens.store.get(googleTokenKey(GMAIL)) ?? "{}").refresh_token, `rt-${GMAIL}`);
    assert.equal(JSON.parse(t.tokens.store.get(googleTokenKey(WORK)) ?? "{}").refresh_token, `rt-${WORK}`);
    assert.equal(t.tokens.store.has(GOOGLE_TOKEN_KEY), false);
    assert.ok(two.calls.some((c) => c.account === WORK), "the new account syncs right away");
  });

  it("signing in to the old single account moves it instead of losing it", async () => {
    const t = makeGoogleEnv({ [GOOGLE_TOKEN_KEY]: JSON.stringify({ ...BUNDLE, access_token: `at-${GMAIL}` }) });
    await signIn(t.env, WORK);
    assert.deepEqual((await listAccounts(t.env.DB)).map((a) => a.email).sort(), [GMAIL, WORK].sort());
    assert.equal(t.tokens.store.has(GOOGLE_TOKEN_KEY), false);
  });

  it("keeps the stored refresh token when Google sends none on a repeat sign-in", async () => {
    const t = oauthEnv();
    await signIn(t.env, GMAIL);
    await signIn(t.env, GMAIL, { access_token: `at-${GMAIL}`, expires_in: 3600 });
    assert.equal(JSON.parse(t.tokens.store.get(googleTokenKey(GMAIL)) ?? "{}").refresh_token, `rt-${GMAIL}`);
  });
});

describe("setup page: accounts and calendars", () => {
  const read = (f: string) => readFileSync(new URL(`../public/${f}`, import.meta.url), "utf8");

  it("lists accounts with calendar checkboxes, a way to add an account, and disconnect", () => {
    const html = read("setup.html");
    const js = read("setup.js");
    assert.match(html, /id="calendars"/);
    assert.match(html, /Calendars that count as meetings/);
    assert.match(html, /test user/);
    assert.match(js, /getJson\("\/api\/calendars"\)/);
    assert.match(js, /\/api\/calendars\/selection/);
    assert.match(js, /method: "PUT"/);
    assert.match(js, /\/api\/calendars\/accounts\/\$\{encodeURIComponent\(email\)\}/);
    assert.match(js, /method: "DELETE"/);
    assert.match(js, /confirm\(/);
    assert.match(js, /Connect another Google account/);
    assert.match(js, /type="checkbox" data-cal/);
  });

  it("new copy has no em dashes and colours are checked before use", () => {
    const js = read("setup.js");
    const start = js.indexOf("Google accounts and calendars");
    assert.ok(start > 0);
    assert.doesNotMatch(js.slice(start, js.indexOf('document.addEventListener("click"')), /—/);
    assert.doesNotMatch(read("setup.html"), /—/);
    assert.match(js, /function safeColor/);
  });
});
