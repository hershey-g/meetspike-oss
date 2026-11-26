import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, it } from "node:test";
import type { Env } from "../src/env.ts";
import { syncCalendarIncremental } from "../src/sources/calendar/ingest.ts";
import { CALENDAR_SYNC_CRON, runScheduledCalendarSync } from "../src/sources/calendar/scheduled.ts";
import { api } from "../src/routes/api.ts";
// @ts-expect-error plain .mjs helper without types
import * as setupLib from "../scripts/setup-lib.mjs";
import {
  addAccount,
  calendarRow,
  eventRow,
  gEvent,
  makeGoogleEnv,
  setSyncToken,
  stubGoogle,
  type Row,
} from "./google-stub.ts";

const ME = "you@example.com";
const NOW = new Date("2026-11-17T21:00:00.000Z"); // 4:00 PM in New York

let restore: (() => void) | null = null;
afterEach(() => {
  restore?.();
  restore = null;
});

async function connected(token?: string) {
  const t = makeGoogleEnv();
  await addAccount(t.env, ME);
  if (token) setSyncToken(t.raw, ME, ME, token);
  return t;
}

function stub(events: Parameters<typeof stubGoogle>[0]["events"]) {
  const s = stubGoogle({ events });
  restore = s.restore;
  return s.calls;
}

/** A meeting stored by an earlier pass on the primary calendar. */
function seed(raw: import("node:sqlite").DatabaseSync, id: string, startUtc: string, title = `Meeting ${id}`) {
  raw.prepare(
    `INSERT INTO calendar_event (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, title, kind,
       after_hours, updated_at) VALUES (?, 'google', '2026-11-17', ?, ?, -300, 1800, ?, 'meeting', 0, '2026-11-01')`,
  ).run(id, startUtc, startUtc, title);
  raw.prepare(
    `INSERT INTO calendar_event_origin (account_email, calendar_id, google_event_id, event_id, start_utc, updated_at)
     VALUES (?, ?, ?, ?, ?, '2026-11-01')`,
  ).run(ME, ME, id, id, startUtc);
}

describe("calendar sync — first run (no token) is a full window listing", () => {
  it("lists the window with showDeleted, stores nextSyncToken, and tombstones what Google no longer has", async () => {
    const t = await connected();
    seed(t.raw, "gone", "2026-11-17T15:00:00.000Z");
    const calls = stub(() => ({
      items: [gEvent("a", "2026-11-17T14:00:00-05:00", "2026-11-17T14:30:00-05:00")],
      nextSyncToken: "tok-1",
    }));

    const r = await syncCalendarIncremental(t.env, "test", { now: NOW });

    assert.equal(r.mode, "full");
    assert.equal(r.reason, "no_token");
    assert.equal(r.written, 1);
    assert.equal(r.removed, 1);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].calendarId, ME, "the primary calendar is read by its id");
    const q = calls[0].q;
    assert.equal(q.get("syncToken"), null);
    assert.equal(q.get("showDeleted"), "true");
    assert.equal(q.get("singleEvents"), "true");
    assert.equal(q.get("orderBy"), null, "orderBy would suppress nextSyncToken");
    // Window: 21 days back, 30 days ahead, local New York midnights.
    assert.equal(q.get("timeMin"), "2026-10-27T04:00:00.000Z");
    assert.equal(q.get("timeMax"), "2026-12-18T05:00:00.000Z");
    assert.equal(calendarRow(t.raw, ME, ME)?.sync_token, "tok-1");
    assert.ok(eventRow(t.raw, "gone")?.deleted_at, "deleted meeting is tombstoned");
    const log = t.raw.prepare(`SELECT endpoint FROM sync_log ORDER BY id DESC LIMIT 1`).get() as Row;
    assert.equal(log.endpoint, "events:full");
  });

  it("follows every page and keeps the token from the last one", async () => {
    const t = await connected();
    const calls = stub(({ q }) =>
      q.get("pageToken")
        ? { items: [gEvent("b", "2026-11-18T10:00:00-05:00", "2026-11-18T11:00:00-05:00")], nextSyncToken: "tok-last" }
        : { items: [gEvent("a", "2026-11-17T10:00:00-05:00", "2026-11-17T11:00:00-05:00")], nextPageToken: "p2" },
    );
    const r = await syncCalendarIncremental(t.env, "test", { now: NOW });
    assert.equal(calls.length, 2);
    assert.equal(r.written, 2);
    assert.equal(calendarRow(t.raw, ME, ME)?.sync_token, "tok-last");
  });
});

