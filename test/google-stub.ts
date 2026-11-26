/**
 * Shared fakes for Google Calendar tests: a real SQLite D1 with every
 * migration, a KV map, and a fetch stub that answers the primary calendar,
 * the calendar list and events.list per account and calendar.
 * Addresses are example.com / *.example only.
 */
import type { Env } from "../src/env.ts";
import { connectAccount } from "../src/sources/calendar/accounts.ts";
import { googleTokenKey } from "../src/sources/calendar/endpoints.ts";
import { fakeKv, sqliteD1 } from "./sqlite-d1.ts";

export type Row = Record<string, unknown>;

export const BUNDLE = { access_token: "at", refresh_token: "rt", expires_at: "2999-01-01T00:00:00.000Z" };
export const GOOGLE_BUNDLE = JSON.stringify(BUNDLE);

export function makeGoogleEnv(kv: Record<string, string> = {}) {
  const d1 = sqliteD1();
  const tokens = fakeKv(kv);
  const env = {
    DB: d1.db,
    TOKENS: tokens,
    RAW: { put: async () => undefined },
    GOOGLE_CLIENT_ID: "test-google-id",
    GOOGLE_CLIENT_SECRET: "test-google-secret",
  } as unknown as Env;
  return { env, raw: d1.raw, tokens };
}

/** Connect an account the way the OAuth callback does (tokens in KV, primary selected). */
export async function addAccount(env: Env, email: string, at = "2026-11-01T00:00:00.000Z") {
  return connectAccount(env, email, { ...BUNDLE, access_token: `at-${email}` }, at);
}

export function hasAccountToken(tokens: { store: Map<string, string> }, email: string): boolean {
  return tokens.store.has(googleTokenKey(email));
}

export function gEvent(id: string, startIso: string, endIso: string, extra: Row = {}) {
  return {
    id,
    status: "confirmed",
    summary: `Meeting ${id}`,
    start: { dateTime: startIso },
    end: { dateTime: endIso },
    ...extra,
  };
}

export type EventsCall = { account: string; calendarId: string; q: URLSearchParams };

/**
 * Stub Google. `events(call)` answers events.list; `calendarList(account)`
 * answers users/me/calendarList (default: the primary only); `primary(token)`
 * answers calendars/primary (default: the address in the bearer token
 * "at-<email>", else you@example.com).
 */
export function stubGoogle(opts: {
  events?: (call: EventsCall) => Response | Row;
  calendarList?: (account: string) => Response | Row;
  primary?: (token: string) => Response | Row;
} = {}) {
  const calls: EventsCall[] = [];
  const listCalls: string[] = [];
  const realFetch = globalThis.fetch;
  const tokenAccount = (auth: string) => {
    const token = auth.replace(/^Bearer /, "");
    return token.startsWith("at-") ? token.slice(3) : "you@example.com";
  };
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input));
    const auth = new Headers(init?.headers).get("Authorization") ?? "";
    const reply = (out: Response | Row) =>
      out instanceof Response ? out : new Response(JSON.stringify(out), { status: 200 });
    const events = /\/calendar\/v3\/calendars\/([^/]+)\/events$/.exec(url.pathname);
    if (events) {
      const call = { account: tokenAccount(auth), calendarId: decodeURIComponent(events[1]), q: url.searchParams };
      calls.push(call);
      return reply(opts.events ? opts.events(call) : { items: [], nextSyncToken: "tok" });
    }
    if (url.pathname.endsWith("/users/me/calendarList")) {
      const account = tokenAccount(auth);
      listCalls.push(account);
      return reply(opts.calendarList ? opts.calendarList(account) : {
        items: [{ id: account, summary: account, primary: true, accessRole: "owner" }],
      });
    }
    if (url.pathname.endsWith("/calendars/primary")) {
      return reply(opts.primary ? opts.primary(auth) : { id: tokenAccount(auth) });
    }
    if (url.hostname === "oauth2.googleapis.com") {
      return reply({ access_token: "at-refreshed", expires_in: 3600 });
    }
    throw new Error(`unexpected fetch ${url}`);
  }) as typeof fetch;
  return { calls, listCalls, restore: () => void (globalThis.fetch = realFetch) };
}

export function eventRow(raw: import("node:sqlite").DatabaseSync, id: string): Row | undefined {
  return raw.prepare(`SELECT * FROM calendar_event WHERE id = ? AND source = 'google'`).get(id) as Row | undefined;
}

export function activeEventIds(raw: import("node:sqlite").DatabaseSync): string[] {
  return (raw.prepare(`SELECT id FROM calendar_event WHERE source = 'google' AND deleted_at IS NULL ORDER BY id`)
    .all() as Array<{ id: string }>).map((r) => r.id);
}

export function calendarRow(raw: import("node:sqlite").DatabaseSync, account: string, calendarId: string): Row | undefined {
  return raw.prepare(`SELECT * FROM google_calendar WHERE account_email = ? AND calendar_id = ?`)
    .get(account, calendarId) as Row | undefined;
}

export function setSyncToken(raw: import("node:sqlite").DatabaseSync, account: string, calendarId: string, token: string) {
  raw.prepare(`UPDATE google_calendar SET sync_token = ? WHERE account_email = ? AND calendar_id = ?`)
    .run(token, account, calendarId);
}
