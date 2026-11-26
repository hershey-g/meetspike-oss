/**
 * Data-safety checks for the multi-account calendar change: the first sync
 * after deploy on data stored by the single-account release, a legacy token
 * that no longer works, and a calendar dropped or an account disconnected
 * while a sync is running. Made-up addresses only.
 */
import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import type { Env } from "../src/env.ts";
import { syncCalendarIncremental } from "../src/sources/calendar/ingest.ts";
import { disconnectAccount, migrateLegacyGoogleTokens, setCalendarSelected } from "../src/sources/calendar/accounts.ts";
import { GOOGLE_TOKEN_KEY, googleTokenKey } from "../src/sources/calendar/endpoints.ts";
import type { GoogleFetch } from "../src/sources/calendar/client.ts";
import { fakeKv, sqliteD1 } from "./sqlite-d1.ts";
import {
  activeEventIds,
  addAccount,
  BUNDLE,
  calendarRow,
  eventRow,
  gEvent,
  GOOGLE_BUNDLE,
  makeGoogleEnv,
  stubGoogle,
  type Row,
} from "./google-stub.ts";

const ME = "owner@gmail.example";
const WORK = "owner@work.example";
const NOW = new Date("2026-11-17T21:00:00.000Z");
const AT = (d: number, h: number, m = 0) =>
  `2026-11-${String(d).padStart(2, "0")}T${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:00-05:00`;

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

/** Rows as the release before 0018 stored them, written before migration 0018 runs. */
function seedOldRelease(r: import("node:sqlite").DatabaseSync) {
  const ins = r.prepare(
    `INSERT INTO calendar_event (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, title, kind,
       attendee_count, attendees_json, after_hours, deleted_at, updated_at, source_type)
     VALUES (?, ?, ?, ?, ?, -300, ?, ?, 'meeting', ?, ?, 0, ?, '2026-11-01T00:00:00.000Z', ?)`,
  );
  const people = JSON.stringify([
    { email: ME, self: true, name: null },
    { email: "pat@client.example", self: false, name: "Pat" },
  ]);
  ins.run("g1", "google", "2026-11-16", "2026-11-16T15:00:00.000Z", "2026-11-16T15:30:00.000Z", 1800, "Meeting g1", 2, people, null, "calendar");
  ins.run("g2_20261118T150000Z", "google", "2026-11-18", "2026-11-18T15:00:00.000Z", "2026-11-18T16:00:00.000Z", 3600, "Weekly", 1, null, null, "calendar");
  ins.run("g3", "google", "2026-11-12", "2026-11-12T15:00:00.000Z", "2026-11-12T16:00:00.000Z", 3600, "Deleted before", 1, null, "2026-11-12T00:00:00.000Z", "calendar");
  ins.run("gold", "google", "2026-09-01", "2026-09-01T15:00:00.000Z", "2026-09-01T16:00:00.000Z", 3600, "Outside window", 1, null, null, "calendar");
  ins.run("gone", "google", "2026-11-15", "2026-11-15T15:00:00.000Z", "2026-11-15T16:00:00.000Z", 3600, "Deleted in Google since", 1, null, null, "calendar");
  ins.run("p1", "plaud", "2026-11-16", "2026-11-16T18:00:00.000Z", "2026-11-16T18:40:00.000Z", 2400, "Recording", 0, null, null, "plaud");
  r.prepare(`INSERT INTO calendar_attendee (event_id, source, email, self, display_name) VALUES ('g1','google',?,1,NULL), ('g1','google','pat@client.example',0,'Pat')`).run(ME);
  r.prepare(
    `INSERT INTO whoop_web_hr (event_id, window_start_utc, window_end_utc, status, sample_count, samples_json, fetched_at)
     VALUES ('g1', '2026-11-16T14:55:00.000Z', '2026-11-16T15:35:00.000Z', 'ok', 2, '[[1,70],[2,72]]', '2026-11-16T16:00:00.000Z')`,
  ).run();
}

function oldReleaseEnv(kv: Record<string, string>) {
  const d1 = sqliteD1({ before: "0018", seed: seedOldRelease });
  const tokens = fakeKv(kv);
  const env = {
    DB: d1.db, TOKENS: tokens, RAW: { put: async () => undefined },
    GOOGLE_CLIENT_ID: "test-google-id", GOOGLE_CLIENT_SECRET: "test-google-secret",
  } as unknown as Env;
  return { env, raw: d1.raw, tokens };
}

