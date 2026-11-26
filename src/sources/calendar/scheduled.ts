import type { Env } from "../../env.ts";
import { getGoogleTokens } from "../../lib/tokens.ts";
import { writeSyncLog } from "../../lib/synclog.ts";
import { SOURCE_GOOGLE } from "../../types.ts";
import { syncCalendarIncremental, type CalendarSyncResult } from "./ingest.ts";

/** Cron for the Worker's `scheduled` handler. Keep in step with `triggers.crons` in wrangler.jsonc. */
export const CALENDAR_SYNC_CRON = "*/15 * * * *";

/**
 * One scheduled calendar pass. Incremental, so a quiet calendar costs one
 * Google request (96 a day, far under the Calendar API quota). Never throws:
 * a Google blip is logged and the next tick tries again.
 */
export async function runScheduledCalendarSync(
  env: Env,
): Promise<CalendarSyncResult | { skipped: "no_google_tokens" } | { error: string }> {
  if (!(await getGoogleTokens(env))) return { skipped: "no_google_tokens" };
  try {
    return await syncCalendarIncremental(env, "cron");
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await writeSyncLog(env, {
      trigger: "cron",
      source: SOURCE_GOOGLE,
      endpoint: "events",
      status: "error",
      errorText: message,
    }).catch(() => {});
    return { error: message };
  }
}
