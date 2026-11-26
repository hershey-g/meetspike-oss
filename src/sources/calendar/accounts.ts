/**
 * Connected Google accounts and the calendars chosen in each (migration 0018).
 *
 * Tokens: KV google:tokens:<email>, one per account. The account is named by
 * its primary calendar's id, which is its email address, so no scope beyond
 * calendar.readonly is needed.
 *
 * Calendars: D1 google_calendar. Only selected calendars sync and count as
 * meetings. A new calendar starts unselected, except the primary.
 *
 * Events: calendar_event keeps one row per meeting; calendar_event_origin
 * records every calendar it was seen on. A meeting stays visible while one of
 * its origins sits on a selected calendar of a connected account.
 */
import type { Env } from "../../env.ts";
import type { TokenBundle } from "../../types.ts";
import { SOURCE_GOOGLE } from "../../types.ts";
import { normalizeEmail } from "../../lib/people.ts";
import {
  deleteGoogleAccountTokens,
  getGoogleAccountTokens,
  getLegacyGoogleTokens,
  googleBundleFresh,
  putGoogleAccountTokens,
  refreshGoogleBundle,
} from "../../lib/tokens.ts";
import { GOOGLE_TOKEN_KEY } from "./endpoints.ts";
import { fetchAccountEmail, listCalendars, type GoogleFetch, googleFetch } from "./client.ts";

/** Legacy KV key holding the single primary calendar's nextSyncToken. Removed on migration. */
export const LEGACY_CALENDAR_SYNC_TOKEN_KEY = "google:calendar-sync-token";

export type GoogleAccountRow = {
  email: string;
  connected_at: string;
  last_sync_at: string | null;
  last_error: string | null;
  updated_at: string;
};

export type GoogleCalendarRow = {
  account_email: string;
  calendar_id: string;
  summary: string | null;
  is_primary: number;
  access_role: string | null;
  color: string | null;
  selected: number;
  sync_token: string | null;
  last_sync_at: string | null;
  last_error: string | null;
  updated_at: string;
};

function missingTable(error: unknown): boolean {
  return /no such table: (google_account|google_calendar|calendar_event_origin)/.test(String(error));
}

/** Connected accounts, oldest first. Empty before migration 0018 is applied. */
export async function listAccounts(db: D1Database): Promise<GoogleAccountRow[]> {
  try {
    const { results } = await db
      .prepare(`SELECT email, connected_at, last_sync_at, last_error, updated_at
                FROM google_account ORDER BY connected_at, email`)
      .all<GoogleAccountRow>();
    return results ?? [];
  } catch (error) {
    if (missingTable(error)) return [];
    throw error;
  }
}

/** Every connected account's address. Each one is the owner ("self"). */
export async function accountEmails(db: D1Database): Promise<string[]> {
  return (await listAccounts(db)).map((a) => a.email);
}

export async function listCalendarRows(db: D1Database, account?: string): Promise<GoogleCalendarRow[]> {
  const sql = `SELECT account_email, calendar_id, summary, is_primary, access_role, color, selected,
                      sync_token, last_sync_at, last_error, updated_at
               FROM google_calendar ${account ? "WHERE account_email = ?" : ""}
               ORDER BY account_email, is_primary DESC, lower(coalesce(summary, calendar_id)), calendar_id`;
  try {
    const stmt = db.prepare(sql);
    const { results } = await (account ? stmt.bind(account) : stmt).all<GoogleCalendarRow>();
    return results ?? [];
  } catch (error) {
    if (missingTable(error)) return [];
    throw error;
  }
}

export async function getCalendarRow(
  db: D1Database, account: string, calendarId: string,
): Promise<GoogleCalendarRow | null> {
  return db
    .prepare(`SELECT account_email, calendar_id, summary, is_primary, access_role, color, selected,
                     sync_token, last_sync_at, last_error, updated_at
              FROM google_calendar WHERE account_email = ? AND calendar_id = ?`)
    .bind(account, calendarId)
    .first<GoogleCalendarRow>();
}

/**
 * Mark an address as the owner everywhere it is already stored: the attendee
 * index and the attendees_json copy on each meeting. Meetings synced before a
 * second account was connected then stop listing that address as a person or
 * its domain as a company.
 */
