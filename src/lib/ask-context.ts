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

function scoredSpan(u: { from: string; to: string }): string {
  return u.from && u.to ? `${u.from} to ${u.to}` : "no scores yet";
}

function heavyLine(effect: HeavyEffect & { from?: string; to?: string }, readiness: string, wearable: string | null): string {
  const dates = effect.from && effect.to ? `, ${effect.from} to ${effect.to}` : "";
  return `Heavy days (${effect.heavyHours}+ hours or ${effect.heavyMeetings}+ meetings) over all history${dates}${wearable ? `, ${wearable} ${readiness}` : ""}: ` +
    `${effect.heavy.days}, next-morning ${wearable ? "" : `${readiness} `}averaged ${n(effect.heavy.nextRecovery)}. ` +
    `Other days: ${effect.lighter.days}, averaged ${n(effect.lighter.nextRecovery)}.`;
}

export type AskLabels = { wearable: string; readiness: string; strain: string | null };

export function buildAskContext(opts: {
  rows: DayRow[];
  events: CalendarEventRow[];
  usual: Usual;
  /** Heavy-day comparison. from/to: the first and last day it used. */
  effect: HeavyEffect & { from?: string; to?: string };
  labels: AskLabels | null;
  timeZone: string;
  today: string;
  range?: { start: string; end: string };
  /** All history, history start to today. The usual and heavy-day numbers cover it, whatever is ranked. */
  baseline?: { start: string; end: string };
  secondary?: { rows: DayRow[]; usual: Usual; effect?: HeavyEffect & { from?: string; to?: string }; labels: AskLabels };
}): string {
  const { rows, events, usual, effect, labels, timeZone, today } = opts;
  const byDay = new Map<string, CalendarEventRow[]>();
  for (const e of [...events].sort((a, b) => a.start_utc.localeCompare(b.start_utc))) {
    const day = calendarDayInZone(e.start_utc, timeZone);
    const meetings = byDay.get(day) ?? [];
    meetings.push(e);
    byDay.set(day, meetings);
  }
  const R = labels?.readiness;
  const strain = labels?.strain;
  const lines: string[] = [];
  lines.push(`${labels ? `Wearable: ${labels.wearable}.` : "Wearable display is off."} Today is ${today} (${weekday(today)}). Time zone ${timeZone}.`);
  if (opts.range) lines.push(`Selected history: ${opts.range.start} to ${opts.range.end}, inclusive.`);
  if (labels) lines.push(
    `Usual (median over all history, ${scoredSpan(usual)}): ${R} ${n(usual.recovery)}, sleep ${n(usual.sleep)}, HRV ${n(usual.hrv)} ms, resting HR ${n(usual.restingHr)} bpm` +
      (strain ? `, ${strain} ${n(usual.strain, 1)}` : "") +
      `, weekday meeting hours ${n(usual.meetingHours, 1)}.`,
  );
  if (labels) lines.push(heavyLine(effect, R!, null));
  const primaryByDay = new Map(rows.map((row) => [row.day, row]));
  const { secondary } = opts;
  const secondaryByDay = new Map(secondary?.rows.map((row) => [row.day, row]));
  const otherLabel = secondary ? `${secondary.labels.readiness} (${secondary.labels.wearable})` : "";
  const otherStrain = secondary?.labels.strain;
  if (secondary) {
    lines.push(`Usual ${otherLabel} (median over all history, ${scoredSpan(secondary.usual)}): ${n(secondary.usual.recovery)}, sleep ${n(secondary.usual.sleep)}, HRV ${n(secondary.usual.hrv)} ms, resting HR ${n(secondary.usual.restingHr)} bpm` +
      (otherStrain ? `, ${otherStrain} ${n(secondary.usual.strain, 1)}` : "") +
      `, weekday meeting hours ${n(secondary.usual.meetingHours, 1)}.`);
    if (secondary.effect) lines.push(heavyLine(secondary.effect, secondary.labels.readiness, secondary.labels.wearable));
  }
  const { range, baseline } = opts;
  if (labels && range && baseline && (range.start > baseline.start || range.end < baseline.end)) {
    lines.push(`Ranking ${range.start} to ${range.end}. Compare against the all-history numbers above.`);
  }
  const daily: Array<{ row: DayRow; lines: string[] }> = [];
  lines.push("");
  if (labels) lines.push(
    `Days. "woke" is the morning of that day. "next" is the following morning, which shows what the day cost.`,
  );
  const dates = [...new Set([...primaryByDay.keys(), ...secondaryByDay.keys()])].sort();
  for (const day of dates) {
    const other = secondaryByDay.get(day);
    const primary = primaryByDay.get(day);
    const row = primary ?? other;
    if (!row || (!row.meetingCount && !primary?.morning && !primary?.next && !other?.morning && !other?.next)) continue;
    const m = primary?.morning;
    const x = primary?.next;
    const woke = m
      ? `woke ${R} ${n(m.readinessScore)}, sleep ${n(m.sleepScore)}, HRV ${n(m.avgHrv)}, RHR ${n(m.lowestHr)}${strain ? `, ${strain} ${n(m.strain, 1)}` : ""}`
      : "woke: no data";
    const next = x ? `next ${R} ${n(x.readinessScore)}, sleep ${n(x.sleepScore)}` : "next: no data";
    const detail = [
      `${day} ${weekday(day)} | ${labels ? `${woke} | ${next} | ` : ""}${row.meetingCount} meetings, ${(row.meetingS / 3600).toFixed(1)} h, ${row.afterHours} after 6 pm`,
    ];
    if (other?.morning || other?.next) {
      const morning = other.morning;
      detail.push(`  ${otherLabel}: woke ${n(morning?.readinessScore)}, sleep ${n(morning?.sleepScore)}, HRV ${n(morning?.avgHrv)}, resting HR ${n(morning?.lowestHr)}` +
        (otherStrain ? `, ${otherStrain} ${n(morning?.strain, 1)}` : "") +
        `, next ${n(other.next?.readinessScore)}, sleep ${n(other.next?.sleepScore)}.`);
    }
    for (const e of byDay.get(day) ?? []) {
      const people = otherAttendees(parseAttendeesJson(e.attendees_json))
        .map((a) => a.name ?? a.email.split("@")[0])
        .slice(0, 6);
      const mins = Math.round(Math.max(0, Date.parse(e.end_utc) - Date.parse(e.start_utc)) / 60000);
      detail.push(
        `  ${hhmm(e)} ${e.title?.trim().slice(0, 250) || "Untitled"} (${e.kind}, ${mins}m)${people.length ? ` with ${people.join(", ")}` : ""}`,
      );
    }
    daily.push({ row, lines: detail });
  }

  const budget = 500_000;
  const encoder = new TextEncoder();
  const size = (text: string) => encoder.encode(text).length;
  const detail = daily.flatMap((day) => day.lines).join("\n");
  if (size(detail) <= budget) return [...lines, detail].join("\n");

  // Keep coverage of the entire range when detailed records exceed the prompt budget.
  const monthly = new Map<string, {
    meetings: number; seconds: number; afterHours: number;
    recovery: number[]; sleep: number[]; otherRecovery: number[]; otherSleep: number[];
  }>();
  for (const { row } of daily) {
    const month = row.day.slice(0, 7);
    const rollup = monthly.get(month) ?? {
      meetings: 0, seconds: 0, afterHours: 0, recovery: [], sleep: [], otherRecovery: [], otherSleep: [],
    };
    rollup.meetings += row.meetingCount;
    rollup.seconds += row.meetingS;
    rollup.afterHours += row.afterHours;
    const next = primaryByDay.get(row.day)?.next;
    if (next?.readinessScore != null) rollup.recovery.push(next.readinessScore);
    if (next?.sleepScore != null) rollup.sleep.push(next.sleepScore);
    const otherNext = secondaryByDay.get(row.day)?.next;
    if (otherNext?.readinessScore != null) rollup.otherRecovery.push(otherNext.readinessScore);
    if (otherNext?.sleepScore != null) rollup.otherSleep.push(otherNext.sleepScore);
    monthly.set(month, rollup);
  }
  lines.push("Monthly totals over the selected history. Dates without meetings or scores are omitted.");
  for (const [month, m] of monthly) {
    const average = (scores: number[]) => n(scores.reduce((sum, score) => sum + score, 0) / scores.length, 1);
    lines.push(`${month} | ${m.meetings} meetings, ${(m.seconds / 3600).toFixed(1)} h, ${m.afterHours} after 6 pm` +
      (labels ? `, next ${R} ${average(m.recovery)} (${m.recovery.length} mornings), sleep ${average(m.sleep)} (${m.sleep.length} mornings)` : "") +
      (secondary ? `, next ${otherLabel} ${average(m.otherRecovery)} (${m.otherRecovery.length} mornings), sleep ${average(m.otherSleep)} (${m.otherSleep.length} mornings)` : ""));
  }
  let remaining = budget - size(lines.join("\n"));
  let first = daily.length;
  while (first > 0 && remaining > 0) {
    remaining -= size(daily[first - 1].lines.join("\n")) + 1;
    if (remaining >= 0) first--;
  }
  if (first < daily.length) {
    lines.push(`Meeting and day details from ${daily[first].row.day} onward. Earlier months are available above as totals only.`);
    for (const day of daily.slice(first)) lines.push(...day.lines);
  }
  return lines.join("\n");
}

export const ASK_SYSTEM_PROMPT = `You answer one person's questions about how their meetings relate to their sleep and recovery, using only the data provided after these instructions.

How to read the data: each day lists the meetings on that day, the scores from the morning of that day ("woke"), and the scores from the following morning ("next"). The next-morning scores are what a day's meetings may have cost. Scores run 0 to 100.

When you answer:
- Use only the data given. Say what information is missing when it cannot answer a question. If individual meetings or people are missing from dates covered by monthly totals, suggest a narrower date range.
- Name specific dates, meetings, people and numbers. Name the wearable for each score, heart-rate number and baseline. Compare each wearable with its own baseline.
- The usual and heavy-day numbers are baselines over all history. When the data says "Ranking", rank only the days and meetings in those ranked dates, and compare them with the all-history baselines. Never mix one wearable's numbers with another's.
- Say plainly when a comparison rests on few days (under five on either side). Patterns here are associations, not proof of cause.
- Do not give medical advice.
- Keep it short: a direct answer first, then the few facts behind it. Under 150 words unless asked for more. A small table only when comparing several days: at most 3 columns and short cells, because it is read on a phone screen.
- Write plainly. No em dashes.`;
