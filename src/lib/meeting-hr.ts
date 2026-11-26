import type { Env } from "../env.ts";
import { SOURCE_OURA, SOURCE_WHOOP } from "../types.ts";
import { loadMeetingHrMap } from "./heartrate-archive.ts";
import { noHrCoverage, type MeetingHrStress, type HrGap } from "./heartrate.ts";
import { loadWhoopWebMeetingHrMap } from "../sources/whoop-web/fill.ts";
import { meetingLimitS, type MeetingInput } from "../sources/whoop-web/meeting-hr.ts";
import type { WearableInfo } from "./wearable.ts";

export const DUAL_HR_NOTE =
  "Meeting heart rate uses WHOOP when it covers the meeting, then Oura. When both have gaps, Oura can fill in sections WHOOP missed.";

const hasData = (hr: MeetingHrStress | undefined): hr is MeetingHrStress => hr?.coverage === "ok";
export const hasFullMeetingHr = (hr: MeetingHrStress | undefined): boolean =>
  hasData(hr) && !hr.partial;

function sharedGaps(whoop: HrGap[], oura: HrGap[]): HrGap[] {
  return whoop.flatMap(([a, b]) => oura.flatMap(([c, d]): HrGap[] => {
    const start = Math.max(a, c);
    const end = Math.min(b, d);
    return start < end ? [[start, end]] : [];
  }));
}

export function selectMeetingHr(
  meeting: MeetingInput,
  whoop: MeetingHrStress | undefined,
  oura: MeetingHrStress | undefined,
): MeetingHrStress {
  if (hasData(whoop) && (hasFullMeetingHr(whoop) || !hasData(oura))) return whoop;
  if (hasData(oura) && (hasFullMeetingHr(oura) || !hasData(whoop))) return oura;
  if (!hasData(whoop) || !hasData(oura)) {
    return whoop && oura
      ? { ...noHrCoverage(), methodNote: DUAL_HR_NOTE, headline: "No HR", story: "WHOOP and Oura have no saved heart rate for this meeting." }
      : whoop ?? oura ?? noHrCoverage();
  }

  const whoopGaps = whoop.gaps ?? [];
  const whoopTimes = new Set(whoop.series.map((p) => p.t));
  const ouraPoints = oura.series.filter((p) => {
    const t = Date.parse(p.t);
    return !whoopTimes.has(p.t) && whoopGaps.some(([start, end]) => t >= start && t < end);
  });
  if (!ouraPoints.length) return whoop;

  const series = [
    ...whoop.series.map((p) => ({ ...p, source: "WHOOP" as const })),
    ...ouraPoints.map((p) => ({ ...p, source: "Oura" as const })),
  ].sort((a, b) => a.t.localeCompare(b.t));
  const gaps = whoopGaps.flatMap((gap) =>
    ouraPoints.some((p) => Date.parse(p.t) >= gap[0] && Date.parse(p.t) < gap[1])
      ? sharedGaps([gap], oura.gaps ?? [])
      : [gap],
  );
  const start = Date.parse(meeting.startUtc);
  const end = Date.parse(meeting.endUtc);
  // Each provider uses a different baseline and sampling cadence. Keep the
  // combined chart available without reporting a combined zone or average.
  return {
    ...noHrCoverage(),
    coverage: "ok",
    source: "WHOOP + Oura",
    gaps,
    methodNote: DUAL_HR_NOTE,
    headline: "Heart rate",
    story: "WHOOP and Oura recorded different parts of this meeting.",
    sampleCount: whoop.sampleCount + ouraPoints.length,
    maxBpm: Math.max(whoop.maxBpm ?? 0, ...ouraPoints.map((p) => p.bpm)),
    series,
    partial: gaps.length
      ? { fromUtc: series[0].t, toUtc: series.at(-1)!.t, lateStart: gaps[0][0] === start, earlyEnd: gaps.at(-1)![1] === end }
      : null,
  };
}

async function restingByDay(env: Env, meetings: MeetingInput[], source: typeof SOURCE_OURA | typeof SOURCE_WHOOP) {
  const days = meetings.map((m) => m.day).sort();
  const res = await env.DB.prepare(
    "SELECT day, lowest_hr FROM daily_sleep WHERE source = ? AND day BETWEEN ? AND ? AND deleted_at IS NULL",
  ).bind(source, days[0], days.at(-1)).all<{ day: string; lowest_hr: number | null }>();
  return new Map((res.results ?? []).map((row) => [row.day, row.lowest_hr]));
}

export async function loadOuraMeetingHr(env: Env, meetings: MeetingInput[], tz: string) {
  if (!meetings.length) return new Map<string, MeetingHrStress>();
  return loadMeetingHrMap(env, meetings, await restingByDay(env, meetings, SOURCE_OURA), tz);
}

export async function saveMeetingHrSources(
  db: D1Database,
  meetings: MeetingInput[],
  readings: Map<string, MeetingHrStress>,
): Promise<void> {
  const sources = meetings.flatMap((m) => {
    const source = readings.get(m.id)?.source;
    return source ? [[m.id, m.startUtc, m.endUtc, source]] : [];
  });
  if (!sources.length) return;
  await db.prepare(
    `INSERT INTO meeting_hr_source (event_id, start_utc, end_utc, source)
     SELECT value ->> 0, value ->> 1, value ->> 2, value ->> 3
     FROM json_each(?)
     WHERE 1
     ON CONFLICT (event_id, start_utc, end_utc) DO UPDATE SET source = excluded.source
     WHERE meeting_hr_source.source <> excluded.source`,
  ).bind(JSON.stringify(sources)).run().catch((err) => {
    // Existing deployments may still be serving while the migration is pending.
    if (!String(err).includes("no such table: meeting_hr_source")) throw err;
  });
}

export async function loadSelectedMeetingHr(
  env: Env,
  w: Pick<WearableInfo, "hasIntradayHr" | "whoopWebHr" | "ouraHr">,
  meetings: MeetingInput[],
  tz: string,
  /** Meetings the owner left out. They never count toward another meeting's baseline. */
  isExcluded?: (eventId: string) => boolean,
): Promise<Map<string, MeetingHrStress>> {
  meetings = meetings.filter((m) => {
    const duration = Date.parse(m.endUtc) - Date.parse(m.startUtc);
    return duration > 0 && duration <= meetingLimitS(m.effective) * 1000;
  });
  if (!w.hasIntradayHr || !meetings.length) return new Map();
  const whoop = w.whoopWebHr
    ? await loadWhoopWebMeetingHrMap(env, meetings, await restingByDay(env, meetings, SOURCE_WHOOP), isExcluded)
    : new Map<string, MeetingHrStress>();
  const oura = w.ouraHr
    ? await loadOuraMeetingHr(env, meetings.filter((m) => !hasFullMeetingHr(whoop.get(m.id))), tz)
    : new Map<string, MeetingHrStress>();
  const selected = new Map(meetings.map((m) => [m.id, selectMeetingHr(m, whoop.get(m.id), oura.get(m.id))]));
  await saveMeetingHrSources(env.DB, meetings, selected);
  return selected;
}
