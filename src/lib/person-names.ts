import { exclusionClause, loadExclusionRules } from "./meeting-override.ts";
/**
 * Show a person's name wherever an attendee appears.
 *
 * Resolution order for an attendee email:
 *   a. the Google attendee displayName on this meeting (already on the row);
 *   b. the displayName the same email had on any other stored meeting
 *      (calendar_attendee, then the person_name cache with source 'calendar');
 *   c. Google Contacts / People API — NOT used: the app's only Google scope is
 *      calendar.readonly, which does not allow it, and no scope is added;
 *   d. a Plaud speaker name that mapped cleanly to the email (person_name,
 *      source 'plaud', written at Plaud ingest);
 *   e. nothing: `name` stays null and the UI shows the email address.
 */
import type { Attendee } from "./people.ts";
import { normalizeEmail, normalizePersonName } from "./people.ts";

export type NameSource = "calendar" | "plaud";

export type NameLookup = {
  /** (b) displayName from other stored meetings, most recent meeting first. */
  calendar: Map<string, string>;
  /** person_name cache rows. */
  cached: Map<string, { name: string; source: NameSource }>;
};

/** Pick a name for one email from what was loaded. Null means "show the email". */
export function resolveName(email: string, inline: string | null | undefined, lookup: NameLookup): string | null {
  const own = normalizePersonName(inline);
  if (own) return own;
  const norm = normalizeEmail(email);
  if (!norm) return null;
  const fromCalendar = lookup.calendar.get(norm);
  if (fromCalendar) return fromCalendar;
  const cached = lookup.cached.get(norm);
  if (cached?.source === "calendar") return cached.name;
  // (c) contacts: not allowed by calendar.readonly — skipped on purpose.
  if (cached?.source === "plaud") return cached.name;
  return null;
}

type Named = { email: string; name: string | null | undefined };

function isNamedSlot(value: unknown): value is Named & Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const rec = value as Record<string, unknown>;
  return typeof rec.email === "string" && "name" in rec;
}

/** Every email in a JSON payload that sits next to an empty `name`. */
export function collectUnnamedEmails(payload: unknown, out = new Set<string>()): Set<string> {
  if (Array.isArray(payload)) {
    for (const v of payload) collectUnnamedEmails(v, out);
  } else if (payload && typeof payload === "object") {
    if (isNamedSlot(payload) && !normalizePersonName(payload.name)) {
      const norm = normalizeEmail(payload.email);
      if (norm) out.add(norm);
    }
    for (const v of Object.values(payload)) collectUnnamedEmails(v, out);
  }
  return out;
}

/** Fill empty `name` fields next to an `email` in place. Returns how many were filled. */
export function fillNames(payload: unknown, names: Map<string, string>): number {
  let filled = 0;
  const walk = (node: unknown) => {
    if (Array.isArray(node)) {
      for (const v of node) walk(v);
      return;
    }
    if (!node || typeof node !== "object") return;
    if (isNamedSlot(node) && !normalizePersonName(node.name)) {
      const norm = normalizeEmail(node.email);
      const name = norm ? names.get(norm) : undefined;
      if (name) {
        (node as Record<string, unknown>).name = name;
        filled += 1;
      }
    }
    for (const v of Object.values(node)) walk(v);
  };
  walk(payload);
  return filled;
}

/** D1 allows 100 bound parameters per statement. */
const CHUNK = 90;

function chunks<T>(xs: T[], n = CHUNK): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < xs.length; i += n) out.push(xs.slice(i, i + n));
  return out;
}

/** Load (b) and the cache for these emails. A missing person_name table is not an error. */
export async function loadNameLookup(db: D1Database, emails: Iterable<string>): Promise<NameLookup> {
  const list = [...new Set([...emails].map((e) => normalizeEmail(e)).filter((e): e is string => Boolean(e)))];
  const lookup: NameLookup = { calendar: new Map(), cached: new Map() };
  // A name only seen in meetings the owner left out is not shown.
  const rules = list.length ? await loadExclusionRules(db) : null;
  for (const part of chunks(list)) {
    const marks = part.map(() => "?").join(", ");
    const left = rules ? exclusionClause(rules, "e", part.length + 1) : null;
    const { results } = await db
      .prepare(
        `SELECT a.email AS email, a.display_name AS display_name
         FROM calendar_attendee a
         ${left ? "JOIN" : "LEFT JOIN"} calendar_event e ON e.id = a.event_id AND e.source = a.source
         WHERE a.email IN (${marks}) AND a.display_name IS NOT NULL AND trim(a.display_name) != ''${left?.sql ?? ""}
         ORDER BY e.start_utc DESC`,
      )
      .bind(...part, ...(left?.params ?? []))
      .all<{ email: string; display_name: string }>();
    for (const row of results ?? []) {
      const name = normalizePersonName(row.display_name);
      if (name && !lookup.calendar.has(row.email)) lookup.calendar.set(row.email, name);
    }
    try {
      const cached = await db
        .prepare(`SELECT email, name, source FROM person_name WHERE email IN (${marks})`)
        .bind(...part)
        .all<{ email: string; name: string; source: string }>();
      for (const row of cached.results ?? []) {
        const name = normalizePersonName(row.name);
        if (!name) continue;
        lookup.cached.set(row.email, { name, source: row.source === "plaud" ? "plaud" : "calendar" });
      }
    } catch {
      // person_name (migration 0009) not applied yet: (b) still works without the cache.
    }
  }
  return lookup;
}

