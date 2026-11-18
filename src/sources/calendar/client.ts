import type { Env } from "../../env.ts";
import { DEFAULT_TIME_ZONE, localDayRangeUtc } from "../../lib/time.ts";
import { getGoogleTokens, getValidGoogleAccessToken, refreshGoogleToken } from "../../lib/tokens.ts";
import { GOOGLE_CALENDAR_EVENTS } from "./endpoints.ts";
import type { GoogleCalendarEvent } from "./project.ts";

export class GoogleAuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "GoogleAuthError";
  }
}

async function googleFetch(env: Env, url: string, token: string): Promise<Response> {
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (res.status === 401) {
    const bundle = await getGoogleTokens(env);
    if (!bundle) throw new GoogleAuthError("google 401 and no tokens");
    const next = await refreshGoogleToken(env, bundle);
    const retry = await fetch(url, { headers: { Authorization: `Bearer ${next}` } });
    if (!retry.ok) throw new Error(`google ${retry.status} after refresh: ${await retry.text()}`);
    return retry;
  }
  if (!res.ok) throw new Error(`google ${res.status}: ${await res.text()}`);
  return res;
}

/**
 * List primary-calendar instances in [startDay, endDay] (inclusive local days
 * in `timeZone`). Bounds are local midnights, not UTC midnights — UTC
 * `T00:00:00Z`/`T23:59:59Z` drops ~20:00+ ET on the last day.
 * `singleEvents=true` expands recurrences. Google `timeMax` is exclusive.
 */
export async function listPrimaryEvents(
  env: Env,
  window: { start: string; end: string },
  timeZone: string = DEFAULT_TIME_ZONE,
): Promise<GoogleCalendarEvent[]> {
  const token = await getValidGoogleAccessToken(env);
  const range = localDayRangeUtc(window.start, window.end, timeZone);
  const out: GoogleCalendarEvent[] = [];
  let pageToken: string | null = null;
  do {
    const params = new URLSearchParams({
      timeMin: range.startUtc,
      timeMax: range.endUtcExclusive,
      singleEvents: "true",
      orderBy: "startTime",
      maxResults: "250",
    });
    if (pageToken) params.set("pageToken", pageToken);
    const res = await googleFetch(env, `${GOOGLE_CALENDAR_EVENTS}?${params.toString()}`, token);
    const json = (await res.json()) as {
      items?: GoogleCalendarEvent[];
      nextPageToken?: string;
    };
    if (Array.isArray(json.items)) out.push(...json.items);
    pageToken = json.nextPageToken ?? null;
  } while (pageToken);
  return out;
}
