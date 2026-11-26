import type { Env } from "../../env.ts";
import type { CalendarEventRow } from "../../types.ts";
import { SOURCE_GOOGLE, SOURCE_SANDBOX_CAL } from "../../types.ts";
import { canonicalJson, r2Key, sha256Hex } from "../../lib/hash.ts";
import { findRaw, insertRaw, loadTimeZone, upsertCalendarEvent } from "../../lib/db.ts";
import { addCalendarDays, calendarDayInZone, localDayRangeUtc, nowIso } from "../../lib/time.ts";
import { putRawJson } from "../../lib/r2.ts";
import { writeSyncLog } from "../../lib/synclog.ts";
import { googleFetch, listEventChanges, SyncTokenExpiredError, type EventPage, type GoogleFetch } from "./client.ts";
import {
  LEGACY_CALENDAR_SYNC_TOKEN_KEY,
  listAccounts,
  listCalendarRows,
  migrateLegacyGoogleTokens,
  recordAccountSync,
  refreshCalendarList,
  releaseIfOrphan,
  settleAfterPass,
  type GoogleCalendarRow,
} from "./accounts.ts";
import { makeCalendarFixtures } from "./fixtures.ts";
import { projectGoogleEvent, type GoogleCalendarEvent } from "./project.ts";

export type IngestTally = { written: number; skipped: number };

/** Archive the event JSON in R2 once per distinct body. Returns the raw_object id. */
async function archiveEvent(
  env: Env, event: GoogleCalendarEvent, source: CalendarEventRow["source"], fetchedAt: string,
): Promise<number | null> {
  const body = canonicalJson(event);
  const hash = await sha256Hex(body);
  const documentId = event.id ?? hash.slice(0, 16);
  const existing = await findRaw(env.DB, "events", documentId, hash, source);
  if (existing) return existing.id;
  const key = r2Key(source, "events", documentId, hash);
  await putRawJson(env, key, body);
  return insertRaw(
    env.DB,
    {
      endpoint: "events",
      documentId,
      day: event.start?.date ?? event.start?.dateTime?.slice(0, 10) ?? null,
      r2Key: key,
      hash,
      fetchedAt,
    },
    source,
  );
}

/** Sandbox fixtures (and anything without a calendar origin): one row per event id. */
export async function ingestCalendarEvent(
  env: Env,
  event: GoogleCalendarEvent,
  opts: { source: CalendarEventRow["source"]; timeZone: string; fetchedAt?: string },
): Promise<"written" | "skipped"> {
  const fetchedAt = opts.fetchedAt ?? nowIso();
  const rawId = await archiveEvent(env, event, opts.source, fetchedAt);
  const row = projectGoogleEvent(event, fetchedAt, opts.timeZone, rawId, opts.source);
  if (!row) {
    // Incremental sync reports a deleted event as a bare {id, status:"cancelled"}
    // with no start/end. Tombstone the stored row so it leaves the day view.
    if (event.status === "cancelled" && event.id) {
      return (await tombstoneCalendarEvent(env.DB, event.id, opts.source, fetchedAt)) ? "written" : "skipped";
    }
    return "skipped";
  }
  return upsertCalendarEvent(env.DB, row);
}

/**
 * Every connected account is the owner. Google marks only the address of the
 * calendar it was read from as `self`, so the same meeting read through the
 * Gmail account would list the Workspace address as another person.
 */
export function markSelfAttendees(event: GoogleCalendarEvent, selfEmails: ReadonlySet<string>): GoogleCalendarEvent {
  if (!selfEmails.size) return event;
  const isSelf = (email: string | undefined) => Boolean(email && selfEmails.has(email.trim().toLowerCase()));
  const attendees = event.attendees?.map((a) => (isSelf(a.email) && !a.self ? { ...a, self: true } : a));
  const organizer = event.organizer && isSelf(event.organizer.email) && !event.organizer.self
    ? { ...event.organizer, self: true }
    : event.organizer;
  return { ...event, ...(attendees ? { attendees } : {}), ...(organizer ? { organizer } : {}) };
}

export type OccurrenceContext = {
  account: string;
  calendarId: string;
  timeZone: string;
  fetchedAt: string;
  selfEmails: ReadonlySet<string>;
  /** The account's own main calendar. Its copy of a meeting is the full one. */
  primary?: boolean;
};

