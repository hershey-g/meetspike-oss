const OFFSET_RE = /([+-])(\d{2}):(\d{2})$/;
const Z_RE = /Z$/;
const IANA_FALLBACK = "America/New_York";

export function nowIso(): string {
  return new Date().toISOString();
}

export function toUtcIso(input: string): string {
  const d = new Date(input);
  if (Number.isNaN(d.getTime())) throw new Error(`unparseable timestamp: ${input}`);
  return d.toISOString();
}

export function offsetMinutesFromIso(input: string): number {
  if (Z_RE.test(input)) return 0;
  const m = OFFSET_RE.exec(input);
  if (!m) throw new Error(`timestamp has no offset: ${input}`);
  const sign = m[1] === "-" ? -1 : 1;
  return sign * (Number(m[2]) * 60 + Number(m[3]));
}

export type LocalWall = {
  day: string;
  hour: number;
  minute: number;
  second: number;
  offsetMin: number;
};

const zoneFormatters = new Map<string, Intl.DateTimeFormat>();

function zoneParts(utcIso: string, timeZone: string): Record<string, string> {
  const d = new Date(utcIso);
  if (Number.isNaN(d.getTime())) throw new Error(`unparseable timestamp: ${utcIso}`);
  let fmt = zoneFormatters.get(timeZone);
  if (!fmt) {
    fmt = new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    });
    zoneFormatters.set(timeZone, fmt);
  }
  return Object.fromEntries(fmt.formatToParts(d).filter((p) => p.type !== "literal").map((p) => [p.type, p.value]));
}

export function calendarDayInZone(utcIso: string, timeZone: string = IANA_FALLBACK): string {
  const p = zoneParts(utcIso, timeZone);
  return `${p.year.padStart(4, "0")}-${p.month}-${p.day}`;
}

/** Offset of `timeZone` at this instant, minutes east of UTC (EST = -300, EDT = -240). */
export function offsetMinutesInZone(utcIso: string, timeZone: string = IANA_FALLBACK): number {
  const p = zoneParts(utcIso, timeZone);
  const asUtc = Date.UTC(
    Number(p.year),
    Number(p.month) - 1,
    Number(p.day),
    Number(p.hour),
    Number(p.minute),
    Number(p.second),
  );
  return Math.round((asUtc - new Date(utcIso).getTime()) / 60_000);
}

export function localWallInZone(utcIso: string, timeZone: string = IANA_FALLBACK): LocalWall {
  const p = zoneParts(utcIso, timeZone);
  return {
    day: `${p.year.padStart(4, "0")}-${p.month}-${p.day}`,
    hour: Number(p.hour),
    minute: Number(p.minute),
    second: Number(p.second),
    offsetMin: offsetMinutesInZone(utcIso, timeZone),
  };
}

export function formatOffsetMin(offsetMin: number): string {
  const sign = offsetMin < 0 ? "-" : "+";
  const abs = Math.abs(offsetMin);
  const h = String(Math.floor(abs / 60)).padStart(2, "0");
  const m = String(abs % 60).padStart(2, "0");
  return `${sign}${h}:${m}`;
}

export function localIsoFromWall(wall: Pick<LocalWall, "day" | "hour" | "minute" | "second" | "offsetMin">): string {
  const hh = String(wall.hour).padStart(2, "0");
  const mm = String(wall.minute).padStart(2, "0");
  const ss = String(wall.second).padStart(2, "0");
  return `${wall.day}T${hh}:${mm}:${ss}${formatOffsetMin(wall.offsetMin)}`;
}

/** Calendar-date arithmetic on YYYY-MM-DD (not timezone-dependent). */
export function addCalendarDays(day: string, n: number): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day);
  if (!m) throw new Error(`invalid day ${day}`);
  const d = new Date(`${day}T12:00:00.000Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/** Work day D → Oura morning date D+1. */
export function ouraMorningDay(workDay: string): string {
  return addCalendarDays(workDay, 1);
}

export function wallClockToUtcIso(local: string, offsetMin: number): string {
  const normalized = local.includes("T") ? local : local.replace(" ", "T");
  const naive = normalized.replace(/Z$/, "").replace(/[+-]\d{2}:\d{2}$/, "");
  const [datePart, timePart = "00:00:00"] = naive.split("T");
  const [y, mo, d] = datePart.split("-").map(Number);
  const [h, mi, s] = timePart.split(":").map(Number);
  const ms = Date.UTC(y, mo - 1, d, h, mi, Math.floor(s || 0)) - offsetMin * 60_000;
  return new Date(ms).toISOString();
}

/** Local midnight of `day` in `timeZone`, as a UTC ISO instant. DST-safe. */
export function localMidnightUtcIso(day: string, timeZone: string = IANA_FALLBACK): string {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error(`invalid day ${day}`);
  let guess = `${day}T00:00:00.000Z`;
  for (let i = 0; i < 4; i += 1) {
    const utc = wallClockToUtcIso(`${day}T00:00:00`, offsetMinutesInZone(guess, timeZone));
    if (utc === guess) return utc;
    guess = utc;
  }
  return guess;
}

/**
 * Inclusive local-day window [fromDay, toDay] as a half-open UTC range
 * [startUtc, endUtcExclusive). Use this — not UTC midnights — for calendar queries.
 */
export function localDayRangeUtc(
  fromDay: string,
  toDay: string,
  timeZone: string = IANA_FALLBACK,
): { startUtc: string; endUtcExclusive: string } {
  return {
    startUtc: localMidnightUtcIso(fromDay, timeZone),
    endUtcExclusive: localMidnightUtcIso(addCalendarDays(toDay, 1), timeZone),
  };
}

/**
 * Monday–Sunday week that contains `day` (YYYY-MM-DD, calendar arithmetic).
 * Week in review uses this window — not Sunday–Saturday.
 */
export function weekBoundsMonday(day: string): { start: string; end: string } {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error(`invalid day ${day}`);
  const weekday = new Date(`${day}T12:00:00.000Z`).getUTCDay(); // Sun=0 … Sat=6
  const mondayOffset = weekday === 0 ? -6 : 1 - weekday;
  const start = addCalendarDays(day, mondayOffset);
  return { start, end: addCalendarDays(start, 6) };
}

export const DEFAULT_TIME_ZONE = IANA_FALLBACK;