describe("calendar sync — incremental with the stored token", () => {
  it("picks up a meeting added later in the day and a move, with one cheap request", async () => {
    const t = await connected("tok-1");
    seed(t.raw, "moved", "2026-11-17T15:00:00.000Z", "Meeting moved");
    const calls = stub(() => ({
      items: [
        // Booked at 3:30 PM for 4:30 PM — after the morning sync.
        gEvent("late", "2026-11-17T16:30:00-05:00", "2026-11-17T17:00:00-05:00"),
        gEvent("moved", "2026-11-17T17:00:00-05:00", "2026-11-17T17:30:00-05:00"),
      ],
      nextSyncToken: "tok-2",
    }));

    const r = await syncCalendarIncremental(t.env, "test", { now: NOW });

    assert.equal(r.mode, "incremental");
    assert.equal(calls.length, 1);
    assert.equal(calls[0].q.get("syncToken"), "tok-1");
    for (const banned of ["timeMin", "timeMax", "orderBy"]) assert.equal(calls[0].q.get(banned), null, banned);
    assert.equal(r.written, 2);
    assert.equal(eventRow(t.raw, "late")?.start_utc, "2026-11-17T21:30:00.000Z");
    assert.equal(eventRow(t.raw, "moved")?.start_utc, "2026-11-17T22:00:00.000Z");
    assert.equal(calendarRow(t.raw, ME, ME)?.sync_token, "tok-2");
    assert.equal(r.removed, 0, "incremental never sweeps the window");
  });

  it("tombstones a cancelled event that arrives as a bare stub", async () => {
    const t = await connected("tok-1");
    seed(t.raw, "x", "2026-11-17T19:00:00.000Z");
    stub(() => ({ items: [{ id: "x", status: "cancelled" }], nextSyncToken: "tok-2" }));
    const r = await syncCalendarIncremental(t.env, "test", { now: NOW });
    assert.equal(r.written, 1);
    assert.ok(eventRow(t.raw, "x")?.deleted_at);
  });

  it("falls back to a full window listing when Google answers 410 Gone", async () => {
    const t = await connected("stale");
    const calls = stub(({ q }) =>
      q.get("syncToken")
        ? new Response(JSON.stringify({ error: { code: 410 } }), { status: 410 })
        : { items: [gEvent("a", "2026-11-17T16:30:00-05:00", "2026-11-17T17:00:00-05:00")], nextSyncToken: "fresh" },
    );
    const r = await syncCalendarIncremental(t.env, "test", { now: NOW });
    assert.equal(r.mode, "full");
    assert.equal(r.reason, "token_expired");
    assert.equal(calls.length, 2);
    assert.ok(calls[1].q.get("timeMin"));
    assert.equal(calendarRow(t.raw, ME, ME)?.sync_token, "fresh");
    assert.equal(r.written, 1);
  });

  it("force re-lists the whole window even with a token", async () => {
    const t = await connected("tok-1");
    const calls = stub(() => ({ items: [], nextSyncToken: "tok-2" }));
    const r = await syncCalendarIncremental(t.env, "test", { now: NOW, force: true });
    assert.equal(r.mode, "full");
    assert.equal(r.reason, "forced");
    assert.equal(calls[0].q.get("syncToken"), null);
  });

  it("does not throw away the old token when Google gives no new one", async () => {
    const t = await connected("tok-1");
    stub(() => ({ items: [] }));
    await syncCalendarIncremental(t.env, "test", { now: NOW });
    assert.equal(calendarRow(t.raw, ME, ME)?.sync_token, "tok-1");
  });
});

