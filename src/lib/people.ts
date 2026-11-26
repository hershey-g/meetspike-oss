import type { MeetingHrStress } from "./heartrate.ts";

function median(values: number[]): number | null {
  const xs = values.filter((n) => Number.isFinite(n)).sort((a, b) => a - b);
  if (!xs.length) return null;
  const mid = Math.floor(xs.length / 2);
  if (xs.length % 2 === 1) return xs[mid];
  return Math.round(((xs[mid - 1] + xs[mid]) / 2) * 10) / 10;
}

export type Attendee = {
  email: string;
  self: boolean;
  /** Google Calendar displayName when present. Never invented from the email. */
  name: string | null;
};

export type PersonBadge = "often spikes you" | "usually restored" | "mixed";

export type PersonTrend = {
  meetingCount: number;
  withCoverage: number;
  elevated: number;
  watching: number;
  restored: number;
  missingHr: number;
  medianAvgBpm: number | null;
  spark: number[];
  badge: PersonBadge | null;
  badgeNote: string;
};

export type AttendeeInput = {
  email?: string;
  self?: boolean;
  displayName?: string;
  name?: string;
  resource?: boolean;
};

export function normalizeEmail(raw: string): string | null {
  const email = raw.trim().toLowerCase();
  if (!email || !email.includes("@") || email.startsWith("noreply") || email.startsWith("calendar-notification")) {
    return null;
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return null;
  return email;
}

/** Keep a real display name. Do not invent one from an email local-part. */
export function normalizePersonName(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const name = raw.trim().replace(/\s+/g, " ");
  if (!name || name.includes("@")) return null;
  return name;
}

export function extractAttendees(doc: {
  attendees?: AttendeeInput[];
  organizer?: AttendeeInput;
}): Attendee[] {
  const seen = new Set<string>();
  const out: Attendee[] = [];
  const push = (row: AttendeeInput | undefined, selfFallback: boolean) => {
    if (!row || row.resource) return;
    const norm = row.email ? normalizeEmail(row.email) : null;
    if (!norm) return;
    const name = normalizePersonName(row.displayName) ?? normalizePersonName(row.name);
    if (seen.has(norm)) {
      const existing = out.find((a) => a.email === norm);
      if (existing && !existing.name && name) existing.name = name;
      return;
    }
    seen.add(norm);
    out.push({
      email: norm,
      self: Boolean(row.self) || selfFallback,
      name,
    });
  };
  for (const a of doc.attendees ?? []) {
    push(a, Boolean(a.self));
  }
  if (doc.organizer?.self && doc.organizer.email) push(doc.organizer, true);
  return out;
}

export function parseAttendeesJson(raw: string | null | undefined): Attendee[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed
      .map((row) => {
        if (!row || typeof row !== "object") return null;
        const rec = row as AttendeeInput;
        if (rec.resource) return null;
        const email = normalizeEmail(String(rec.email ?? ""));
        if (!email) return null;
        return {
          email,
          self: Boolean(rec.self),
          name: normalizePersonName(rec.displayName) ?? normalizePersonName(rec.name),
        };
      })
      .filter((a): a is Attendee => a != null);
  } catch {
    return [];
  }
}

export function otherAttendees(list: Attendee[]): Attendee[] {
  return list.filter((a) => !a.self);
}

export function attendeesIdentityNote(list: Attendee[]): string | null {
  const others = otherAttendees(list);
  if (!others.length) {
    return list.some((a) => a.self)
      ? "Only your address is on this event — no other attendee emails."
      : "No attendee emails on this event";
  }
  return null;
}

/** Most recent stored display name for this email. Does not invent a name. */
export function pickPersonName(email: string, lists: Attendee[][]): string | null {
  const norm = normalizeEmail(email);
  if (!norm) return null;
  for (const list of lists) {
    for (const a of list) {
      if (a.email === norm && a.name) return a.name;
    }
  }
  return null;
}

export function summarizePerson(
  rows: Array<{ hrStress: MeetingHrStress | null }>,
): PersonTrend {
  const spark: number[] = [];
  let elevated = 0;
  let watching = 0;
  let restored = 0;
  let missingHr = 0;
  let combined = 0;
  const avgs: number[] = [];
  for (const row of rows) {
    const hr = row.hrStress;
    if (!hr || hr.coverage !== "ok") {
      missingHr += 1;
      continue;
    }
    if (hr.meanBpm != null) {
      avgs.push(hr.meanBpm);
      spark.push(Math.round(hr.meanBpm));
    }
    if (hr.zone === "high") elevated += 1;
    else if (hr.zone === "moderate") watching += 1;
    else if (hr.zone === "low") restored += 1;
    else combined += 1;
  }
  const scored = elevated + watching + restored;
  const withCoverage = scored + combined;
  let badge: PersonBadge | null = null;
  let badgeNote = "Need at least two meetings with ring heart-rate before a person pattern is honest.";
  if (scored >= 2) {
    if (elevated >= 2 && elevated / scored >= 0.5) {
      badge = "often spikes you";
      badgeNote = `${elevated} of ${scored} meetings with heart-rate scores landed Elevated.`;
    } else if (restored / scored >= 2 / 3 && elevated === 0) {
      badge = "usually restored";
      badgeNote = `${restored} of ${scored} meetings with heart-rate scores stayed Restored.`;
    } else {
      badge = "mixed";
      badgeNote = `${elevated} Elevated, ${watching} Worth watching, ${restored} Restored — with ring data only.`;
    }
  }
  return {
    meetingCount: rows.length,
    withCoverage,
    elevated,
    watching,
    restored,
    missingHr,
    medianAvgBpm: median(avgs),
    spark,
    badge,
    badgeNote,
  };
}