/**
 * One event as read from one calendar of one account.
 *
 * The meeting row (calendar_event, source google) is shared: copies on other
 * calendars or accounts with the same Google event id, or the same iCalUID
 * and start, point at the row that already exists instead of adding a second
 * one, so heart rate, people and companies count the meeting once. The
 * origin row records that this calendar has it. A cancelled copy drops its
 * origin, and the meeting is hidden only when no selected calendar has it.
 */
export async function ingestGoogleOccurrence(
  env: Env, event: GoogleCalendarEvent, ctx: OccurrenceContext,
): Promise<"written" | "skipped"> {
  if (!event.id) return "skipped";
  const db = env.DB;
  const marked = markSelfAttendees(event, ctx.selfEmails);
  const rawId = await archiveEvent(env, marked, SOURCE_GOOGLE, ctx.fetchedAt);
  const own = await db
    .prepare(`SELECT event_id FROM calendar_event_origin
              WHERE account_email = ? AND calendar_id = ? AND google_event_id = ?`)
    .bind(ctx.account, ctx.calendarId, event.id)
    .first<{ event_id: string }>();

  const row = event.status === "cancelled" ? null : projectGoogleEvent(marked, ctx.fetchedAt, ctx.timeZone, rawId, SOURCE_GOOGLE);
  if (!row) {
    if (event.status !== "cancelled") return "skipped";
    if (own) {
      await db
        .prepare(`DELETE FROM calendar_event_origin WHERE account_email = ? AND calendar_id = ? AND google_event_id = ?`)
        .bind(ctx.account, ctx.calendarId, event.id)
        .run();
    }
    return (await releaseIfOrphan(db, own?.event_id ?? event.id, ctx.fetchedAt)) ? "written" : "skipped";
  }

  const ical = typeof event.iCalUID === "string" && event.iCalUID.trim() ? event.iCalUID.trim() : null;
  let canonical = own?.event_id ?? null;
  if (!canonical) {
    const dup = await db
      .prepare(`SELECT event_id FROM calendar_event_origin
                WHERE NOT (account_email = ? AND calendar_id = ?)
                  AND (event_id = ? OR google_event_id = ? OR (ical_uid IS NOT NULL AND ical_uid = ? AND start_utc = ?))
                ORDER BY CASE WHEN event_id = ? THEN 0 ELSE 1 END, updated_at
                LIMIT 1`)
      .bind(ctx.account, ctx.calendarId, event.id, event.id, ical, row.start_utc, event.id)
      .first<{ event_id: string }>();
    canonical = dup?.event_id ?? event.id;
  }
  await db
    .prepare(`INSERT INTO calendar_event_origin
                (account_email, calendar_id, google_event_id, event_id, ical_uid, start_utc, updated_at)
              VALUES (?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT (account_email, calendar_id, google_event_id) DO UPDATE SET
                event_id = excluded.event_id, ical_uid = excluded.ical_uid,
                start_utc = excluded.start_utc, updated_at = excluded.updated_at`)
    .bind(ctx.account, ctx.calendarId, event.id, canonical, ical, row.start_utc, ctx.fetchedAt)
    .run();
  if (!ctx.primary) {
    // Another calendar's copy (a shared, team or resource calendar) can be
    // sparse: Google hides a private event's title and guests from readers.
    // When a chosen main calendar of a connected account has this meeting,
    // its copy is the full one, so this copy only records its origin.
    const main = await db
      .prepare(`SELECT 1 AS ok FROM calendar_event_origin o
                JOIN google_calendar g ON g.account_email = o.account_email AND g.calendar_id = o.calendar_id
                WHERE o.event_id = ? AND g.selected = 1 AND g.is_primary = 1
                  AND NOT (o.account_email = ? AND o.calendar_id = ?) LIMIT 1`)
      .bind(canonical, ctx.account, ctx.calendarId)
      .first<{ ok: number }>();
    if (main) return "skipped";
  }
  return upsertCalendarEvent(db, { ...row, id: canonical });
}

export async function ingestCalendarFixtures(env: Env, trigger = "calendar-fixtures"): Promise<IngestTally> {
  const timeZone = await loadTimeZone(env.DB);
  const tally: IngestTally = { written: 0, skipped: 0 };
  for (const event of makeCalendarFixtures()) {
    const r = await ingestCalendarEvent(env, event, { source: SOURCE_SANDBOX_CAL, timeZone });
    if (r === "written") tally.written += 1;
    else tally.skipped += 1;
  }
  await writeSyncLog(env, {
    trigger,
    source: SOURCE_SANDBOX_CAL,
    endpoint: "events",
    status: "ok",
    rowsWritten: tally.written,
    rowsSkipped: tally.skipped,
  });
  return tally;
}

