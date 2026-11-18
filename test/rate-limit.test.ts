import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  WHOOP_RATE_RULES,
  applyRateLimitHeaders,
  blockFor,
  newRateState,
  parseRateLimitHeaders,
  rateLimitDelayMs,
  recordRequest,
  remainingNow,
  retryAfterSeconds,
  type RateState,
} from "../src/lib/rate-limit.ts";

const T0 = Date.parse("2026-11-17T12:00:00.000Z");

function send(state: RateState, count: number, at: number, everyMs = 0): RateState {
  let s = state;
  for (let i = 0; i < count; i += 1) s = recordRequest(s, at + i * everyMs);
  return s;
}

function headers(h: Record<string, string>) {
  return new Headers(h);
}

describe("WHOOP rate rules", () => {
  it("are 100 a minute and 10,000 a day", () => {
    assert.deepEqual(WHOOP_RATE_RULES, [
      { limit: 100, windowMs: 60_000 },
      { limit: 10_000, windowMs: 86_400_000 },
    ]);
  });
});

describe("rateLimitDelayMs", () => {
  it("lets the first 100 requests in a minute through and holds the 101st", () => {
    let s = newRateState();
    for (let i = 0; i < 100; i += 1) {
      assert.equal(rateLimitDelayMs(s, T0 + i), 0, `request ${i + 1}`);
      s = recordRequest(s, T0 + i);
    }
    // The 101st has to wait until the first one is a minute old.
    assert.equal(rateLimitDelayMs(s, T0 + 100), 60_000 - 100);
    assert.equal(remainingNow(s, T0 + 100), 0);
  });

  it("frees one slot at a time as requests age out of the minute", () => {
    const s = send(newRateState(), 100, T0, 100); // one every 100 ms, T0 … T0+9.9s
    assert.equal(rateLimitDelayMs(s, T0 + 60_000), 0, "the first request has aged out");
    const after = recordRequest(s, T0 + 60_000);
    assert.equal(rateLimitDelayMs(after, T0 + 60_000), 100, "the next slot frees 100 ms later");
  });

  it("enforces the daily cap even when every minute is under its limit", () => {
    // 10,000 requests spread evenly over ~23 hours: 8.28 s apart, about 7 a minute.
    const s = send(newRateState(), 10_000, T0, 8_280);
    const now = T0 + 10_000 * 8_280;
    assert.equal(remainingNow(s, now), 0);
    const wait = rateLimitDelayMs(s, now);
    assert.equal(wait, T0 + 86_400_000 - now, "waits for the first request of the day to age out");
    assert.equal(rateLimitDelayMs(s, T0 + 86_400_000), 0);
  });

  it("forgets requests older than a day", () => {
    const s = send(newRateState(), 50, T0);
    const later = recordRequest(s, T0 + 86_400_001);
    assert.equal(later.stamps.length, 1);
    assert.equal(remainingNow(later, T0 + 86_400_001), 99);
  });
});

describe("server headers", () => {
  it("reads WHOOP's X-RateLimit headers, including the policy form", () => {
    assert.deepEqual(
      parseRateLimitHeaders(headers({ "X-RateLimit-Remaining": "98", "X-RateLimit-Reset": "30" })),
      { remaining: 98, resetS: 30 },
    );
    assert.deepEqual(
      parseRateLimitHeaders(headers({ "X-RateLimit-Limit": "100, 100;window=60, 10000;window=86400", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "12" })),
      { remaining: 0, resetS: 12 },
    );
    assert.deepEqual(parseRateLimitHeaders(headers({})), { remaining: null, resetS: null });
    assert.deepEqual(parseRateLimitHeaders(headers({ "X-RateLimit-Remaining": "soon" })), { remaining: null, resetS: null });
  });

  it("holds off until the server's reset when nothing is left", () => {
    const blocked = applyRateLimitHeaders(newRateState(), T0, { remaining: 0, resetS: 30 });
    assert.equal(rateLimitDelayMs(blocked, T0), 30_000);
    assert.equal(rateLimitDelayMs(blocked, T0 + 30_000), 0);
    const fine = applyRateLimitHeaders(newRateState(), T0, { remaining: 40, resetS: 30 });
    assert.equal(rateLimitDelayMs(fine, T0), 0);
  });

  it("backs off after a 429 using Retry-After, then the reset header, then a floor", () => {
    assert.equal(retryAfterSeconds(headers({ "Retry-After": "7", "X-RateLimit-Reset": "30" })), 7);
    assert.equal(retryAfterSeconds(headers({ "X-RateLimit-Reset": "30" })), 30);
    assert.equal(retryAfterSeconds(headers({})), 60);
    const s = blockFor(newRateState(), T0, 30);
    assert.equal(rateLimitDelayMs(s, T0 + 10_000), 20_000);
  });
});