export async function markSelfEmail(db: D1Database, rawEmail: string): Promise<number> {
  const email = normalizeEmail(rawEmail);
  if (!email) return 0;
  await db.prepare(`UPDATE calendar_attendee SET self = 1 WHERE email = ? AND self = 0`).bind(email).run();
  const { results } = await db
    .prepare(`SELECT id, source, attendees_json FROM calendar_event
              WHERE attendees_json IS NOT NULL AND instr(lower(attendees_json), ?) > 0`)
    .bind(email)
    .all<{ id: string; source: string; attendees_json: string }>();
  let changed = 0;
  for (const row of results ?? []) {
    let list: unknown;
    try {
      list = JSON.parse(row.attendees_json);
    } catch {
      continue;
    }
    if (!Array.isArray(list)) continue;
    let touched = false;
    for (const a of list) {
      if (a && typeof a === "object" && typeof a.email === "string" && a.email.toLowerCase() === email && a.self !== true) {
        a.self = true;
        touched = true;
      }
    }
    if (!touched) continue;
    await db
      .prepare(`UPDATE calendar_event SET attendees_json = ? WHERE id = ? AND source = ?`)
      .bind(JSON.stringify(list), row.id, row.source)
      .run();
    changed += 1;
  }
  return changed;
}

/**
 * Store an account: its tokens, its row, its primary calendar (selected), and
 * its address as the owner. Connecting an account again keeps its choices.
 */
export async function connectAccount(
  env: Env, rawEmail: string, bundle: TokenBundle, at: string = new Date().toISOString(),
): Promise<string> {
  const email = normalizeEmail(rawEmail);
  if (!email) throw new Error("google account has no usable email address");
  await putGoogleAccountTokens(env, email, bundle);
  await env.DB.prepare(
    `INSERT INTO google_account (email, connected_at, last_sync_at, last_error, updated_at)
     VALUES (?, ?, NULL, NULL, ?)
     ON CONFLICT (email) DO UPDATE SET last_error = NULL, updated_at = excluded.updated_at`,
  ).bind(email, at, at).run();
  // The primary calendar's id is the account address.
  await env.DB.prepare(
    `INSERT INTO google_calendar (account_email, calendar_id, summary, is_primary, selected, updated_at)
     VALUES (?, ?, ?, 1, 1, ?)
     ON CONFLICT (account_email, calendar_id) DO NOTHING`,
  ).bind(email, email, email, at).run();
  await markSelfEmail(env.DB, email);
  return email;
}

/**
 * Move the single-account token (KV google:tokens) to google:tokens:<email>
 * without a new sign-in. Asks Google which address the token belongs to,
 * records the account with its primary calendar selected, and claims the
 * meetings already stored (their origins were written with an empty account
 * by migration 0018). Returns the address, or null when there was nothing to
 * move. The old sync token is dropped, so the next pass is one full listing.
 */
export async function migrateLegacyGoogleTokens(
  env: Env, at: string = new Date().toISOString(),
): Promise<string | null> {
  const legacy = await getLegacyGoogleTokens(env);
  if (!legacy) return null;
  let bundle = legacy;
  if (!googleBundleFresh(bundle)) bundle = await refreshGoogleBundle(env, bundle);
  const email = await fetchAccountEmail(bundle.access_token);
  // A per-account token for the same address comes from a later sign-in, so it
  // is never older than the legacy one: keep it rather than overwrite it.
  const current = await getGoogleAccountTokens(env, email);
  await connectAccount(env, email, current ?? bundle, at);
  // OR IGNORE: when the owner signed in to this account again before the move
  // worked, its sync already recorded some of these meetings on its primary.
  // A plain UPDATE would hit that key and fail every time; the copies left
  // behind duplicate an origin that exists, so they go.
  await env.DB.prepare(
    `UPDATE OR IGNORE calendar_event_origin SET account_email = ?, calendar_id = ? WHERE account_email = ''`,
  ).bind(email, email).run();
  await env.DB.prepare(`DELETE FROM calendar_event_origin WHERE account_email = ''`).run();
  // The claimed meetings were never checked against this calendar: list it in full next pass.
  await env.DB.prepare(`UPDATE google_calendar SET sync_token = NULL WHERE account_email = ? AND calendar_id = ?`)
    .bind(email, email).run();
  await env.TOKENS.delete(GOOGLE_TOKEN_KEY);
  await env.TOKENS.delete(LEGACY_CALENDAR_SYNC_TOKEN_KEY);
  return email;
}