describe("calendar sync — schedule", () => {
  it.skip("runs the 15-minute sync and the every-minute push check from wrangler config, and the template and deploy command agree", () => {
    const root = new URL("../", import.meta.url);
    const cfg = setupLib.parseJsonc(readFileSync(new URL("wrangler.jsonc", root), "utf8"));
    assert.equal(CALENDAR_SYNC_CRON, "*/15 * * * *");
    // Build 11 adds the every-minute cron (PUSH_CRON in src/sources/whoop-web/push.ts) next to the 15-minute one.
    assert.deepEqual(cfg.triggers?.crons, [CALENDAR_SYNC_CRON, "* * * * *"]);
    assert.equal(cfg.routes, undefined, "a cron is not a route");

    const example = setupLib.parseJsonc(readFileSync(new URL("wrangler.jsonc.example", root), "utf8"));
    assert.deepEqual(example.triggers?.crons, cfg.triggers?.crons, "wrangler.jsonc.example lists the same crons as wrangler.jsonc");

    // The deploy uses a production config we cannot edit (a secret), so the workflow passes the crons itself.
    const deploy = readFileSync(new URL(".github/workflows/deploy.yml", root), "utf8");
    const command = deploy.split("\n").find((line) => /wrangler deploy/.test(line) && !line.trim().startsWith("#"));
    assert.ok(command, "deploy.yml has a wrangler deploy command");
    assert.match(command, /-c wrangler\.production\.jsonc/);
    const flag = /--triggers((?:\s+"[^"]+"|\s+'[^']+')+)/.exec(command);
    assert.ok(flag, `deploy command passes --triggers: ${command}`);
    const triggers = [...flag[1].matchAll(/"([^"]+)"|'([^']+)'/g)].map((m) => m[1] ?? m[2]);
    assert.deepEqual(triggers, cfg.triggers?.crons, "the --triggers flags match wrangler.jsonc crons, in order");
    assert.match(deploy, /must match wrangler\.jsonc/i, "a comment says the flags must match wrangler.jsonc");
  });

  it("skips quietly before Google is connected", async () => {
    const t = makeGoogleEnv();
    let called = false;
    const real = globalThis.fetch;
    restore = () => void (globalThis.fetch = real);
    globalThis.fetch = (async () => ((called = true), new Response("{}"))) as typeof fetch;
    assert.deepEqual(await runScheduledCalendarSync(t.env), { skipped: "no_google_tokens" });
    assert.equal(called, false);
  });

  it("logs a Google error and does not throw, so the next tick tries again", async () => {
    const t = await connected("tok-1");
    stub(() => new Response("backend error", { status: 503 }));
    const r = await runScheduledCalendarSync(t.env);
    assert.ok("error" in r && /503/.test(r.error));
    const log = t.raw.prepare(`SELECT status, trigger FROM sync_log ORDER BY id DESC LIMIT 1`).get() as Row;
    assert.equal(log.status, "error");
    assert.equal(log.trigger, "cron");
    assert.equal(calendarRow(t.raw, ME, ME)?.sync_token, "tok-1");
    assert.match(String(calendarRow(t.raw, ME, ME)?.last_error), /503/);
  });
});

describe("POST /api/calendar/sync", () => {
  async function post(env: Env, body: unknown) {
    const res = await api.request("/calendar/sync", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }, env);
    return { status: res.status, json: (await res.json()) as Row };
  }

  beforeEach(() => {
    restore?.();
    restore = null;
  });

  it("does a real incremental resync by default", async () => {
    const t = await connected("tok-1");
    const calls = stub(() => ({
      items: [gEvent("late", "2026-11-17T16:30:00-05:00", "2026-11-17T17:00:00-05:00")],
      nextSyncToken: "tok-2",
    }));
    const { status, json } = await post(t.env, { mode: "live" });
    assert.equal(status, 200);
    assert.equal(json.sync, "incremental");
    assert.equal(json.written, 1);
    assert.ok(typeof json.syncedAt === "string");
    assert.equal(calls[0].q.get("syncToken"), "tok-1");
  });

  it("full: true re-lists the window", async () => {
    const t = await connected("tok-1");
    const calls = stub(() => ({ items: [], nextSyncToken: "tok-2" }));
    const { json } = await post(t.env, { mode: "live", full: true });
    assert.equal(json.sync, "full");
    assert.equal(calls[0].q.get("syncToken"), null);
  });

  it("an explicit window re-lists those days on every selected calendar without touching tokens", async () => {
    const t = await connected("tok-1");
    const calls = stub(() => ({
      items: [gEvent("w", "2026-11-10T10:00:00-05:00", "2026-11-10T10:30:00-05:00")],
      nextSyncToken: "ignored",
    }));
    const { status, json } = await post(t.env, { mode: "live", startDay: "2026-11-09", endDay: "2026-11-10" });
    assert.equal(status, 200);
    assert.equal(json.sync, "window");
    assert.equal(json.written, 1);
    assert.equal(calls[0].q.get("timeMin"), "2026-11-09T05:00:00.000Z");
    assert.equal(calendarRow(t.raw, ME, ME)?.sync_token, "tok-1");
  });

  it("answers 409 (not 401, which the app reads as an Access sign-in) when Google is not connected", async () => {
    const t = makeGoogleEnv();
    const { status, json } = await post(t.env, { mode: "live" });
    assert.equal(status, 409);
    assert.equal(json.needsGoogle, true);
  });

  it("turns a Google failure into a JSON 502 the app can show", async () => {
    const t = await connected("tok-1");
    stub(() => new Response("nope", { status: 500 }));
    const { status, json } = await post(t.env, { mode: "live" });
    assert.equal(status, 502);
    assert.match(String(json.error), /Google Calendar sync failed/);
  });
});

describe("app refresh path", () => {
  const appJs = readFileSync(new URL("../public/app.js", import.meta.url), "utf8");
  const apiTs = readFileSync(new URL("../src/routes/api.ts", import.meta.url), "utf8");

  it("syncs Google on page load and has a Refresh button with a status line", () => {
    assert.match(appJs, /render\(\);\n[^\n]*\n[^\n]*\nautoSync\(\);\s*$/);
    assert.match(appJs, /data-action="resync"/);
    assert.match(appJs, /Synced \$\{ago\}/);
    assert.match(appJs, /Calendar sync failed: /);
  });

  it("does not let the browser serve a pre-sync copy of the view", () => {
    assert.doesNotMatch(apiTs, /"Cache-Control": "[^"]*stale-while-revalidate/);
    assert.match(apiTs, /"Cache-Control", "private, no-store"/);
  });
});