/** Legacy KV key for the single calendar's nextSyncToken. Sync tokens now live per calendar in D1. */
export const CALENDAR_SYNC_TOKEN_KEY = LEGACY_CALENDAR_SYNC_TOKEN_KEY;
/** Full-sync window around today, in local days. Incremental passes are not windowed. */
export const FULL_SYNC_PAST_DAYS = 21;
export const FULL_SYNC_FUTURE_DAYS = 30;

export async function tombstoneCalendarEvent(
  db: D1Database,
  id: string,
  source: string,
  at: string,
): Promise<boolean> {
  const res = await db
    .prepare(
      `UPDATE calendar_event SET deleted_at = ?, updated_at = ?
       WHERE id = ? AND source = ? AND deleted_at IS NULL`,
    )
    .bind(at, at, id, source)
    .run();
  return Number(res?.meta?.changes ?? 0) > 0;
}

export type CalendarSyncMode = "incremental" | "full";
export type CalendarSyncReason = "no_token" | "token_expired" | "forced";

export type CalendarPassResult = IngestTally & {
  account: string;
  calendarId: string;
  mode: CalendarSyncMode;
  reason?: CalendarSyncReason;
  removed: number;
  error?: string;
};

export type CalendarSyncResult = IngestTally & {
  /** "full" when any calendar was listed in full this pass. */
  mode: CalendarSyncMode;
  /** Why a full sync ran: no token yet, Google said 410, or the caller forced it. */
  reason?: CalendarSyncReason;
  /** Stored meetings in a full-sync window that Google no longer lists. */
  removed: number;
  syncedAt: string;
  /** One entry per calendar synced (selected calendars of every connected account). */
  calendars: CalendarPassResult[];
  /** Calendars or accounts that failed this pass while others succeeded. */
  errors?: Array<{ account: string; calendarId?: string; error: string }>;
};

type PassOptions = {
  force: boolean;
  fetchedAt: string;
  timeZone: string;
  selfEmails: ReadonlySet<string>;
  fetchImpl: GoogleFetch;
};

/**
 * Bring one calendar up to date.
 *
 * Uses Google's incremental sync: the calendar's stored `nextSyncToken`
 * returns only what changed (new, moved, edited or cancelled events, any
 * date), which is one cheap request when nothing changed. Without a token,
 * after a 410, or when `force` is set, it lists the whole window
 * [today-21, today+30] instead, drops this calendar's origins in that window
 * Google no longer has, and keeps the new token for next time.
 */
