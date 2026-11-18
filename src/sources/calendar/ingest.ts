import type { Env } from "../../env.ts";
import type { CalendarEventRow } from "../../types.ts";
import { SOURCE_GOOGLE, SOURCE_SANDBOX_CAL } from "../../types.ts";
import { canonicalJson, r2Key, sha256Hex } from "../../lib/hash.ts";
import { nowIso } from "../../lib/time.ts";
import { findRaw, insertRaw, loadTimeZone, upsertCalendarEvent } from "../../lib/db.ts";
import { putRawJson } from "../../lib/r2.ts";
import { writeSyncLog } from "../../lib/synclog.ts";
import { listPrimaryEvents } from "./client.ts";
import { makeCalendarFixtures } from "./fixtures.ts";
import { projectGoogleEvent, type GoogleCalendarEvent } from "./project.ts";

export type IngestTally = { written: number; skipped: number };

export async function ingestCalendarEvent(
  env: Env,
  event: GoogleCalendarEvent,
  opts: { source: CalendarEventRow["source"]; timeZone: string; fetchedAt?: string },
): Promise<"written" | "skipped"> {
  const fetchedAt = opts.fetchedAt ?? nowIso();
  const body = canonicalJson(event);
  const hash = await sha256Hex(body);
  const documentId = event.id ?? hash.slice(0, 16);
  const existing = await findRaw(env.DB, "events", documentId, hash, opts.source);
  let rawId: number | null = existing?.id ?? null;
  if (!existing) {
    const key = r2Key(opts.source, "events", documentId, hash);
    await putRawJson(env, key, body);
    rawId = await insertRaw(
      env.DB,
      {
        endpoint: "events",
        documentId,
        day: event.start?.date ?? event.start?.dateTime?.slice(0, 10) ?? null,
        r2Key: key,
        hash,
        fetchedAt,
      },
      opts.source,
    );
  }
  const row = projectGoogleEvent(event, fetchedAt, opts.timeZone, rawId, opts.source);
  if (!row) return "skipped";
  return upsertCalendarEvent(env.DB, row);
}

export async function syncPrimaryCalendar(
  env: Env,
  window: { start: string; end: string },
  trigger = "calendar-sync",
): Promise<IngestTally> {
  const timeZone = await loadTimeZone(env.DB);
  const events = await listPrimaryEvents(env, window, timeZone);
  const tally: IngestTally = { written: 0, skipped: 0 };
  for (const event of events) {
    const r = await ingestCalendarEvent(env, event, { source: SOURCE_GOOGLE, timeZone });
    if (r === "written") tally.written += 1;
    else tally.skipped += 1;
  }
  await writeSyncLog(env, {
    trigger,
    source: SOURCE_GOOGLE,
    endpoint: "events",
    windowStart: window.start,
    windowEnd: window.end,
    status: "ok",
    rowsWritten: tally.written,
    rowsSkipped: tally.skipped,
  });
  return tally;
}

export async function ingestCalendarFixtures(env: Env, trigger = "calendar-fixtures"): Promise<IngestTally> {
  const timeZone = await loadTimeZone(env.DB);
  const tally: IngestTally = { written: 0, skipped: 0 };
  for (const event of makeCalendarFixtures()) {
    const r = await ingestCalendarEvent(env, event, { source: SOURCE_SANDBOX_CAL, timeZone });
    if (r === "written") tally.written += 1;
    else tally.skipped += 1;
  }
  await writeSyncLog(env, {
    trigger,
    source: SOURCE_SANDBOX_CAL,
    endpoint: "events",
    status: "ok",
    rowsWritten: tally.written,
    rowsSkipped: tally.skipped,
  });
  return tally;
}
