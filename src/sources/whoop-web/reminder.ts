import type { Env } from "../../env.ts";
import { MAX_MOVED_MEETING_S, meetingLimitS } from "./meeting-hr.ts";
import { applyOverrides, loadOverridesForIds, OverrideSet, type ResolvedOverride } from "../../lib/meeting-override.ts";

/**
 * "Turn on HR Broadcast in the WHOOP app" reminders. One app reminds per
 * meeting: the iPhone for the meetings it reported scheduling a reminder for
 * at its last check-in (signed in, notifications allowed, within
 * REMINDER_OWNER_TTL_S), the Mac for everything else. Each app decides its own timing
 * (two minutes before a meeting, one follow-up if no heart rate arrives in the
 * meeting's first minute). The Worker answers "is a meeting starting?", who
 * owns reminders, and, when PUSHOVER_TOKEN and PUSHOVER_USER are set,
 * forwards a push.
 */

/** A calendar meeting this close to its start (or already running) counts as starting. */
export const REMINDER_LEAD_MS = 2 * 60_000;
const PUSHOVER_URL = "https://api.pushover.net/1/messages.json";
const MAX_TITLE = 120;

/**
 * `startUtc`/`endUtc` are the times the meeting counts for (the owner's or the
 * Mac's changes applied). `calendarStartUtc` is the calendar's own start and
 * is only present when it differs: the phone matches its covered starts on it.
 */
export type ReminderMeeting = { id: string; title: string | null; startUtc: string; endUtc: string; calendarStartUtc?: string };

type StartingRow = { id: string; title: string | null; start_utc: string; end_utc: string; duration_s: number; override?: ResolvedOverride };

/** The calendar meeting that starts within two minutes or is in progress; the latest start wins. Meetings the owner left out never remind. */
export async function startingMeeting(db: D1Database, now: number): Promise<ReminderMeeting | null> {
  const startTo = new Date(now + REMINDER_LEAD_MS).toISOString();
  const endFrom = new Date(now).toISOString();
  // Read a little wider than the calendar test (a start up to 2 h early, an end up to 4 h late),
  // then test again on effective times.
  const { results } = await db
    .prepare(
      `SELECT id, title, start_utc, end_utc, duration_s FROM calendar_event
       WHERE start_utc <= ? AND end_utc > ? AND start_utc > ? AND deleted_at IS NULL
         AND source_type = 'calendar'`,
    )
    .bind(new Date(now + REMINDER_LEAD_MS + 2 * 3600_000).toISOString(), new Date(now - 4 * 3600_000).toISOString(),
      new Date(now - (MAX_MOVED_MEETING_S + 16 * 3600) * 1000).toISOString())
    .all<StartingRow>();
  const found = results ?? [];
  const rows = applyOverrides(found, found.length ? await loadOverridesForIds(db, found.map((row) => row.id)) : OverrideSet.none)
    .filter((row) => row.start_utc <= startTo && row.end_utc > endFrom && row.duration_s > 0 && row.duration_s <= meetingLimitS(row.override?.timesChanged));
  rows.sort((a, b) => b.start_utc.localeCompare(a.start_utc) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const row = rows[0];
  if (!row) return null;
  const moved = row.override?.timesChanged && row.override.calendarStartUtc !== row.start_utc;
  return {
    id: row.id, title: row.title, startUtc: row.start_utc, endUtc: row.end_utc,
    ...(moved ? { calendarStartUtc: row.override!.calendarStartUtc } : {}),
  };
}

export function pushoverConfigured(env: Pick<Env, "PUSHOVER_TOKEN" | "PUSHOVER_USER">): boolean {
  return Boolean(env.PUSHOVER_TOKEN?.trim() && env.PUSHOVER_USER?.trim());
}

/** One printable line, bounded. */
function line(v: unknown, max: number): string {
  return String(v ?? "").replace(/[^\x20-\x7e -￿]/g, " ").replace(/\s+/g, " ").trim().slice(0, max);
}

export function reminderMessage(meetingTitle: unknown, repeat: boolean): string {
  const title = line(meetingTitle, MAX_TITLE);
  if (repeat) return `Still no heart rate for ${title ? `“${title}”` : "your meeting"}. Turn on HR Broadcast in the WHOOP app.`;
  return `${title ? `“${title}” is starting` : "A meeting is starting"}. Turn on HR Broadcast in the WHOOP app.`;
}

export type ReminderOwner = "phone" | "mac";

/** How long an iPhone check-in lasts. The phone only owns the meeting starts it reported. */
export const REMINDER_OWNER_TTL_S = 7 * 24 * 3600;
/** At most this many covered starts per check-in (the phone keeps at most 60 pending notifications). */
export const MAX_COVERED = 60;
/** A covered start matches a calendar meeting starting this close to it. */
export const COVERED_MATCH_MS = 90_000;
const OWNER_KEY = "reminders:phone_owner";
const ISO_UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?Z$/;

export type ReminderOwnerState = { owner: ReminderOwner; until: string | null };
/** A live iPhone check-in: until when, and the meeting starts (ms) it scheduled a reminder for. */
export type PhoneCheckIn = { until: number; covered: number[] };

type KvLike = Pick<KVNamespace, "get" | "put" | "delete">;

/** Strict: missing, or an array of at most MAX_COVERED ISO UTC times. Returns ms values, or null when invalid. */
export function parseCovered(value: unknown): number[] | null {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > MAX_COVERED) return null;
  const out: number[] = [];
  for (const v of value) {
    if (typeof v !== "string" || !ISO_UTC.test(v)) return null;
    const ms = Date.parse(v);
    if (!Number.isFinite(ms)) return null;
    out.push(ms);
  }
  return out;
}

