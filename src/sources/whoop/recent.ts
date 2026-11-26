import type { Env } from "../../env.ts";
import { loadTimeZone } from "../../lib/db.ts";
import { writeSyncLog } from "../../lib/synclog.ts";
import { addCalendarDays, calendarDayInZone, DEFAULT_TIME_ZONE } from "../../lib/time.ts";
import { getWhoopTokens } from "../../lib/tokens.ts";
import { SOURCE_WHOOP } from "../../types.ts";
import { WhoopRateLimitError, type WhoopCallOptions } from "./client.ts";
import { ingestWhoopWindow } from "./ingest.ts";

/**
 * Keeps today's WHOOP sleep, recovery and strain current during the day.
 *
 * The nightly reconcile runs at 06:00 Eastern, which is often before WHOOP has
 * scored the night, and it was the only pull. So a morning's sleep and
 * recovery stayed "No score" until the next morning. This pass re-reads
 * yesterday and today (about four WHOOP requests) on the 15-minute cron and
 * on a manual refresh. Rows are upserts and unchanged records are skipped, so
 * repeating it is cheap and safe.
 */
export const RECENT_SYNC_KEY = "whoop:recent-sync-at";
/** Cron ticks are 15 minutes apart; this only stops two overlapping ticks doubling up. */
export const CRON_MIN_INTERVAL_MS = 10 * 60_000;
/** A pull-to-refresh can ask again after this long. */
export const MANUAL_MIN_INTERVAL_MS = 60_000;

export type RecentWhoopResult =
  | { ok: true; written: number; unchanged: number; window: { start: string; end: string } }
  | { ok: true; skipped: "not_connected" | "too_soon" }
  | { ok: false; error: string; rateLimited?: boolean; retryAfterS?: number };

type RecentDeps = {
  now?: () => number;
  ingest?: typeof ingestWhoopWindow;
};

/** Yesterday and today in the user's time zone: last night's sleep and today's cycle. */
export function recentWindow(nowMs: number, timeZone: string): { start: string; end: string } {
  const today = calendarDayInZone(new Date(nowMs).toISOString(), timeZone);
  return { start: addCalendarDays(today, -1), end: today };
}

/** Never throws. Errors are logged to sync_log and returned. */
export async function syncRecentWhoop(
  env: Env,
  opts: { trigger: string; minIntervalMs: number; requestOptions?: WhoopCallOptions },
  deps: RecentDeps = {},
): Promise<RecentWhoopResult> {
  const now = deps.now ? deps.now() : Date.now();
  let window: { start: string; end: string } | null = null;
  try {
    if (!(await getWhoopTokens(env))) return { ok: true, skipped: "not_connected" };
    if (opts.trigger !== "webhook") {
      const last = Number(await env.TOKENS.get(RECENT_SYNC_KEY));
      if (Number.isFinite(last) && last > 0 && now - last < opts.minIntervalMs) return { ok: true, skipped: "too_soon" };
    }
    const stamp = env.TOKENS.put(RECENT_SYNC_KEY, String(now), { expirationTtl: 86_400 });
    // D1 already serialized webhook pulls. For them, the KV stamp is a hint for cron and manual refresh.
    await (opts.trigger === "webhook" ? stamp.catch(() => {}) : stamp);
    const tz = await loadTimeZone(env.DB).catch(() => DEFAULT_TIME_ZONE);
    window = recentWindow(now, tz);
    const tally = await (deps.ingest ?? ingestWhoopWindow)(env, window, opts.trigger, opts.requestOptions);
    return { ok: true, written: tally.written, unchanged: tally.skipped, window };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    // A failed pull should not wait out the interval; a rate limit should.
    if (!(err instanceof WhoopRateLimitError)) await env.TOKENS.delete(RECENT_SYNC_KEY).catch(() => {});
    await writeSyncLog(env, {
      trigger: opts.trigger,
      source: SOURCE_WHOOP,
      endpoint: "recovery,cycle,sleep,workout",
      windowStart: window?.start ?? null,
      windowEnd: window?.end ?? null,
      status: "error",
      errorText: message,
    }).catch(() => {});
    return { ok: false, error: message, ...(err instanceof WhoopRateLimitError ? { rateLimited: true, retryAfterS: err.retryAfterS } : {}) };
  }
}