describe("first sync after deploy, on data from the single-account release", () => {
  it("moves the token, keeps every meeting once, and keeps heart rate, people and other sources", async () => {
    const t = oldReleaseEnv({ [GOOGLE_TOKEN_KEY]: GOOGLE_BUNDLE, "google:calendar-sync-token": "old" });
    const people = [{ email: ME, self: true }, { email: "pat@client.example", displayName: "Pat" }];
    stub({
      primary: () => ({ id: ME }),
      events: () => ({
        items: [
          gEvent("g1", AT(16, 10), AT(16, 10, 30), { iCalUID: "g1@google.com", attendees: people }),
          gEvent("g2_20261118T150000Z", AT(18, 10), AT(18, 11), { iCalUID: "g2@google.com" }),
          gEvent("g5", AT(19, 10), AT(19, 11), { iCalUID: "g5@google.com" }),
        ],
        nextSyncToken: "tok-1",
      }),
    });

    const r = await syncCalendarIncremental(t.env, "cron", { now: NOW });

    assert.equal(r.mode, "full");
    assert.equal(t.tokens.store.has(GOOGLE_TOKEN_KEY), false);
    assert.ok(t.tokens.store.has(googleTokenKey(ME)));
    assert.deepEqual(activeEventIds(t.raw), ["g1", "g2_20261118T150000Z", "g5", "gold"]);
    const googleRows = t.raw.prepare(`SELECT count(*) AS n FROM calendar_event WHERE source = 'google'`).get() as Row;
    assert.equal(googleRows.n, 6, "no duplicate rows: g1 g2 g3 gold gone g5");
    assert.ok(eventRow(t.raw, "gone")?.deleted_at, "deleted in Google since: tombstoned by the full listing");
    assert.ok(eventRow(t.raw, "g3")?.deleted_at, "already deleted stays deleted");
    const hr = t.raw.prepare(
      `SELECT h.event_id FROM whoop_web_hr h JOIN calendar_event e ON e.id = h.event_id WHERE e.deleted_at IS NULL`,
    ).all() as Row[];
    assert.deepEqual(hr.map((x) => x.event_id), ["g1"], "heart rate still joins its meeting");
    const att = t.raw.prepare(`SELECT email, self FROM calendar_attendee WHERE event_id = 'g1' ORDER BY email`).all() as Row[];
    assert.deepEqual(att.map((a) => [a.email, a.self]), [[ME, 1], ["pat@client.example", 0]]);
    const plaud = t.raw.prepare(`SELECT deleted_at FROM calendar_event WHERE id = 'p1' AND source = 'plaud'`).get() as Row;
    assert.equal(plaud.deleted_at, null);
    const orphans = t.raw.prepare(`SELECT count(*) AS n FROM calendar_event_origin WHERE account_email = ''`).get() as Row;
    assert.equal(orphans.n, 0, "every old origin claimed");
    assert.equal(calendarRow(t.raw, ME, ME)?.sync_token, "tok-1");
  });
});

describe("a legacy token that no longer works", () => {
  it("does not stop the accounts that are connected from syncing, and stays in KV", async () => {
    const t = makeGoogleEnv({ [GOOGLE_TOKEN_KEY]: JSON.stringify({ ...BUNDLE, expires_at: "2000-01-01T00:00:00.000Z" }) });
    await addAccount(t.env, WORK);
    const realFetch = globalThis.fetch;
    const s = stub({ events: () => ({ items: [gEvent("w1", AT(17, 9), AT(17, 10))], nextSyncToken: "tok-w" }) });
    const stubbed = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (new URL(String(input)).hostname === "oauth2.googleapis.com") {
        return new Response(JSON.stringify({ error: "invalid_grant" }), { status: 400 });
      }
      return stubbed(input, init);
    }) as typeof fetch;
    restore = () => { s.restore(); globalThis.fetch = realFetch; };

    const r = await syncCalendarIncremental(t.env, "cron", { now: NOW });

    assert.deepEqual(activeEventIds(t.raw), ["w1"]);
    assert.ok(r.errors?.some((e) => /refresh failed 400/.test(e.error)), "the legacy failure is reported");
    assert.equal(t.tokens.store.has(GOOGLE_TOKEN_KEY), true, "never deleted while it cannot be moved");
  });

  it("moves later even after the same account was signed in again and synced meanwhile", async () => {
    const t = oldReleaseEnv({ [GOOGLE_TOKEN_KEY]: GOOGLE_BUNDLE });
    let googleUp = false;
    stub({
      primary: () => (googleUp ? { id: ME } : new Response("down", { status: 503 })),
      events: () => ({ items: [gEvent("g1", AT(16, 10), AT(16, 10, 30)), gEvent("g5", AT(19, 10), AT(19, 11))], nextSyncToken: "t" }),
    });
    await addAccount(t.env, ME); // the old token could not be moved, so the owner signed in again
    await syncCalendarIncremental(t.env, "cron", { now: NOW }); // g1 now has an origin on (ME, ME) and on ('', '')
    assert.equal(t.tokens.store.has(GOOGLE_TOKEN_KEY), true);

    googleUp = true;
    const r = await syncCalendarIncremental(t.env, "cron", { now: NOW });

    assert.equal(r.errors, undefined, "the move succeeds");
    assert.equal(t.tokens.store.has(GOOGLE_TOKEN_KEY), false);
    const left = t.raw.prepare(`SELECT count(*) AS n FROM calendar_event_origin WHERE account_email = ''`).get() as Row;
    assert.equal(left.n, 0);
    const g1 = t.raw.prepare(`SELECT count(*) AS n FROM calendar_event_origin WHERE event_id = 'g1'`).get() as Row;
    assert.equal(g1.n, 1);
    assert.equal(r.mode, "full", "claimed meetings are checked against the calendar once");
    assert.deepEqual(activeEventIds(t.raw), ["g1", "g5", "gold"], "g2 and gone are no longer on the calendar");
  });

  it("does not replace a newer sign-in of the same account with the old token", async () => {
    const t = makeGoogleEnv({ [GOOGLE_TOKEN_KEY]: JSON.stringify({ ...BUNDLE, refresh_token: "rt-old" }) });
    await addAccount(t.env, ME); // signed in again after the old token stopped refreshing
    const fresh = JSON.parse(t.tokens.store.get(googleTokenKey(ME)) ?? "{}");
    stub({ primary: () => ({ id: ME }) });

    assert.equal(await migrateLegacyGoogleTokens(t.env), ME);

    assert.deepEqual(JSON.parse(t.tokens.store.get(googleTokenKey(ME)) ?? "{}"), fresh);
    assert.equal(t.tokens.store.has(GOOGLE_TOKEN_KEY), false);
  });
});

