/**
 * Client-side request budget for an API with a per-minute and a per-day cap.
 * Pure: the caller passes the clock, so it is testable and has no timers.
 *
 * WHOOP's documented defaults are 100 requests / minute and 10,000 / day.
 */
export type RateLimitRule = { limit: number; windowMs: number };

export const WHOOP_RATE_RULES: readonly RateLimitRule[] = [
  { limit: 100, windowMs: 60_000 },
  { limit: 10_000, windowMs: 86_400_000 },
];

export type RateState = {
  /** Start times (ms) of requests still inside the longest window, ascending. */
  stamps: number[];
  /** Do not send before this instant (ms). Set from server headers or a 429. */
  blockedUntil: number;
};

export function newRateState(): RateState {
  return { stamps: [], blockedUntil: 0 };
}

function longestWindow(rules: readonly RateLimitRule[]): number {
  return rules.reduce((m, r) => Math.max(m, r.windowMs), 0);
}

/** Drop requests that have aged out of every window. */
export function pruneRateState(state: RateState, now: number, rules: readonly RateLimitRule[]): RateState {
  const horizon = now - longestWindow(rules);
  return { stamps: state.stamps.filter((t) => t > horizon), blockedUntil: state.blockedUntil };
}

/** Milliseconds to wait before one more request is within every rule. 0 = go now. */
export function rateLimitDelayMs(state: RateState, now: number, rules: readonly RateLimitRule[] = WHOOP_RATE_RULES): number {
  let wait = Math.max(0, state.blockedUntil - now);
  for (const rule of rules) {
    const inWindow = state.stamps.filter((t) => t > now - rule.windowMs);
    if (inWindow.length < rule.limit) continue;
    // The slot frees when the request `limit` places back leaves the window.
    const frees = inWindow[inWindow.length - rule.limit] + rule.windowMs;
    wait = Math.max(wait, frees - now);
  }
  return Math.max(0, Math.ceil(wait));
}

/** Record that a request was sent at `now`. */
export function recordRequest(state: RateState, now: number, rules: readonly RateLimitRule[] = WHOOP_RATE_RULES): RateState {
  const next = pruneRateState(state, now, rules);
  next.stamps.push(now);
  return next;
}

/** How many more requests fit right now under each rule (smallest wins). */
export function remainingNow(state: RateState, now: number, rules: readonly RateLimitRule[] = WHOOP_RATE_RULES): number {
  let left = Infinity;
  for (const rule of rules) {
    const used = state.stamps.filter((t) => t > now - rule.windowMs).length;
    left = Math.min(left, rule.limit - used);
  }
  return Math.max(0, left);
}

export type RateLimitHeaders = {
  /** Requests left in the window closest to its cap. */
  remaining: number | null;
  /** Seconds until that window resets. */
  resetS: number | null;
};

function headerNumber(raw: string | null): number | null {
  if (raw == null) return null;
  // draft-polli-ratelimit-headers: the first item is the value; the rest is policy detail.
  const first = raw.split(/[,;]/)[0]?.trim() ?? "";
  if (first === "") return null;
  const n = Number(first);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

/** Read `X-RateLimit-Remaining` / `X-RateLimit-Reset` (seconds). Missing or junk is null. */
export function parseRateLimitHeaders(headers: { get(name: string): string | null }): RateLimitHeaders {
  return {
    remaining: headerNumber(headers.get("X-RateLimit-Remaining")),
    resetS: headerNumber(headers.get("X-RateLimit-Reset")),
  };
}

/** Seconds to back off after a 429: `Retry-After`, else the reset header, else a floor. */
export function retryAfterSeconds(headers: { get(name: string): string | null }, fallbackS = 60): number {
  const retry = headerNumber(headers.get("Retry-After"));
  if (retry != null && retry > 0) return Math.ceil(retry);
  const { resetS } = parseRateLimitHeaders(headers);
  if (resetS != null && resetS > 0) return Math.ceil(resetS);
  return fallbackS;
}

/**
 * Fold what the server said into local state. When the server reports nothing
 * left, hold off until its reset — it counts requests we cannot see (other
 * isolates, earlier runs).
 */
export function applyRateLimitHeaders(state: RateState, now: number, h: RateLimitHeaders): RateState {
  if (h.remaining === 0 && h.resetS != null) {
    return { stamps: state.stamps, blockedUntil: Math.max(state.blockedUntil, now + h.resetS * 1000) };
  }
  return state;
}

/** Hold off for `seconds` from `now` (after a 429). */
export function blockFor(state: RateState, now: number, seconds: number): RateState {
  return { stamps: state.stamps, blockedUntil: Math.max(state.blockedUntil, now + seconds * 1000) };
}
