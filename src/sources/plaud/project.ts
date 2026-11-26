import { SOURCE_PLAUD, type CalendarEventRow } from "../../types.ts";
import {
  DEFAULT_TIME_ZONE,
  localIsoFromWall,
  localWallInZone,
  toUtcIso,
  wallClockToUtcIso,
} from "../../lib/time.ts";
import { durationSeconds, isAfterHours } from "../calendar/classify.ts";
import { classifyPlaudTitle, cleanPlaudTitle } from "./classify.ts";
import { parseSpeakers, type PlaudSpeaker } from "../../lib/person-names.ts";

export type PlaudRecordingInput = {
  /** Optional speaker names from the transcript: ["Jane Doe"] or [{ name, email }]. Names only are kept. */
  speakers?: unknown;
  plaud_file_id?: unknown;
  title?: unknown;
  start_at?: unknown;
  end_at?: unknown;
  duration_ms?: unknown;
  duration?: unknown;
  has_transcript?: unknown;
};

export type PlaudReject = {
  plaud_file_id: string | null;
  status: "rejected";
  reason: "no_match" | "bad_id" | "bad_title" | "bad_window";
};

export type PlaudAccept = {
  status: "accept";
  row: CalendarEventRow;
};

const ID_RE = /^[A-Za-z0-9._:-]{1,128}$/;

function asString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const t = value.trim();
  return t ? t : null;
}

function asMs(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) return Math.round(value);
  if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) {
    const n = Number(value);
    return n > 0 ? Math.round(n) : null;
  }
  return null;
}

/** Naive ISO (no Z / offset) is operator-local wall time. Offset/Z is taken as given. */
export function plaudInstantToUtc(input: string, timeZone: string = DEFAULT_TIME_ZONE): string | null {
  const raw = input.trim();
  if (!raw) return null;
  if (/[zZ]$/.test(raw) || /[+-]\d{2}:\d{2}$/.test(raw)) {
    try {
      return toUtcIso(raw);
    } catch {
      return null;
    }
  }
  const naive = (raw.includes("T") ? raw : raw.replace(" ", "T")).replace(/Z$/, "");
  const wall = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(naive) ? `${naive}:00` : naive;
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(wall)) return null;
  try {
    const noon = `${wall.slice(0, 10)}T12:00:00.000Z`;
    const offset = localWallInZone(noon, timeZone).offsetMin;
    return wallClockToUtcIso(wall, offset);
  } catch {
    return null;
  }
}

export function parseWindowUtc(
  startAt: string,
  endAt: string | null,
  durationMs: number | null,
  timeZone: string,
): { startUtc: string; endUtc: string } | null {
  const startUtc = plaudInstantToUtc(startAt, timeZone);
  if (!startUtc) return null;
  if (endAt) {
    const endUtc = plaudInstantToUtc(endAt, timeZone);
    if (!endUtc) return null;
    if (Date.parse(endUtc) <= Date.parse(startUtc)) return null;
    return { startUtc, endUtc };
  }
  if (durationMs != null && durationMs >= 1000) {
    return { startUtc, endUtc: new Date(Date.parse(startUtc) + durationMs).toISOString() };
  }
  return null;
}

export function projectPlaudRecording(
  input: PlaudRecordingInput,
  opts: { timeZone?: string; now?: string },
): PlaudAccept | PlaudReject {
  const timeZone = opts.timeZone ?? DEFAULT_TIME_ZONE;
  const now = opts.now ?? new Date().toISOString();
  const fileId = asString(input.plaud_file_id);
  if (!fileId || !ID_RE.test(fileId)) {
    return { plaud_file_id: fileId, status: "rejected", reason: "bad_id" };
  }
  const title = cleanPlaudTitle(asString(input.title) ?? "");
  if (!title) return { plaud_file_id: fileId, status: "rejected", reason: "bad_title" };
  const match = classifyPlaudTitle(title);
  if (!match) return { plaud_file_id: fileId, status: "rejected", reason: "no_match" };

  const startAt = asString(input.start_at);
  const endAt = asString(input.end_at);
  const durationMs = asMs(input.duration_ms) ?? asMs(input.duration);
  if (!startAt) return { plaud_file_id: fileId, status: "rejected", reason: "bad_window" };
  const window = parseWindowUtc(startAt, endAt, durationMs, timeZone);
  if (!window) return { plaud_file_id: fileId, status: "rejected", reason: "bad_window" };

  const startWall = localWallInZone(window.startUtc, timeZone);
  const endWall = localWallInZone(window.endUtc, timeZone);
  const hasTranscript = input.has_transcript === true || input.has_transcript === 1 || input.has_transcript === "true";

  return {
    status: "accept",
    row: {
      id: fileId,
      source: SOURCE_PLAUD,
      day: startWall.day,
      start_utc: window.startUtc,
      end_utc: window.endUtc,
      start_local: localIsoFromWall(startWall),
      end_local: localIsoFromWall(endWall),
      tz_offset_min: startWall.offsetMin,
      duration_s: durationSeconds(window.startUtc, window.endUtc),
      title,
      kind: match.kind,
      client_key: null,
      project_key: null,
      attendee_count: null,
      attendees_json: null,
      after_hours: isAfterHours(startWall.hour, startWall.minute) ? 1 : 0,
      location: null,
      raw_id: null,
      deleted_at: null,
      updated_at: now,
      source_type: match.sourceType,
      plaud_file_id: fileId,
      sync_reason: match.syncReason,
      has_transcript: hasTranscript ? 1 : 0,
      synced_at: now,
    },
  };
}

export function planPlaudIngest(
  body: unknown,
  opts: { timeZone?: string; now?: string; limit?: number } = {},
): { accept: CalendarEventRow[]; reject: PlaudReject[]; truncated: boolean } {
  const limit = opts.limit ?? 200;
  const recordings = extractRecordings(body);
  const accept: CalendarEventRow[] = [];
  const reject: PlaudReject[] = [];
  const seen = new Set<string>();
  let truncated = false;
  for (const rec of recordings) {
    if (accept.length + reject.length >= limit) {
      truncated = true;
      break;
    }
    const result = projectPlaudRecording(rec, opts);
    if (result.status === "rejected") {
      reject.push(result);
      continue;
    }
    if (seen.has(result.row.id)) {
      reject.push({ plaud_file_id: result.row.id, status: "rejected", reason: "bad_id" });
      continue;
    }
    seen.add(result.row.id);
    accept.push(result.row);
  }
  return { accept, reject, truncated };
}

function extractRecordings(body: unknown): PlaudRecordingInput[] {
  if (!body || typeof body !== "object") return [];
  const rec = body as Record<string, unknown>;
  if (Array.isArray(rec.recordings)) {
    return rec.recordings.filter((x) => x && typeof x === "object") as PlaudRecordingInput[];
  }
  if (rec.plaud_file_id) return [rec as PlaudRecordingInput];
  return [];
}

/** Speaker names per plaud_file_id, for attendee-name matching. Transcripts are never read or stored. */
export function extractPlaudSpeakers(body: unknown): Map<string, PlaudSpeaker[]> {
  const out = new Map<string, PlaudSpeaker[]>();
  for (const rec of extractRecordings(body)) {
    const id = asString(rec.plaud_file_id);
    if (!id) continue;
    const speakers = parseSpeakers(rec.speakers);
    if (speakers.length) out.set(id, speakers);
  }
  return out;
}