describe("the same meeting on the main calendar and on a shared calendar", () => {
  it("a shared calendar's sparse copy (private event, reader access) does not strip the title or attendees", async () => {
    const TEAM = "team@group.calendar.example";
    const t = makeGoogleEnv();
    await addAccount(t.env, ME);
    t.raw.prepare(
      `INSERT INTO google_calendar (account_email, calendar_id, summary, is_primary, access_role, selected, updated_at)
       VALUES (?, ?, 'Team', 0, 'reader', 1, '2026-11-01')`,
    ).run(ME, TEAM);
    const people = [{ email: ME, self: true }, { email: "pat@client.example", displayName: "Pat" }];
    stub({
      events: (call) => ({
        items: call.calendarId === ME
          ? [gEvent("m1", AT(17, 9), AT(17, 10), { summary: "Board review", attendees: people, iCalUID: "m1@google.com" })]
          // Google hides a private event's details from readers of someone else's calendar.
          : [{ id: "m1", status: "confirmed", visibility: "private", iCalUID: "m1@google.com", start: { dateTime: AT(17, 9) }, end: { dateTime: AT(17, 10) } }],
        nextSyncToken: `tok-${call.calendarId}`,
      }),
    });

    await syncCalendarIncremental(t.env, "cron", { now: NOW });

    const row = eventRow(t.raw, "m1");
    assert.equal(row?.title, "Board review");
    const att = t.raw.prepare(`SELECT email FROM calendar_attendee WHERE event_id = 'm1' AND self = 0`).all() as Row[];
    assert.deepEqual(att.map((a) => a.email), ["pat@client.example"]);
    const n = t.raw.prepare(`SELECT count(*) AS n FROM calendar_event_origin WHERE event_id = 'm1'`).get() as Row;
    assert.equal(n.n, 2, "both calendars still recorded as having it");
  });
});

describe("a calendar dropped or an account disconnected while a sync runs", () => {
  it("dropping the calendar mid-sync leaves its meetings hidden and no sync token", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, ME);
    const fetchImpl: GoogleFetch = async (env) => {
      await setCalendarSelected(env.DB, ME, ME, false); // the switch is turned off on the iPhone now
      return new Response(JSON.stringify({ items: [gEvent("a", AT(17, 9), AT(17, 10))], nextSyncToken: "tok" }));
    };
    await syncCalendarIncremental(t.env, "cron", { now: NOW, fetchImpl });
    assert.deepEqual(activeEventIds(t.raw), [], "a dropped calendar's meeting must not show");
    assert.equal(calendarRow(t.raw, ME, ME)?.sync_token, null);
    await setCalendarSelected(t.env.DB, ME, ME, true);
    assert.deepEqual(activeEventIds(t.raw), ["a"], "and it comes back when chosen again");
  });

  it("disconnecting mid-sync leaves no meetings or origins from that account", async () => {
    const t = makeGoogleEnv();
    await addAccount(t.env, ME);
    await addAccount(t.env, WORK);
    const fetchImpl: GoogleFetch = async (env, account) => {
      if (account === WORK) await disconnectAccount(env, WORK);
      return new Response(JSON.stringify({ items: [gEvent(`${account[6]}1`, AT(17, 9), AT(17, 10))], nextSyncToken: "tok" }));
    };
    await syncCalendarIncremental(t.env, "cron", { now: NOW, fetchImpl });
    assert.deepEqual(activeEventIds(t.raw), ["g1"]);
    const left = t.raw.prepare(`SELECT count(*) AS n FROM calendar_event_origin WHERE account_email = ?`).get(WORK) as Row;
    assert.equal(left.n, 0);
  });
});
