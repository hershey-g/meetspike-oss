import type { Env } from "../../env.ts";
import { getValidWhoopAccessToken, getWhoopTokens, refreshWhoopToken } from "../../lib/tokens.ts";
import {
  WHOOP_RATE_RULES,
  applyRateLimitHeaders,
  blockFor,
  newRateState,
  parseRateLimitHeaders,
  rateLimitDelayMs,
  recordRequest,
  retryAfterSeconds,
  type RateState,
} from "../../lib/rate-limit.ts";
import { WHOOP_API, WHOOP_COLLECTIONS, WHOOP_PAGE_LIMIT, type WhoopCollectionKey } from "./endpoints.ts";

export class WhoopRateLimitError extends Error {
  retryAfterS: number;
  constructor(retryAfterS: number, why = "429") {
    super(`whoop rate limit (${why}) — retry after ${retryAfterS}s`);
    this.name = "WhoopRateLimitError";
    this.retryAfterS = retryAfterS;
  }
}

/** Longest pause taken inline. Anything longer is handed back to the workflow's retry. */
const MAX_INLINE_WAIT_MS = 20_000;
/** Stop this far short of the daily cap; other runs may be counting too. */
const DAILY_MARGIN = 100;
const DAILY_LIMIT = WHOOP_RATE_RULES[1].limit;
const DAILY_KEY_PREFIX = "whoop:requests:";

/** Per-isolate pacing. The per-day count is also kept in KV (see below). */
let rate: RateState = newRateState();

export function resetWhoopRateState(): void {
  rate = newRateState();
}

export type WhoopCallOptions = {
  /** Counts requests so the caller can charge them to the daily budget. */
  tally?: { requests: number };
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
  signal?: AbortSignal;
  spacing?: { minMs: number; lastRequestAt?: number };
};

const defaultSleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

async function paced(url: string, token: string, opts: WhoopCallOptions): Promise<Response> {
  const now = opts.now ?? Date.now;
  const spacing = opts.spacing;
  const spacingDelay = spacing && spacing.lastRequestAt !== undefined ? spacing.lastRequestAt + spacing.minMs - now() : 0;
  const wait = Math.max(rateLimitDelayMs(rate, now()), spacingDelay);
  if (wait > MAX_INLINE_WAIT_MS) throw new WhoopRateLimitError(Math.ceil(wait / 1000), "local budget");
  if (wait > 0) await (opts.sleep ?? defaultSleep)(wait);
  opts.signal?.throwIfAborted();
  if (spacing) spacing.lastRequestAt = now();
  rate = recordRequest(rate, now());
  if (opts.tally) opts.tally.requests += 1;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` }, signal: opts.signal });
  rate = applyRateLimitHeaders(rate, now(), parseRateLimitHeaders(res.headers));
  if (res.status === 429) {
    const retry = retryAfterSeconds(res.headers);
    rate = blockFor(rate, now(), retry);
    throw new WhoopRateLimitError(retry);
  }
  return res;
}

/** GET a WHOOP API path. Paces requests, and refreshes the token once on a 401. */
export async function whoopFetch(env: Env, pathWithQuery: string, opts: WhoopCallOptions = {}): Promise<Response> {
  const url = pathWithQuery.startsWith("http") ? pathWithQuery : `${WHOOP_API}${pathWithQuery}`;
  // No abort signal on token calls: WHOOP retires the old refresh token, so an
  // aborted refresh after WHOOP answered would lose the new one.
  const token = await getValidWhoopAccessToken(env);
  let res = await paced(url, token, opts);
  if (res.status === 401) {
    const bundle = await getWhoopTokens(env);
    if (!bundle) throw new Error("whoop 401 and no tokens");
    const next = await refreshWhoopToken(env, bundle);
    res = await paced(url, next, opts);
  }
  if (!res.ok) throw new Error(`whoop ${res.status}: ${await res.text()}`);
  return res;
}

/**
 * Every record of a collection whose start time falls in [startIso, endIso).
 * Follows `next_token` until WHOOP stops returning one.
 */
export async function listWhoopCollection(
  env: Env,
  collection: WhoopCollectionKey,
  range: { startIso: string; endIso: string },
  opts: WhoopCallOptions = {},
): Promise<unknown[]> {
  const spec = WHOOP_COLLECTIONS[collection];
  const out: unknown[] = [];
  let next: string | null = null;
  do {
    const params = new URLSearchParams({
      limit: String(WHOOP_PAGE_LIMIT),
      start: range.startIso,
      end: range.endIso,
    });
    if (next) params.set("nextToken", next);
    const res = await whoopFetch(env, `${spec.path}?${params.toString()}`, opts);
    const json = (await res.json()) as { records?: unknown[]; next_token?: string | null };
    if (Array.isArray(json.records)) out.push(...json.records);
    next = json.next_token ? json.next_token : null;
  } while (next);
  return out;
}

function dailyKey(now: number): string {
  return `${DAILY_KEY_PREFIX}${new Date(now).toISOString().slice(0, 10)}`;
}

/** Requests already charged to today (UTC), across every run of this Worker. */
export async function whoopRequestsToday(env: Env, now = Date.now()): Promise<number> {
  const raw = await env.TOKENS.get(dailyKey(now));
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

/** Refuse to start a pull that could run past WHOOP's daily cap. */
export async function assertWhoopDailyBudget(env: Env, now = Date.now()): Promise<number> {
  const used = await whoopRequestsToday(env, now);
  if (used >= DAILY_LIMIT - DAILY_MARGIN) {
    const midnight = Date.parse(`${new Date(now).toISOString().slice(0, 10)}T00:00:00.000Z`) + 86_400_000;
    throw new WhoopRateLimitError(Math.ceil((midnight - now) / 1000), "daily budget");
  }
  return used;
}

export async function chargeWhoopRequests(env: Env, requests: number, now = Date.now()): Promise<void> {
  if (requests <= 0) return;
  const used = await whoopRequestsToday(env, now);
  await env.TOKENS.put(dailyKey(now), String(used + requests), { expirationTtl: 2 * 86_400 });
}
