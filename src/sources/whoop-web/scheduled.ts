import type { Env } from "../../env.ts";
import { writeSyncLog } from "../../lib/synclog.ts";
import { SOURCE_WHOOP_WEB } from "./constants.ts";
import { runWhoopWebFill, type FillRunResult } from "./fill.ts";

/**
 * The 15-minute cron's WHOOP web pass. Off unless WHOOP_WEB_HR is on and
 * WHOOP is the active wearable. No password login unless
 * WHOOP_WEB_WORKER_LOGIN is on (this build has no WHOOP web API client).
 * Never throws: trouble is logged and the next tick tries again.
 */
export async function runScheduledWhoopWebFill(env: Env): Promise<FillRunResult | { error: string }> {
  try {
    return await runWhoopWebFill(env, { trigger: "cron" });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await writeSyncLog(env, {
      trigger: "cron",
      source: SOURCE_WHOOP_WEB,
      endpoint: "fill",
      status: "error",
      errorText: message,
    }).catch(() => {});
    return { error: message };
  }
}
