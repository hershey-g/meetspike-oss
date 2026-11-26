/**
 * Google accounts and which of their calendars count as meetings.
 * Mounted at /api/calendars, behind Cloudflare Access with the rest of /api.
 *
 *   GET    /api/calendars                    accounts, their calendars, selection, last sync, errors
 *   PUT    /api/calendars/selection          { selections: [{ account, calendarId, selected }] }
 *   DELETE /api/calendars/accounts/:email    disconnect: tokens, calendars and its meetings
 */
import { Hono } from "hono";
import type { Env } from "../env.ts";
import { normalizeEmail } from "../lib/people.ts";
import {
  CalendarNotFoundError,
  disconnectAccount,
  listAccounts,
  listCalendarRows,
  migrateLegacyGoogleTokens,
  refreshCalendarList,
  setCalendarSelected,
} from "../sources/calendar/accounts.ts";
import { syncCalendarIncremental } from "../sources/calendar/ingest.ts";

export const calendars = new Hono<{ Bindings: Env }>();

export const GOOGLE_CONNECT_PATH = "/auth/google/start";
export const CALENDARS_SETUP_PATH = "/setup#calendars";

export type CalendarView = {
  id: string;
  name: string;
  primary: boolean;
  selected: boolean;
  color: string | null;
  accessRole: string | null;
  lastSyncAt: string | null;
  error: string | null;
};

export type AccountView = {
  email: string;
  connectedAt: string;
  lastSyncAt: string | null;
  error: string | null;
  calendars: CalendarView[];
};

export type CalendarsResponse = {
  ok: true;
  accounts: AccountView[];
  connectPath: string;
  setupPath: string;
  /** Set when the old single-account token could not be moved yet (Google unreachable or sign-in expired). */
  legacyError: string | null;
};

function message(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** Stored state, shaped for the setup page and the iPhone app. */
export async function calendarsState(env: Env, legacyError: string | null = null): Promise<CalendarsResponse> {
  const [accounts, rows] = await Promise.all([listAccounts(env.DB), listCalendarRows(env.DB)]);
  return {
    ok: true,
    accounts: accounts.map((a) => ({
      email: a.email,
      connectedAt: a.connected_at,
      lastSyncAt: a.last_sync_at,
      error: a.last_error,
      calendars: rows
        .filter((r) => r.account_email === a.email)
        .map((r) => ({
          id: r.calendar_id,
          name: r.summary?.trim() || r.calendar_id,
          primary: Boolean(r.is_primary),
          selected: Boolean(r.selected),
          color: r.color,
          accessRole: r.access_role,
          lastSyncAt: r.last_sync_at,
          error: r.last_error,
        })),
    })),
    connectPath: GOOGLE_CONNECT_PATH,
    setupPath: CALENDARS_SETUP_PATH,
    legacyError,
  };
}

/**
 * Moves an old single-account token if one is left, then (unless refresh=0)
 * reads each account's calendar list from Google so new calendars appear.
 * A Google failure is shown on that account, not as a failed request.
 */
calendars.get("/", async (c) => {
  let legacyError: string | null = null;
  try {
    await migrateLegacyGoogleTokens(c.env);
  } catch (err) {
    legacyError = message(err);
  }
  if (c.req.query("refresh") !== "0") {
    for (const account of await listAccounts(c.env.DB)) {
      try {
        await refreshCalendarList(c.env, account.email);
      } catch (err) {
        await c.env.DB.prepare(`UPDATE google_account SET last_error = ? WHERE email = ?`)
          .bind(`calendar list: ${message(err)}`.slice(0, 500), account.email).run();
      }
    }
  }
  c.header("Cache-Control", "private, no-store");
  return c.json(await calendarsState(c.env, legacyError));
});

type SelectionInput = { account?: unknown; calendarId?: unknown; selected?: unknown };

function parseSelections(body: unknown): Array<{ account: string; calendarId: string; selected: boolean }> | null {
  const raw = body && typeof body === "object" && Array.isArray((body as { selections?: unknown }).selections)
    ? ((body as { selections: SelectionInput[] }).selections)
    : body && typeof body === "object" && "calendarId" in (body as object)
      ? [body as SelectionInput]
      : null;
  if (!raw || !raw.length || raw.length > 200) return null;
  const out: Array<{ account: string; calendarId: string; selected: boolean }> = [];
  for (const s of raw) {
    if (!s || typeof s !== "object") return null;
    const account = typeof s.account === "string" ? normalizeEmail(s.account) : null;
    const calendarId = typeof s.calendarId === "string" ? s.calendarId.trim() : "";
    if (!account || !calendarId || calendarId.length > 400 || typeof s.selected !== "boolean") return null;
    out.push({ account, calendarId, selected: s.selected });
  }
  return out;
}

/**
 * Choose which calendars count. Dropping a calendar hides its meetings at
 * once (unless another chosen calendar has them). Choosing one shows what is
 * stored at once, then syncs so its recent window is filled in.
 */
calendars.put("/selection", async (c) => {
  const selections = parseSelections(await c.req.json().catch(() => null));
  if (!selections) {
    return c.json({ error: "send { selections: [{ account, calendarId, selected }] }" }, 400);
  }
  let changed = 0;
  let hidden = 0;
  let shown = 0;
  let added = false;
  for (const s of selections) {
    try {
      const r = await setCalendarSelected(c.env.DB, s.account, s.calendarId, s.selected);
      if (r.changed) changed += 1;
      if (r.changed && s.selected) added = true;
      hidden += r.hidden;
      shown += r.shown;
    } catch (err) {
      if (err instanceof CalendarNotFoundError) return c.json({ error: err.message }, 404);
      throw err;
    }
  }
  let syncError: string | null = null;
  if (added) {
    try {
      await syncCalendarIncremental(c.env, "calendar-selection");
    } catch (err) {
      syncError = message(err);
    }
  }
  return c.json({ ...(await calendarsState(c.env)), changed, hidden, shown, syncError });
});

calendars.delete("/accounts/:email", async (c) => {
  let raw: string;
  try {
    raw = decodeURIComponent(c.req.param("email"));
  } catch {
    return c.json({ error: "bad account address" }, 400);
  }
  const email = normalizeEmail(raw);
  if (!email) return c.json({ error: "bad account address" }, 400);
  const r = await disconnectAccount(c.env, email);
  if (!r.removed) return c.json({ error: `${email} is not connected` }, 404);
  return c.json({ ...(await calendarsState(c.env)), removed: true, hidden: r.hidden });
});
