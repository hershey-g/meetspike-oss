/**
 * The data block "Ask your data" sends to Claude: one compact line per day,
 * with that day's meetings under it. Only dates, times, titles, lengths,
 * attendee names and scores. No transcripts, emails or raw payloads.
 */
import type { CalendarEventRow } from "../types.ts";
import { calendarDayInZone } from "./time.ts";
import { otherAttendees, parseAttendeesJson } from "./people.ts";
import type { DayRow, HeavyEffect, Usual } from "./usual.ts";

const WEEKDAY = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

function weekday(day: string): string {
  return WEEKDAY[new Date(`${day}T12:00:00.000Z`).getUTCDay()];
}

function n(v: number | null | undefined, places = 0): string {
  if (v == null || !Number.isFinite(v)) return "none";
  return places ? v.toFixed(places) : String(Math.round(v));
}

function hhmm(e: Pick<CalendarEventRow, "start_local">): string {
  return /T(\d{2}:\d{2})/.exec(e.start_local ?? "")?.[1] ?? "??:??";
}

export type AskLabels = { wearable: string; readiness: string; strain: string | null };

export function buildAskContext(opts: {
  rows: DayRow[];
  events: CalendarEventRow[];
  usual: Usual;
  effect: HeavyEffect;
  labels: AskLabels;
  timeZone: string;
  today: string;
}): string {
  const { rows, events, usual, effect, labels, timeZone, today } = opts;
  const byDay = new Map<string, CalendarEventRow[]>();
  const seen = new Set<string>();
  for (const e of [...events].sort((a, b) => a.start_utc.localeCompare(b.start_utc))) {
    if (seen.has(e.id)) continue;
    seen.add(e.id);
    const day = calendarDayInZone(e.start_utc, timeZone);
    byDay.set(day, [...(byDay.get(day) ?? []), e]);
  }
  const R = labels.readiness;
  const strain = labels.strain;
  const lines: string[] = [];
  lines.push(`Wearable: ${labels.wearable}. Today is ${today} (${weekday(today)}). Time zone ${timeZone}.`);
  lines.push(
    `Usual (median over ${usual.from} to ${usual.to}): ${R} ${n(usual.recovery)}, sleep ${n(usual.sleep)}, HRV ${n(usual.hrv)} ms, resting HR ${n(usual.restingHr)} bpm` +
      (strain ? `, ${strain} ${n(usual.strain, 1)}` : "") +
      `, weekday meeting hours ${n(usual.meetingHours, 1)}.`,
  );
  lines.push(
    `Heavy days (${effect.heavyHours}+ hours or ${effect.heavyMeetings}+ meetings) in the window below: ${effect.heavy.days}, next-morning ${R} averaged ${n(effect.heavy.nextRecovery)}. Other days: ${effect.lighter.days}, averaged ${n(effect.lighter.nextRecovery)}.`,
  );
  lines.push("");
  lines.push(
    `Days. "woke" is the morning of that day. "next" is the following morning, which shows what the day cost.`,
  );
  for (const r of rows) {
    const m = r.morning;
    const x = r.next;
    const woke = m
      ? `woke ${R} ${n(m.readinessScore)}, sleep ${n(m.sleepScore)}, HRV ${n(m.avgHrv)}, RHR ${n(m.lowestHr)}${strain ? `, ${strain} ${n(m.strain, 1)}` : ""}`
      : "woke: no data";
    const next = x ? `next ${R} ${n(x.readinessScore)}, sleep ${n(x.sleepScore)}` : "next: no data";
    lines.push(
      `${r.day} ${weekday(r.day)} | ${woke} | ${next} | ${r.meetingCount} meetings, ${(r.meetingS / 3600).toFixed(1)} h, ${r.afterHours} after 6 pm`,
    );
    for (const e of byDay.get(r.day) ?? []) {
      const people = otherAttendees(parseAttendeesJson(e.attendees_json))
        .map((a) => a.name ?? a.email.split("@")[0])
        .slice(0, 6);
      const mins = Math.round(Math.max(0, Date.parse(e.end_utc) - Date.parse(e.start_utc)) / 60000);
      lines.push(
        `  ${hhmm(e)} ${e.title?.trim() || "Untitled"} (${e.kind}, ${mins}m)${people.length ? ` with ${people.join(", ")}` : ""}`,
      );
    }
  }
  return lines.join("\n");
}

export const ASK_SYSTEM_PROMPT = `You answer one person's questions about how their meetings relate to their sleep and recovery, using only the data provided after these instructions.

How to read the data: each day lists the meetings on that day, the scores from the morning of that day ("woke"), and the scores from the following morning ("next"). The next-morning scores are what a day's meetings may have cost. Scores run 0 to 100.

When you answer:
- Use only the data given. If it cannot answer the question, say what is missing.
- Name specific dates, meetings, people and numbers.
- Say plainly when a comparison rests on few days (under five on either side). Patterns here are associations, not proof of cause.
- Do not give medical advice.
- Keep it short: a direct answer first, then the few facts behind it. Under 150 words unless asked for more. A small table only when comparing several days.
- Write plainly. No em dashes.`;
