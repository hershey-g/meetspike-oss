/** Google Calendar OAuth + Calendar API v3. Scope is readonly only. */

export const GOOGLE_AUTHORIZE = "https://accounts.google.com/o/oauth2/v2/auth";
export const GOOGLE_TOKEN = "https://oauth2.googleapis.com/token";
export const GOOGLE_CALENDAR_EVENTS = "https://www.googleapis.com/calendar/v3/calendars/primary/events";

export const GOOGLE_SCOPES = ["https://www.googleapis.com/auth/calendar.readonly"] as const;

export const GOOGLE_TOKEN_KEY = "google:tokens";
export const GOOGLE_STATE_PREFIX = "oauth:google:state:";
