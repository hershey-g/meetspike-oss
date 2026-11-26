import type { Env } from "../../env.ts";
import { getOuraTokens } from "../../lib/tokens.ts";
import { writeSyncLog } from "../../lib/synclog.ts";
import { addUtcDays, formatUtcDay } from "./endpoints.ts";
import { RateLimitError } from "./client.ts";
import { ingestEndpointWindow } from "./ingest.ts";

export const OURA_MORNING_ENDPOINTS = ["daily_sleep", "daily_readiness", "sleep"] as const;
export const OURA_RECENT_ENDPOINTS = [...OURA_MORNING_ENDPOINTS, "heartrate"] as const;

const NEXT_SYNC = "oura:recent-sync-after";
const intervalMs = 10 * 60_000;
let running: Promise<RecentOuraResult> | undefined;

type RecentOuraResult =
  | { ok: true; skipped: "not_connected" | "too_soon" }
  | { ok: true; written: number; unchanged: number }
  | { ok: false; error: string };

async function pull(env: Env, trigger: string): Promise<RecentOuraResult> {
  const end = formatUtcDay(new Date());
  const window = { start: addUtcDays(end, -1), end };
  let endpoint: string | null = null;
  try {
    if (!(await getOuraTokens(env))) return { ok: true, skipped: "not_connected" };
    const now = Date.now();
    if (Number(await env.TOKENS.get(NEXT_SYNC)) > now) return { ok: true, skipped: "too_soon" };
    await env.TOKENS.put(NEXT_SYNC, String(now + intervalMs), { expirationTtl: 86_400 });
    let written = 0;
    let unchanged = 0;
    const pacing = { minMs: 1000 };
    for (const key of OURA_RECENT_ENDPOINTS) {
      endpoint = key;
      const tally = await ingestEndpointWindow(env, key, window, trigger, pacing);
      written += tally.written;
      unchanged += tally.skipped;
    }
    return { ok: true, written, unchanged };
  } catch (err) {
    const error = err instanceof Error ? err.message : String(err);
    if (err instanceof RateLimitError && err.retryAfterS * 1000 > intervalMs) {
      await env.TOKENS.put(NEXT_SYNC, String(Date.now() + err.retryAfterS * 1000), {
        expirationTtl: Math.max(86_400, err.retryAfterS),
      }).catch(() => {});
    }
    await writeSyncLog(env, {
      trigger, endpoint, windowStart: window.start, windowEnd: window.end, status: "error", errorText: error,
    }).catch(() => {});
    return { ok: false, error };
  }
}

export function syncRecentOura(env: Env, trigger: string): Promise<RecentOuraResult> {
  running ??= pull(env, trigger).finally(() => { running = undefined; });
  return running;
}