/** True while some origin of this meeting is on a selected calendar of a connected account. */
export async function hasVisibleOrigin(db: D1Database, eventId: string): Promise<boolean> {
  const row = await db
    .prepare(`SELECT 1 AS ok FROM calendar_event_origin o
              JOIN google_calendar g ON g.account_email = o.account_email AND g.calendar_id = o.calendar_id
              WHERE o.event_id = ? AND g.selected = 1 LIMIT 1`)
    .bind(eventId)
    .first<{ ok: number }>();
  return Boolean(row);
}

export async function tombstoneGoogleEvent(db: D1Database, id: string, at: string): Promise<boolean> {
  const res = await db
    .prepare(`UPDATE calendar_event SET deleted_at = ?, updated_at = ?
              WHERE id = ? AND source = ? AND deleted_at IS NULL`)
    .bind(at, at, id, SOURCE_GOOGLE)
    .run();
  return Number(res?.meta?.changes ?? 0) > 0;
}

/** Hide a meeting when no selected calendar still has it. True when it was hidden now. */
export async function releaseIfOrphan(db: D1Database, eventId: string, at: string): Promise<boolean> {
  if (await hasVisibleOrigin(db, eventId)) return false;
  return tombstoneGoogleEvent(db, eventId, at);
}

async function originEventIds(db: D1Database, account: string, calendarId?: string): Promise<string[]> {
  const { results } = await db
    .prepare(`SELECT DISTINCT event_id FROM calendar_event_origin
              WHERE account_email = ? ${calendarId != null ? "AND calendar_id = ?" : ""}`)
    .bind(...(calendarId != null ? [account, calendarId] : [account]))
    .all<{ event_id: string }>();
  return (results ?? []).map((r) => r.event_id);
}

/** Hide the meetings only this calendar had. History stays stored for when it is chosen again. */
async function hideCalendarEvents(db: D1Database, account: string, calendarId: string, at: string): Promise<number> {
  let hidden = 0;
  for (const id of await originEventIds(db, account, calendarId)) {
    if (await releaseIfOrphan(db, id, at)) hidden += 1;
  }
  return hidden;
}

/** Show again every stored meeting this calendar has (cancelled ones have no origin left). */
async function reviveCalendarEvents(db: D1Database, account: string, calendarId: string, at: string): Promise<number> {
  const res = await db
    .prepare(`UPDATE calendar_event SET deleted_at = NULL, updated_at = ?
              WHERE source = ? AND deleted_at IS NOT NULL AND id IN (
                SELECT event_id FROM calendar_event_origin WHERE account_email = ? AND calendar_id = ?)`)
    .bind(at, SOURCE_GOOGLE, account, calendarId)
    .run();
  return Number(res?.meta?.changes ?? 0);
}

export class CalendarNotFoundError extends Error {
  constructor(account: string, calendarId: string) {
    super(`no calendar ${calendarId} on ${account}`);
    this.name = "CalendarNotFoundError";
  }
}

/**
 * Choose or drop one calendar. Dropping hides its meetings (unless another
 * selected calendar has them) and forgets its sync token, so choosing it
 * again shows them at once and the next sync lists its window in full.
 */
export async function setCalendarSelected(
  db: D1Database, account: string, calendarId: string, selected: boolean, at: string = new Date().toISOString(),
): Promise<{ changed: boolean; hidden: number; shown: number }> {
  const row = await getCalendarRow(db, account, calendarId);
  if (!row) throw new CalendarNotFoundError(account, calendarId);
  if (Boolean(row.selected) === selected) return { changed: false, hidden: 0, shown: 0 };
  await db
    .prepare(`UPDATE google_calendar SET selected = ?, sync_token = NULL, last_error = NULL, updated_at = ?
              WHERE account_email = ? AND calendar_id = ?`)
    .bind(selected ? 1 : 0, at, account, calendarId)
    .run();
  if (selected) return { changed: true, hidden: 0, shown: await reviveCalendarEvents(db, account, calendarId, at) };
  return { changed: true, hidden: await hideCalendarEvents(db, account, calendarId, at), shown: 0 };
}

