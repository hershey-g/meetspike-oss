import { parseAttendeesJson } from "./people.ts";
import { normalizeSourceType, SOURCE_TYPE_CALENDAR } from "./source-type.ts";
import type { CalendarEventRow } from "../types.ts";

type MeetingIdentity = Pick<CalendarEventRow, "id" | "start_utc" | "title" | "attendees_json">;
type Meeting = MeetingIdentity & Partial<Pick<CalendarEventRow, "source_type">>;

/** A calendar copy and its linked recording may describe the same meeting. */
export function dedupeMeetings<T extends Meeting>(meetings: T[]): T[] {
  const unique = new Map<string, T>();
  for (const meeting of meetings) {
    const start = Date.parse(meeting.start_utc);
    const attendees = [...new Set(parseAttendeesJson(meeting.attendees_json).map(({ email }) => email))].sort();
    const key = JSON.stringify([Number.isFinite(start) ? start : meeting.start_utc, meeting.title, attendees]);
    const existing = unique.get(key);
    // Keep the calendar event when available so its established links and HR lookup still work.
    if (!existing || (normalizeSourceType(existing.source_type) !== SOURCE_TYPE_CALENDAR &&
      normalizeSourceType(meeting.source_type) === SOURCE_TYPE_CALENDAR)) {
      unique.set(key, meeting);
    }
  }
  return [...unique.values()];
}
