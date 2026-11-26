import type { WorkflowStep } from "cloudflare:workers";
import type { Env } from "../env.ts";
import { SOURCE_WHOOP, type WearableSource } from "../types.ts";
import { writeSyncLog } from "./synclog.ts";
import { ACTIVE_ENDPOINTS, chunkWindows } from "../sources/oura/endpoints.ts";
import { OURA_RECENT_ENDPOINTS } from "../sources/oura/recent.ts";
import { RateLimitError } from "../sources/oura/client.ts";
import { ingestEndpointWindow } from "../sources/oura/ingest.ts";
import { WHOOP_WINDOW_DAYS } from "../sources/whoop/endpoints.ts";
import { WhoopRateLimitError } from "../sources/whoop/client.ts";
import { ingestWhoopWindow } from "../sources/whoop/ingest.ts";

export const HISTORY_START_DAY = "2010-01-01";
export const WHOOP_HISTORY_ENDPOINT = "recovery,cycle,sleep,workout";

export type HistoryWindow = { endpoint: string; start: string; end: string };
export type HistoryPlan = {
  source: WearableSource;
  startDay: string;
  endDay: string;
  trigger: string;
  fullHistory: boolean;
};

export function historyWindows(plan: HistoryPlan): HistoryWindow[] {
  const { source, startDay, endDay, fullHistory } = plan;
  if (source === SOURCE_WHOOP) {
    return chunkWindows(startDay, endDay, WHOOP_WINDOW_DAYS).map((w) => ({ ...w, endpoint: WHOOP_HISTORY_ENDPOINT }));
  }
  const specs = fullHistory
    ? ACTIVE_ENDPOINTS.filter((spec) => OURA_RECENT_ENDPOINTS.some((key) => key === spec.key))
    : ACTIVE_ENDPOINTS;
  return specs.flatMap((spec) =>
    chunkWindows(startDay, endDay, spec.maxDays).map((w) => ({ ...w, endpoint: spec.key })),
  );
}

type Steps = Pick<WorkflowStep, "do" | "sleep">;
const STEP = { retries: { limit: 5, delay: "30 seconds", backoff: "exponential" as const } };
const PACE_MS = 1000;
const RATE_ATTEMPTS = 8;

export async function runWearableHistory(
  env: Env,
  step: Steps,
  plan: HistoryPlan,
  ingest = (w: HistoryWindow) => plan.source === SOURCE_WHOOP
    ? ingestWhoopWindow(env, w, plan.trigger, { spacing: { minMs: PACE_MS } })
    : ingestEndpointWindow(env, w.endpoint, w, plan.trigger, { minMs: PACE_MS }),
) {
  const totals = { written: 0, skipped: 0, completedWindows: 0 };
  for (const window of historyWindows(plan)) {
    const { endpoint, start, end } = window;
    const name = `${plan.source}:${endpoint}:${start}:${end}`;
    for (let attempt = 0; attempt < RATE_ATTEMPTS; attempt++) {
      const result = await step.do(`${name}:${attempt}`, STEP, async () => {
        if (plan.fullHistory) {
          const checkpoint = await env.DB.prepare(
            `SELECT rows_written AS written, rows_skipped AS skipped FROM sync_log
             WHERE trigger = ? AND source = ? AND status = 'ok'
               AND endpoint = ? AND window_start = ? AND window_end = ?
             ORDER BY id LIMIT 1`,
          ).bind(plan.trigger, plan.source, endpoint, start, end).first<{ written: number; skipped: number }>();
          if (checkpoint) return { ...checkpoint, fetched: false };
        }
        try {
          const tally = await ingest(window);
          return { ...tally, fetched: true };
        } catch (err) {
          if (err instanceof RateLimitError || err instanceof WhoopRateLimitError) {
            await writeSyncLog(env, {
              trigger: plan.trigger, source: plan.source, endpoint, windowStart: start, windowEnd: end,
              status: "partial", errorText: `Provider rate limit. Retry after ${err.retryAfterS}s.`,
            });
            return { retryAfterS: err.retryAfterS };
          }
          await writeSyncLog(env, {
            trigger: plan.trigger, source: plan.source, endpoint, windowStart: start, windowEnd: end,
            status: "error", errorText: "Window import failed.",
          });
          throw err;
        }
      });
      if (result.retryAfterS !== undefined) {
        const wait = Math.max(result.retryAfterS, 2 ** attempt);
        await step.sleep(`${name}:rate-limit:${attempt}`, wait * 1000);
        if (attempt === RATE_ATTEMPTS - 1) throw new Error(`Rate limit persisted for ${name}`);
        continue;
      }
      totals.written += result.written;
      totals.skipped += result.skipped;
      totals.completedWindows++;
      if (result.fetched && plan.fullHistory) await step.sleep(`${name}:pace`, PACE_MS);
      break;
    }
  }
  return totals;
}