/** Forget a calendar (gone from the account's list): its origins, then its row. */
async function removeCalendar(db: D1Database, account: string, calendarId: string, at: string): Promise<number> {
  const ids = await originEventIds(db, account, calendarId);
  await db.prepare(`DELETE FROM calendar_event_origin WHERE account_email = ? AND calendar_id = ?`)
    .bind(account, calendarId).run();
  await db.prepare(`DELETE FROM google_calendar WHERE account_email = ? AND calendar_id = ?`)
    .bind(account, calendarId).run();
  let hidden = 0;
  for (const id of ids) if (await releaseIfOrphan(db, id, at)) hidden += 1;
  return hidden;
}

/**
 * After a sync pass over one calendar: if the calendar was dropped (or its
 * account disconnected) while the pass ran, the pass may have shown its
 * meetings again. Hide them now, the way dropping it would have. Returns true
 * while the calendar is still chosen.
 */
export async function settleAfterPass(
  db: D1Database, account: string, calendarId: string, at: string,
): Promise<boolean> {
  const row = await getCalendarRow(db, account, calendarId);
  if (row?.selected) return true;
  if (row) await hideCalendarEvents(db, account, calendarId, at);
  else await removeCalendar(db, account, calendarId, at);
  return false;
}

/**
 * Read the account's calendar list from Google and store it. New calendars
 * start unselected (the primary starts selected). Calendars that left the
 * list are forgotten and their meetings hidden. Free/busy-only calendars are
 * skipped: their events cannot be read.
 */
export async function refreshCalendarList(
  env: Env, account: string, opts: { at?: string; fetchImpl?: GoogleFetch } = {},
): Promise<GoogleCalendarRow[]> {
  const at = opts.at ?? new Date().toISOString();
  const entries = (await listCalendars(env, account, opts.fetchImpl ?? googleFetch))
    .filter((c) => c.accessRole !== "freeBusyReader");
  const seen = new Set<string>();
  for (const c of entries) {
    seen.add(c.id);
    const primary = c.primary === true || c.id === account;
    await env.DB.prepare(
      `INSERT INTO google_calendar (account_email, calendar_id, summary, is_primary, access_role, color, selected, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (account_email, calendar_id) DO UPDATE SET
         summary = excluded.summary, is_primary = excluded.is_primary, access_role = excluded.access_role,
         color = excluded.color, updated_at = excluded.updated_at`,
    ).bind(
      account, c.id, (c.summaryOverride || c.summary || c.id).trim(), primary ? 1 : 0,
      c.accessRole ?? null, c.backgroundColor ?? null, primary ? 1 : 0, at,
    ).run();
  }
  for (const row of await listCalendarRows(env.DB, account)) {
    // The primary never leaves: it is the account itself.
    if (!seen.has(row.calendar_id) && !row.is_primary) await removeCalendar(env.DB, account, row.calendar_id, at);
  }
  return listCalendarRows(env.DB, account);
}

/**
 * Disconnect an account: delete its tokens, its calendars and its origins,
 * and hide every meeting no other connected calendar still has. The rows stay
 * as tombstones (the way every other deletion here works), so reconnecting
 * brings the recent window back with one sync. The address keeps counting as
 * the owner on meetings already stored.
 */
export async function disconnectAccount(
  env: Env, rawEmail: string, at: string = new Date().toISOString(),
): Promise<{ removed: boolean; hidden: number }> {
  const email = normalizeEmail(rawEmail);
  if (!email) return { removed: false, hidden: 0 };
  const exists = await env.DB.prepare(`SELECT email FROM google_account WHERE email = ?`)
    .bind(email).first<{ email: string }>();
  await deleteGoogleAccountTokens(env, email);
  if (!exists) return { removed: false, hidden: 0 };
  const ids = await originEventIds(env.DB, email);
  await env.DB.prepare(`DELETE FROM calendar_event_origin WHERE account_email = ?`).bind(email).run();
  await env.DB.prepare(`DELETE FROM google_calendar WHERE account_email = ?`).bind(email).run();
  await env.DB.prepare(`DELETE FROM google_account WHERE email = ?`).bind(email).run();
  let hidden = 0;
  for (const id of ids) if (await releaseIfOrphan(env.DB, id, at)) hidden += 1;
  return { removed: true, hidden };
}

export async function recordAccountSync(
  db: D1Database, account: string, at: string, error: string | null,
): Promise<void> {
  await db
    .prepare(`UPDATE google_account SET last_sync_at = CASE WHEN ? IS NULL THEN ? ELSE last_sync_at END,
                                        last_error = ?, updated_at = ?
              WHERE email = ?`)
    .bind(error, at, error, at, account)
    .run();
}