async function syncOneCalendar(env: Env, cal: GoogleCalendarRow, opts: PassOptions): Promise<CalendarPassResult> {
  const { account_email: account, calendar_id: calendarId } = cal;
  const stored = opts.force ? null : cal.sync_token;
  let mode: CalendarSyncMode = "incremental";
  let reason: CalendarSyncReason | undefined = opts.force ? "forced" : stored ? undefined : "no_token";
  let page: EventPage | null = null;
  if (stored) {
    try {
      page = await listEventChanges(env, account, calendarId, { syncToken: stored }, opts.fetchImpl);
    } catch (err) {
      if (!(err instanceof SyncTokenExpiredError)) throw err;
      reason = "token_expired";
    }
  }

  const today = calendarDayInZone(opts.fetchedAt, opts.timeZone);
  const range = localDayRangeUtc(
    addCalendarDays(today, -FULL_SYNC_PAST_DAYS), addCalendarDays(today, FULL_SYNC_FUTURE_DAYS), opts.timeZone,
  );
  if (!page) {
    mode = "full";
    page = await listEventChanges(
      env, account, calendarId, { timeMin: range.startUtc, timeMax: range.endUtcExclusive }, opts.fetchImpl,
    );
  }

  const ctx: OccurrenceContext = {
    account, calendarId, timeZone: opts.timeZone, fetchedAt: opts.fetchedAt, selfEmails: opts.selfEmails,
    primary: Boolean(cal.is_primary),
  };
  const tally: IngestTally = { written: 0, skipped: 0 };
  const seen = new Set<string>();
  for (const event of page.items) {
    if (event.id) seen.add(event.id);
    const r = await ingestGoogleOccurrence(env, event, ctx);
    if (r === "written") tally.written += 1;
    else tally.skipped += 1;
  }

  let removed = 0;
  if (mode === "full") {
    // A full listing is the truth for its window: anything this calendar had
    // there that Google did not return (even as cancelled) was deleted.
    const { results } = await env.DB.prepare(
      `SELECT google_event_id, event_id FROM calendar_event_origin
       WHERE account_email = ? AND calendar_id = ? AND start_utc >= ? AND start_utc < ?`,
    )
      .bind(account, calendarId, range.startUtc, range.endUtcExclusive)
      .all<{ google_event_id: string; event_id: string }>();
    for (const row of results ?? []) {
      if (seen.has(row.google_event_id)) continue;
      await env.DB.prepare(
        `DELETE FROM calendar_event_origin WHERE account_email = ? AND calendar_id = ? AND google_event_id = ?`,
      ).bind(account, calendarId, row.google_event_id).run();
      if (await releaseIfOrphan(env.DB, row.event_id, opts.fetchedAt)) removed += 1;
    }
  }

  // Dropped or disconnected while this pass ran: hide what the pass showed
  // and keep no token, as if the pass had not happened.
  if (!(await settleAfterPass(env.DB, account, calendarId, opts.fetchedAt))) {
    return { account, calendarId, mode, ...(reason ? { reason } : {}), ...tally, removed };
  }
  await env.DB.prepare(
    `UPDATE google_calendar SET sync_token = coalesce(?, CASE WHEN ? THEN NULL ELSE sync_token END),
                                last_sync_at = ?, last_error = NULL, updated_at = ?
     WHERE account_email = ? AND calendar_id = ? AND selected = 1`,
  ).bind(page.nextSyncToken, reason === "token_expired" ? 1 : 0, opts.fetchedAt, opts.fetchedAt, account, calendarId).run();

  return { account, calendarId, mode, ...(reason ? { reason } : {}), ...tally, removed };
}