/**
 * The stored check-in, or null when there is none or it is stale. The old
 * format (a bare ISO check-in time) still counts as checked in but covers no
 * meeting, so the Mac reminds. A KV failure reads as no check-in.
 */
export async function phoneCheckIn(kv: KvLike, now: number): Promise<PhoneCheckIn | null> {
  const raw = await kv.get(OWNER_KEY).catch(() => null);
  if (!raw) return null;
  let until = NaN;
  let covered: number[] = [];
  if (raw.startsWith("{")) {
    try {
      const v = JSON.parse(raw) as { until?: unknown; covered?: unknown };
      until = typeof v.until === "string" ? Date.parse(v.until) : NaN;
      covered = parseCovered(v.covered) ?? [];
    } catch {
      return null;
    }
  } else {
    until = Date.parse(raw) + REMINDER_OWNER_TTL_S * 1000;
  }
  return Number.isFinite(until) && until > now ? { until, covered } : null;
}

/**
 * Who reminds about this meeting: the phone only when its check-in is fresh
 * and it reported a start within COVERED_MATCH_MS of this one. No meeting, or
 * a meeting the phone does not have, is the Mac. `until` is the check-in
 * expiry whenever the phone is checked in.
 */
export function ownerFor(checkIn: PhoneCheckIn | null, meetingStartUtc: string | null | undefined): ReminderOwnerState {
  if (!checkIn) return { owner: "mac", until: null };
  const until = new Date(checkIn.until).toISOString();
  const start = meetingStartUtc ? Date.parse(meetingStartUtc) : NaN;
  const covered = Number.isFinite(start) && checkIn.covered.some((c) => Math.abs(c - start) <= COVERED_MATCH_MS);
  return { owner: covered ? "phone" : "mac", until };
}

/** The owner for a meeting starting at `meetingStartUtc` (null: no meeting, so the Mac). */
export async function reminderOwner(kv: KvLike, now: number, meetingStartUtc: string | null = null): Promise<ReminderOwnerState> {
  return ownerFor(await phoneCheckIn(kv, now), meetingStartUtc);
}

/** The iPhone checks in (active, with the starts it covers) or steps down (signed out, notifications off). */
export async function setPhoneOwner(
  kv: KvLike, active: boolean, now: number, covered: number[] = [],
): Promise<ReminderOwnerState & { covered: number }> {
  if (!active) {
    await kv.delete(OWNER_KEY);
    return { owner: "mac", until: null, covered: 0 };
  }
  const until = new Date(now + REMINDER_OWNER_TTL_S * 1000).toISOString();
  const starts = [...new Set(covered)].sort((a, b) => a - b).map((ms) => new Date(ms).toISOString());
  await kv.put(OWNER_KEY, JSON.stringify({ until, covered: starts }), { expirationTtl: REMINDER_OWNER_TTL_S });
  return { owner: "phone", until, covered: starts.length };
}

export type PushResult = "sent" | "not_configured" | "failed";

/** Send one Pushover notification. Never throws; the token never leaves this function. */
export async function sendPushover(
  env: Pick<Env, "PUSHOVER_TOKEN" | "PUSHOVER_USER">,
  message: string,
  fetchImpl: typeof fetch = fetch,
): Promise<PushResult> {
  if (!pushoverConfigured(env)) return "not_configured";
  const body = new URLSearchParams({
    token: env.PUSHOVER_TOKEN!.trim(),
    user: env.PUSHOVER_USER!.trim(),
    title: "Meetspike heart rate",
    message,
    sound: "pushover",
  });
  try {
    const res = await fetchImpl(PUSHOVER_URL, { method: "POST", body, signal: AbortSignal.timeout(8000) });
    return res.ok ? "sent" : "failed";
  } catch {
    return "failed";
  }
}
