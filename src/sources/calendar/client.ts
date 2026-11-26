import type { Env } from "../../env.ts";
import { getGoogleAccountTokens, getValidGoogleAccessToken, refreshGoogleToken } from "../../lib/tokens.ts";
import { calendarEventsUrl, GOOGLE_CALENDAR_LIST, GOOGLE_PRIMARY_CALENDAR } from "./endpoints.ts";
import type { GoogleCalendarEvent } from "./project.ts";

export class GoogleAuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "GoogleAuthError";
  }
}

/** Google answered 410 Gone: the stored sync token is no longer valid. Do a full sync. */
export class SyncTokenExpiredError extends Error {
  constructor() {
    super("google sync token expired (410)");
    this.name = "SyncTokenExpiredError";
  }
}

export type GoogleFetch = (env: Env, account: string, url: string, token: string) => Promise<Response>;

/**
 * GET with one account's access token. A 401 refreshes that account's token
 * once and retries. A 410 becomes SyncTokenExpiredError so a sync can fall
 * back to a full listing.
 */
export const googleFetch: GoogleFetch = async (env, account, url, token) => {
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (res.status === 410) throw new SyncTokenExpiredError();
  if (res.status === 401) {
    const bundle = await getGoogleAccountTokens(env, account);
    if (!bundle) throw new GoogleAuthError(`google 401 and no tokens for ${account}`);
    const next = await refreshGoogleToken(env, account, bundle);
    const retry = await fetch(url, { headers: { Authorization: `Bearer ${next}` } });
    if (retry.status === 410) throw new SyncTokenExpiredError();
    if (!retry.ok) throw new Error(`google ${retry.status} after refresh: ${await retry.text()}`);
    return retry;
  }
  if (!res.ok) throw new Error(`google ${res.status}: ${await res.text()}`);
  return res;
};

/**
 * The email address an access token belongs to: the id of its primary
 * calendar. Needs only calendar.readonly.
 */
export async function fetchAccountEmail(accessToken: string): Promise<string> {
  const res = await fetch(GOOGLE_PRIMARY_CALENDAR, { headers: { Authorization: `Bearer ${accessToken}` } });
  if (res.status === 401) throw new GoogleAuthError("google 401 reading the primary calendar");
  if (!res.ok) throw new Error(`google ${res.status}: ${await res.text()}`);
  const json = (await res.json()) as { id?: string };
  const email = typeof json.id === "string" ? json.id.trim().toLowerCase() : "";
  if (!email.includes("@")) throw new Error("google did not name the account (primary calendar has no address id)");
  return email;
}

export type GoogleCalendarListEntry = {
  id: string;
  summary?: string;
  summaryOverride?: string;
  primary?: boolean;
  accessRole?: string;
  backgroundColor?: string;
  deleted?: boolean;
};

/** Every calendar on the account's calendar list, following pages. */
export async function listCalendars(
  env: Env,
  account: string,
  fetchImpl: GoogleFetch = googleFetch,
): Promise<GoogleCalendarListEntry[]> {
  const token = await getValidGoogleAccessToken(env, account);
  const out: GoogleCalendarListEntry[] = [];
  let pageToken: string | null = null;
  do {
    const params = new URLSearchParams({ maxResults: "250" });
    if (pageToken) params.set("pageToken", pageToken);
    const res = await fetchImpl(env, account, `${GOOGLE_CALENDAR_LIST}?${params.toString()}`, token);
    const json = (await res.json()) as { items?: GoogleCalendarListEntry[]; nextPageToken?: string };
    for (const item of json.items ?? []) {
      if (item && typeof item.id === "string" && !item.deleted) out.push(item);
    }
    pageToken = json.nextPageToken ?? null;
  } while (pageToken);
  return out;
}

export type EventPage = {
  items: GoogleCalendarEvent[];
  /** Present on the last page only. Missing means Google gave no token for this request. */
  nextSyncToken: string | null;
};

/**
 * One sync pass over one calendar of one account, following every page.
 *
 * - With `syncToken`: only what changed since that token (adds, moves,
 *   attendee edits and cancellations). Google forbids timeMin/timeMax/orderBy
 *   alongside a sync token, so none are sent.
 * - Without: a full listing of [timeMin, timeMax). `showDeleted` so
 *   cancellations inside the window come back and can be tombstoned. No
 *   `orderBy`: the projector does not care about order, and the last page then
 *   carries the `nextSyncToken` the next incremental pass starts from.
 *
 * `singleEvents=true` on both, as Google requires the same flags each time.
 */
export async function listEventChanges(
  env: Env,
  account: string,
  calendarId: string,
  opts: { syncToken: string } | { timeMin: string; timeMax: string },
  fetchImpl: GoogleFetch = googleFetch,
): Promise<EventPage> {
  const token = await getValidGoogleAccessToken(env, account);
  const items: GoogleCalendarEvent[] = [];
  let pageToken: string | null = null;
  let nextSyncToken: string | null = null;
  do {
    const params = new URLSearchParams({ singleEvents: "true", maxResults: "250" });
    if ("syncToken" in opts) {
      params.set("syncToken", opts.syncToken);
    } else {
      params.set("timeMin", opts.timeMin);
      params.set("timeMax", opts.timeMax);
      params.set("showDeleted", "true");
    }
    if (pageToken) params.set("pageToken", pageToken);
    const res = await fetchImpl(env, account, `${calendarEventsUrl(calendarId)}?${params.toString()}`, token);
    const json = (await res.json()) as {
      items?: GoogleCalendarEvent[];
      nextPageToken?: string;
      nextSyncToken?: string;
    };
    if (Array.isArray(json.items)) items.push(...json.items);
    pageToken = json.nextPageToken ?? null;
    if (json.nextSyncToken) nextSyncToken = json.nextSyncToken;
  } while (pageToken);
  return { items, nextSyncToken };
}