/**
 * Remember names in D1. A calendar name replaces anything; a plaud name only
 * fills an email that has no calendar name. Best effort: never throws.
 */
export async function cacheNames(
  db: D1Database,
  entries: Array<{ email: string; name: string }>,
  source: NameSource,
  at: string = new Date().toISOString(),
): Promise<number> {
  const clean = entries
    .map((e) => ({ email: normalizeEmail(e.email), name: normalizePersonName(e.name) }))
    .filter((e): e is { email: string; name: string } => Boolean(e.email && e.name));
  if (!clean.length) return 0;
  const sql =
    source === "calendar"
      ? `INSERT INTO person_name (email, name, source, updated_at) VALUES (?, ?, 'calendar', ?)
         ON CONFLICT (email) DO UPDATE SET name = excluded.name, source = 'calendar', updated_at = excluded.updated_at
         WHERE person_name.name != excluded.name OR person_name.source != 'calendar'`
      : `INSERT INTO person_name (email, name, source, updated_at) VALUES (?, ?, 'plaud', ?)
         ON CONFLICT (email) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at
         WHERE person_name.source = 'plaud' AND person_name.name != excluded.name`;
  try {
    await db.batch(clean.map((e) => db.prepare(sql).bind(e.email, e.name, at)));
    return clean.length;
  } catch {
    return 0;
  }
}

/**
 * Fill every empty attendee/person `name` in an API payload, in place.
 * Names found from other meetings (b) are written to the cache on the way.
 */
export async function resolvePayloadNames(db: D1Database, payload: unknown): Promise<number> {
  const emails = collectUnnamedEmails(payload);
  if (!emails.size) return 0;
  const lookup = await loadNameLookup(db, emails);
  const names = new Map<string, string>();
  const learned: Array<{ email: string; name: string }> = [];
  for (const email of emails) {
    const name = resolveName(email, null, lookup);
    if (!name) continue;
    names.set(email, name);
    const cached = lookup.cached.get(email);
    if (lookup.calendar.has(email) && (cached?.source !== "calendar" || cached.name !== name)) {
      learned.push({ email, name });
    }
  }
  if (learned.length) await cacheNames(db, learned, "calendar");
  return fillNames(payload, names);
}

/* ---------- Plaud speakers (d) ---------- */

export type PlaudSpeaker = { name: string; email: string | null };

const GENERIC_SPEAKER = /^(speaker|spk|person|participant|unknown|guest)\s*[-_#]?\s*\d*$/i;

/** Accepts ["Jane Doe", {name, email}] and drops "Speaker 1"-style labels. */
export function parseSpeakers(raw: unknown): PlaudSpeaker[] {
  if (!Array.isArray(raw)) return [];
  const out: PlaudSpeaker[] = [];
  for (const item of raw.slice(0, 50)) {
    const rec = typeof item === "string" ? { name: item } : item && typeof item === "object" ? (item as Record<string, unknown>) : null;
    if (!rec) continue;
    const name = normalizePersonName(rec.name ?? rec.speaker ?? rec.label);
    if (!name || GENERIC_SPEAKER.test(name)) continue;
    const email = typeof rec.email === "string" ? normalizeEmail(rec.email) : null;
    out.push({ name, email });
  }
  return out;
}

function fold(s: string): string {
  return s
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase();
}

/** Local-part spellings a name could plausibly own: jane.doe, jane_doe, janedoe, jdoe, jane. */
function localPartsFor(name: string): Set<string> {
  const words = fold(name)
    .split(/[^a-z]+/)
    .filter(Boolean);
  const out = new Set<string>();
  if (!words.length) return out;
  const first = words[0];
  const last = words[words.length - 1];
  out.add(first);
  if (words.length > 1) {
    for (const sep of [".", "_", "-", ""]) out.add(`${first}${sep}${last}`);
    out.add(`${first[0]}${last}`);
    out.add(`${first[0]}.${last}`);
  }
  return out;
}

function localPart(email: string): string {
  return fold(email.slice(0, email.indexOf("@")).replace(/\+.*$/, "")).replace(/\d+$/, "");
}

/**
 * Map Plaud speaker names onto meeting attendees, only where the mapping is
 * unambiguous: the speaker carries the attendee's email, or the speaker's name
 * spells the email's local part (jane.doe@ ↔ "Jane Doe") and that speaker and
 * that attendee match nobody else. Self and already-named attendees are skipped.
 */
export function matchSpeakersToAttendees(attendees: Attendee[], speakers: PlaudSpeaker[]): Map<string, string> {
  const out = new Map<string, string>();
  const open = attendees.filter((a) => !a.self && !a.name);
  if (!open.length || !speakers.length) return out;

  const used = new Set<number>();
  speakers.forEach((s, i) => {
    if (!s.email) return;
    const hit = open.find((a) => a.email === s.email);
    if (hit) {
      out.set(hit.email, s.name);
      used.add(i);
    }
  });

  const remaining = open.filter((a) => !out.has(a.email));
  const pairs: Array<[number, string]> = [];
  speakers.forEach((s, i) => {
    if (used.has(i) || s.email) return;
    const forms = localPartsFor(s.name);
    for (const a of remaining) if (forms.has(localPart(a.email))) pairs.push([i, a.email]);
  });
  for (const [i, email] of pairs) {
    const speakerHits = pairs.filter(([j]) => j === i).length;
    const attendeeHits = pairs.filter(([, e]) => e === email).length;
    if (speakerHits === 1 && attendeeHits === 1) out.set(email, speakers[i].name);
  }
  return out;
}
