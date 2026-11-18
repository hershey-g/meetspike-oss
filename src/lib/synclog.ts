import type { Env } from "../env.ts";
import { nowIso } from "./time.ts";

export async function writeSyncLog(
  env: Env,
  row: {
    trigger: string;
    source?: string;
    endpoint?: string | null;
    windowStart?: string | null;
    windowEnd?: string | null;
    status: "ok" | "partial" | "error";
    rowsWritten?: number;
    rowsSkipped?: number;
    errorText?: string | null;
    eventId?: string | null;
  },
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO sync_log
      (trigger, source, endpoint, window_start, window_end, status, rows_written, rows_skipped, error_text, event_id, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      row.trigger,
      row.source ?? "oura",
      row.endpoint ?? null,
      row.windowStart ?? null,
      row.windowEnd ?? null,
      row.status,
      row.rowsWritten ?? 0,
      row.rowsSkipped ?? 0,
      row.errorText ?? null,
      row.eventId ?? null,
      nowIso(),
    )
    .run();
}