function errorText(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** How a failed move of the old single-account token is named in sync errors. */
const LEGACY_ACCOUNT_LABEL = "google:tokens (old sign-in, not moved yet)";

/**
 * Move the old single-account token, then list the connected accounts. A move
 * that fails (Google down, or that old sign-in revoked) leaves the old key in
 * place and is retried next pass; it only stops the sync when no account is
 * connected yet, so it cannot block accounts signed in since.
 */
async function accountsAfterLegacyMove(
  env: Env, at: string,
): Promise<{ accounts: Awaited<ReturnType<typeof listAccounts>>; legacyError: string | null }> {
  let moveError: unknown = null;
  try {
    await migrateLegacyGoogleTokens(env, at);
  } catch (err) {
    moveError = err;
  }
  const accounts = await listAccounts(env.DB);
  if (!accounts.length) {
    if (moveError) throw moveError;
    throw new Error("no google tokens: connect Google at /auth/google/start");
  }
  return { accounts, legacyError: moveError ? errorText(moveError) : null };
}

/**
 * Sync every selected calendar of every connected Google account.
 *
 * Moves the old single-account token first (no new sign-in). The calendar
 * list is read from Google when an account has none stored yet, and on a
 * forced pass (the daily reconcile). One calendar or account failing does not
 * stop the others; when every calendar fails the first error is thrown, so
 * callers report it the way they did with one calendar.
 */
export async function syncCalendarIncremental(
  env: Env,
  trigger = "calendar-sync",
  opts: { force?: boolean; now?: Date; fetchImpl?: GoogleFetch } = {},
): Promise<CalendarSyncResult> {
  const now = opts.now ?? new Date();
  const fetchedAt = now.toISOString();
  const fetchImpl = opts.fetchImpl ?? googleFetch;
  const { accounts, legacyError } = await accountsAfterLegacyMove(env, fetchedAt);
  const timeZone = await loadTimeZone(env.DB);
  const selfEmails = new Set(accounts.map((a) => a.email));
  const pass: PassOptions = { force: opts.force === true, fetchedAt, timeZone, selfEmails, fetchImpl };

  const calendars: CalendarPassResult[] = [];
  const errors: NonNullable<CalendarSyncResult["errors"]> = [];
  if (legacyError) errors.push({ account: LEGACY_ACCOUNT_LABEL, error: legacyError });
  const thrown: unknown[] = [];
  let attempted = 0;
  for (const account of accounts) {
    let rows = await listCalendarRows(env.DB, account.email);
    if (!rows.length || pass.force) {
      try {
        rows = await refreshCalendarList(env, account.email, { at: fetchedAt, fetchImpl });
      } catch (err) {
        // Keep going with what is stored; the events pass reports auth trouble too.
        errors.push({ account: account.email, error: `calendar list: ${errorText(err)}` });
      }
    }
    let accountError: string | null = null;
    for (const cal of rows.filter((r) => r.selected)) {
      attempted += 1;
      try {
        calendars.push(await syncOneCalendar(env, cal, pass));
      } catch (err) {
        const message = errorText(err);
        thrown.push(err);
        accountError ??= message;
        errors.push({ account: account.email, calendarId: cal.calendar_id, error: message });
        calendars.push({
          account: account.email, calendarId: cal.calendar_id, mode: "incremental", written: 0, skipped: 0, removed: 0,
          error: message,
        });
        await env.DB.prepare(
          `UPDATE google_calendar SET last_error = ?, updated_at = ? WHERE account_email = ? AND calendar_id = ?`,
        ).bind(message.slice(0, 500), fetchedAt, account.email, cal.calendar_id).run();
      }
    }
    await recordAccountSync(env.DB, account.email, fetchedAt, accountError ? accountError.slice(0, 500) : null);
  }
  if (attempted > 0 && thrown.length === attempted) throw thrown[0];

  const ok = calendars.filter((c) => !c.error);
  const full = ok.find((c) => c.mode === "full");
  const result: CalendarSyncResult = {
    written: ok.reduce((n, c) => n + c.written, 0),
    skipped: ok.reduce((n, c) => n + c.skipped, 0),
    removed: ok.reduce((n, c) => n + c.removed, 0),
    mode: full ? "full" : "incremental",
    ...(full?.reason ? { reason: full.reason } : {}),
    syncedAt: fetchedAt,
    calendars,
    ...(errors.length ? { errors } : {}),
  };
  await writeSyncLog(env, {
    trigger,
    source: SOURCE_GOOGLE,
    endpoint: full ? "events:full" : "events:incremental",
    status: errors.length ? "error" : "ok",
    rowsWritten: result.written + result.removed,
    rowsSkipped: result.skipped,
    ...(errors.length ? { errorText: errors.map((e) => `${e.account}${e.calendarId ? ` ${e.calendarId}` : ""}: ${e.error}`).join("; ").slice(0, 1000) } : {}),
  });
  return result;
}

/**
 * Re-list exactly [start, end] (local days) on every selected calendar, for
 * backfill or repair. Does not touch sync tokens and does not sweep.
 */
export async function syncCalendarWindow(
  env: Env,
  window: { start: string; end: string },
  trigger = "calendar-sync",
  opts: { fetchImpl?: GoogleFetch } = {},
): Promise<IngestTally> {
  const fetchedAt = nowIso();
  const fetchImpl = opts.fetchImpl ?? googleFetch;
  const { accounts } = await accountsAfterLegacyMove(env, fetchedAt);
  const timeZone = await loadTimeZone(env.DB);
  const selfEmails = new Set(accounts.map((a) => a.email));
  const range = localDayRangeUtc(window.start, window.end, timeZone);
  const tally: IngestTally = { written: 0, skipped: 0 };
  for (const account of accounts) {
    for (const cal of (await listCalendarRows(env.DB, account.email)).filter((r) => r.selected)) {
      const page = await listEventChanges(
        env, account.email, cal.calendar_id, { timeMin: range.startUtc, timeMax: range.endUtcExclusive }, fetchImpl,
      );
      const ctx: OccurrenceContext = {
        account: account.email, calendarId: cal.calendar_id, timeZone, fetchedAt, selfEmails, primary: Boolean(cal.is_primary),
      };
      for (const event of page.items) {
        const r = await ingestGoogleOccurrence(env, event, ctx);
        if (r === "written") tally.written += 1;
        else tally.skipped += 1;
      }
      await settleAfterPass(env.DB, account.email, cal.calendar_id, fetchedAt);
    }
  }
  await writeSyncLog(env, {
    trigger,
    source: SOURCE_GOOGLE,
    endpoint: "events",
    windowStart: window.start,
    windowEnd: window.end,
    status: "ok",
    rowsWritten: tally.written,
    rowsSkipped: tally.skipped,
  });
  return tally;
}
