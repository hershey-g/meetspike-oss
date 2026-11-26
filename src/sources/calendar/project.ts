import {
  SOURCE_GOOGLE,
  SOURCE_SANDBOX_CAL,
  type CalendarEventRow,
} from "../../types.ts";
import {
  calendarDayInZone,
  DEFAULT_TIME_ZONE,
  localIsoFromWall,
  localWallInZone,
  offsetMinutesFromIso,
  toUtcIso,
  wallClockToUtcIso,
} from "../../lib/time.ts";
import { classifyTitle, durationSeconds, isAfterHours, type WorkKind } from "./classify.ts";
import { extractAttendees } from "../../lib/people.ts";

export type GoogleDate = {
  dateTime?: string;
  date?: string;
  timeZone?: string;
};

export type GoogleAttendee = {
  email?: string;
  self?: boolean;
  displayName?: string;
  name?: string;
  resource?: boolean;
  responseStatus?: string;
  organizer?: boolean;
};

export type GoogleCalendarEvent = {
  id?: string;
  /** Same for every copy of one meeting (other calendars, other accounts). With the start, the dedupe key. */
  iCalUID?: string;
  status?: string;
  summary?: string;
  location?: string;
  start?: GoogleDate;
  end?: GoogleDate;
  attendees?: GoogleAttendee[];
  organizer?: { email?: string; self?: boolean };
};

function domainOf(email: string | undefined): string | null {
  if (!email || !email.includes("@")) return null;
  return email.slice(email.indexOf("@") + 1).toLowerCase();
}

export function hasExternalAttendee(event: GoogleCalendarEvent): boolean {
  const attendees = event.attendees ?? [];
  if (attendees.length === 0) return false;
  const selfEmail = attendees.find((a) => a.self)?.email ?? event.organizer?.email;
  const selfDomain = domainOf(selfEmail);
  return attendees.some((a) => {
    if (a.self) return false;
    const d = domainOf(a.email);
    if (!d) return false;
    if (selfDomain && d === selfDomain) return false;
    return true;
  });
}

function parseBound(
  bound: GoogleDate | undefined,
  timeZone: string,
  role: "start" | "end",
): { utc: string; offsetMin: number } | null {
  if (!bound) return null;
  if (bound.dateTime) {
    const utc = toUtcIso(bound.dateTime);
    let offsetMin: number;
    try {
      offsetMin = offsetMinutesFromIso(bound.dateTime);
    } catch {
      offsetMin = localWallInZone(utc, bound.timeZone ?? timeZone).offsetMin;
    }
    return { utc, offsetMin };
  }
  if (bound.date) {
    const zone = bound.timeZone ?? timeZone;
    // All-day: midnight local → next midnight local. Offset taken at that local midnight.
    const noonUtc = toUtcIso(`${bound.date}T12:00:00Z`);
    const offsetMin = localWallInZone(noonUtc, zone).offsetMin;
    const localMidnight = `${bound.date}T00:00:00`;
    const utc =
      role === "end"
        ? wallClockToUtcIso(`${bound.date}T00:00:00`, offsetMin)
        : wallClockToUtcIso(localMidnight, offsetMin);
    // All-day `end.date` is exclusive next-day in Google; treat as 00:00 that date.
    return { utc, offsetMin };
  }
  return null;
}

export function projectGoogleEvent(
  event: GoogleCalendarEvent,
  updatedAt: string,
  timeZone: string = DEFAULT_TIME_ZONE,
  rawId: number | null = null,
  source: CalendarEventRow["source"] = SOURCE_GOOGLE,
): CalendarEventRow | null {
  if (!event.id) return null;
  const start = parseBound(event.start, timeZone, "start");
  const end = parseBound(event.end, timeZone, "end");
  if (!start || !end) return null;

  // Work day / after-hours are the operator's zone, not the event's labelled TZ.
  // A 20:00 America/New_York meeting stored as 00:00Z must land on the ET day.
  const startWall = localWallInZone(start.utc, timeZone);
  const endWall = localWallInZone(end.utc, timeZone);
  const title = event.summary?.trim() || null;
  const kind: WorkKind = classifyTitle(title ?? "", {
    externalAttendee: hasExternalAttendee(event),
  });
  const attendees = extractAttendees(event);
  const deleted = event.status === "cancelled" ? updatedAt : null;

  return {
    id: event.id,
    source: source === SOURCE_GOOGLE ? SOURCE_GOOGLE : SOURCE_SANDBOX_CAL,
    day: startWall.day,
    start_utc: start.utc,
    end_utc: end.utc,
    start_local: localIsoFromWall(startWall),
    end_local: localIsoFromWall(endWall),
    tz_offset_min: startWall.offsetMin,
    duration_s: durationSeconds(start.utc, end.utc),
    title,
    kind,
    client_key: null,
    project_key: null,
    attendee_count: attendees.length > 0 ? attendees.length : null,
    attendees_json: attendees.length ? JSON.stringify(attendees) : null,
    after_hours: isAfterHours(startWall.hour, startWall.minute) ? 1 : 0,
    location: event.location ?? null,
    raw_id: rawId,
    deleted_at: deleted,
    updated_at: updatedAt,
    source_type: "calendar",
    plaud_file_id: null,
    sync_reason: null,
    has_transcript: null,
    synced_at: null,
  };
}

export function eventWorkDay(row: CalendarEventRow, timeZone: string = DEFAULT_TIME_ZONE): string {
  return calendarDayInZone(row.start_utc, timeZone) || row.day;
}

/** Recompute day / local walls / after-hours in the operator zone from UTC instants. */
export function localizeEventForZone(row: CalendarEventRow, timeZone: string = DEFAULT_TIME_ZONE): CalendarEventRow {
  const startWall = localWallInZone(row.start_utc, timeZone);
  const endWall = localWallInZone(row.end_utc, timeZone);
  return {
    ...row,
    day: startWall.day,
    start_local: localIsoFromWall(startWall),
    end_local: localIsoFromWall(endWall),
    tz_offset_min: startWall.offsetMin,
    after_hours: isAfterHours(startWall.hour, startWall.minute) ? 1 : 0,
  };
}
