import type { GoogleCalendarEvent } from "./project.ts";

const ZONE = "America/New_York";

/**
 * Deterministic Google-shaped events covering DST boundaries, after-hours,
 * early starts, client vs internal, and a heavy day. Used by tests and
 * `POST /api/calendar/sync { "mode": "fixtures" }`.
 */
export function makeCalendarFixtures(): GoogleCalendarEvent[] {
  return [
    {
      id: "evt-dst-spring-late",
      summary: "Client pitch — Acme",
      start: { dateTime: "2024-03-09T19:00:00-05:00", timeZone: ZONE },
      end: { dateTime: "2024-03-09T20:30:00-05:00", timeZone: ZONE },
      attendees: [
        { email: "you@example.com", self: true, displayName: "You" },
        { email: "alex@client.example", displayName: "Alex Rivera" },
      ],
      location: "Zoom",
    },
    {
      id: "evt-dst-spring-morning",
      summary: "Team standup",
      start: { dateTime: "2024-03-10T09:00:00-04:00", timeZone: ZONE },
      end: { dateTime: "2024-03-10T09:15:00-04:00", timeZone: ZONE },
      attendees: [
        { email: "you@example.com", self: true, displayName: "You" },
        { email: "sam@example.com", displayName: "Sam Chen" },
      ],
    },
    {
      id: "evt-dst-fall-late",
      summary: "Weekly staff",
      start: { dateTime: "2024-11-02T18:30:00-04:00", timeZone: ZONE },
      end: { dateTime: "2024-11-02T19:30:00-04:00", timeZone: ZONE },
    },
    {
      id: "evt-dst-fall-morning",
      summary: "Deep work — planning",
      start: { dateTime: "2024-11-03T10:00:00-05:00", timeZone: ZONE },
      end: { dateTime: "2024-11-03T12:00:00-05:00", timeZone: ZONE },
    },
    {
      id: "evt-early-standup",
      summary: "Stand-up",
      start: { dateTime: "2026-08-20T07:15:00-04:00", timeZone: ZONE },
      end: { dateTime: "2026-08-20T07:30:00-04:00", timeZone: ZONE },
    },
    {
      id: "evt-heavy-1",
      summary: "Discovery call",
      start: { dateTime: "2026-08-21T09:00:00-04:00", timeZone: ZONE },
      end: { dateTime: "2026-08-21T10:00:00-04:00", timeZone: ZONE },
      attendees: [
        { email: "you@example.com", self: true, displayName: "You" },
        { email: "pat@client.example", displayName: "Pat Okonkwo" },
      ],
    },
    {
      id: "evt-heavy-2",
      summary: "Proposal review",
      start: { dateTime: "2026-08-21T11:00:00-04:00", timeZone: ZONE },
      end: { dateTime: "2026-08-21T12:00:00-04:00", timeZone: ZONE },
      attendees: [
        { email: "you@example.com", self: true, displayName: "You" },
        { email: "pat@client.example", displayName: "Pat Okonkwo" },
      ],
    },
    {
      id: "evt-heavy-3",
      summary: "Internal 1:1",
      start: { dateTime: "2026-08-21T13:00:00-04:00", timeZone: ZONE },
      end: { dateTime: "2026-08-21T13:30:00-04:00", timeZone: ZONE },
    },
    {
      id: "evt-heavy-4",
      summary: "Client kickoff",
      start: { dateTime: "2026-08-21T14:00:00-04:00", timeZone: ZONE },
      end: { dateTime: "2026-08-21T15:30:00-04:00", timeZone: ZONE },
      attendees: [
        { email: "you@example.com", self: true },
        { email: "ada@other.example", displayName: "Ada Mensah" },
      ],
    },
    {
      id: "evt-heavy-5",
      summary: "Invoice / bookkeep",
      start: { dateTime: "2026-08-21T16:00:00-04:00", timeZone: ZONE },
      end: { dateTime: "2026-08-21T16:30:00-04:00", timeZone: ZONE },
    },
    {
      id: "evt-heavy-6",
      summary: "Retainer check-in",
      start: { dateTime: "2026-08-21T18:00:00-04:00", timeZone: ZONE },
      end: { dateTime: "2026-08-21T19:00:00-04:00", timeZone: ZONE },
      attendees: [
        { email: "you@example.com", self: true },
        { email: "jordan@client.example", displayName: "Jordan Hale" },
      ],
    },
    {
      id: "evt-personal",
      summary: "Dentist",
      start: { dateTime: "2026-08-22T15:00:00-04:00", timeZone: ZONE },
      end: { dateTime: "2026-08-22T16:00:00-04:00", timeZone: ZONE },
    },
    {
      id: "evt-upcoming",
      summary: "Customer pitch",
      start: { dateTime: "2026-09-28T16:00:00-04:00", timeZone: ZONE },
      end: { dateTime: "2026-09-28T17:00:00-04:00", timeZone: ZONE },
      attendees: [
        { email: "you@example.com", self: true },
        { email: "lee@newco.example", displayName: "Lee Park" },
      ],
    },
    {
      id: "evt-cancelled",
      status: "cancelled",
      summary: "Cancelled hold for focus",
      start: { dateTime: "2026-08-22T10:00:00-04:00", timeZone: ZONE },
      end: { dateTime: "2026-08-22T11:00:00-04:00", timeZone: ZONE },
    },
    {
      id: "evt-all-day",
      summary: "Personal — family",
      start: { date: "2026-08-23", timeZone: ZONE },
      end: { date: "2026-08-24", timeZone: ZONE },
    },
  ];
}
