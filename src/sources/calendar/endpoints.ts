/** Google Calendar OAuth + Calendar API v3. Scope is readonly only. */

export const GOOGLE_AUTHORIZE = "https://accounts.google.com/o/oauth2/v2/auth";
export const GOOGLE_TOKEN = "https://oauth2.googleapis.com/token";
export const GOOGLE_CALENDAR_API = "https://www.googleapis.com/calendar/v3";
/** The primary calendar's events (legacy single-calendar sync). */
export const GOOGLE_CALENDAR_EVENTS = `${GOOGLE_CALENDAR_API}/calendars/primary/events`;
/** Calendars the account can see. Covered by calendar.readonly. */
export const GOOGLE_CALENDAR_LIST = `${GOOGLE_CALENDAR_API}/users/me/calendarList`;
/**
 * The account's primary calendar. Its `id` is the account's email address,
 * which is how an account is named without asking for any scope beyond
 * calendar.readonly (no openid / email scope needed).
 */
export const GOOGLE_PRIMARY_CALENDAR = `${GOOGLE_CALENDAR_API}/calendars/primary`;

export function calendarEventsUrl(calendarId: string): string {
  return `${GOOGLE_CALENDAR_API}/calendars/${encodeURIComponent(calendarId)}/events`;
}

export const GOOGLE_SCOPES = ["https://www.googleapis.com/auth/calendar.readonly"] as const;

/** Legacy single-account KV key. Moved to googleTokenKey(email) on first run. */
export const GOOGLE_TOKEN_KEY = "google:tokens";
/** Per-account KV key prefix: google:tokens:<email>. */
export const GOOGLE_ACCOUNT_TOKEN_PREFIX = "google:tokens:";
export const GOOGLE_STATE_PREFIX = "oauth:google:state:";

export function googleTokenKey(email: string): string {
  return `${GOOGLE_ACCOUNT_TOKEN_PREFIX}${email}`;
}
