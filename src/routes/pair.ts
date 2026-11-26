import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import type { Env } from "../env.ts";
import {
  PAIR_RATE_RULES,
  PAIR_TTL_S,
  missingPairTable,
  newPairingCode,
  pairingUrl,
  rateKey,
  redeemable,
  saveNewPairing,
  splitCode,
  storedPairing,
  takePairing,
} from "../lib/pairing.ts";
import { newRateState, rateLimitDelayMs, recordRequest, type RateState } from "../lib/rate-limit.ts";
import { requireAccessUser } from "../lib/access-jwt.ts";

const GONE = "This code has expired or was already used. Make a new one on the setup page.";
const NO_TABLE = "Apply D1 migration 0016_pair_codes.sql to the Worker's database first.";

function has(v: string | undefined): v is string {
  return typeof v === "string" && v.trim() !== "";
}

function accessToken(env: Env): { clientId: string; clientSecret: string } | null {
  if (!has(env.PHONE_ACCESS_CLIENT_ID) || !has(env.PHONE_ACCESS_CLIENT_SECRET)) return null;
  return { clientId: env.PHONE_ACCESS_CLIENT_ID.trim(), clientSecret: env.PHONE_ACCESS_CLIENT_SECRET.trim() };
}

/**
 * POST /api/pair/start, behind Cloudflare Access with the rest of /api/*.
 * Makes a ten-minute, single-use code and returns the meetspike:// link the
 * setup page draws as a QR code. Never returns a secret.
 *
 * A code is worth the ingest secret, so this does not trust that Access sits
 * in front: it verifies the Access token itself (signature, issuer, AUD,
 * expiry) and needs a signed-in person, not a service token. Without
 * ACCESS_TEAM_DOMAIN and ACCESS_AUD it refuses, except on wrangler dev.
 */
export const pairStart = new Hono<{ Bindings: Env }>();

pairStart.post("/start", async (c) => {
  c.header("Cache-Control", "private, no-store");
  const gate = await requireAccessUser(c.req.raw.headers, c.req.url, c.env);
  if (!gate.ok) {
    console.log(JSON.stringify({ event: "pair_start_denied", reason: gate.reason }));
    return c.json({ error: gate.error }, gate.status);
  }
  if (!has(c.env.INGEST_ADMIN_SECRET)) {
    return c.json({ error: "Add the INGEST_ADMIN_SECRET secret to your Worker first." }, 503);
  }
  const now = Date.now();
  const code = newPairingCode();
  const { id, secret } = splitCode(code)!;
  try {
    await saveNewPairing(c.env.DB, id, await storedPairing(secret, now));
  } catch (err) {
    if (missingPairTable(err)) return c.json({ error: NO_TABLE }, 503);
    throw err;
  }
  console.log(JSON.stringify({ event: "pair_start" }));
  const origin = new URL(c.req.url).origin;
  return c.json({
    ok: true,
    url: pairingUrl(origin, code),
    origin,
    expiresAt: new Date(now + PAIR_TTL_S * 1000).toISOString(),
    includesAccessToken: accessToken(c.env) !== null,
  });
});

/**
 * POST /hooks/pair { code }. Under /hooks/, which bypasses Access, so a
 * phone with no Access token yet can reach it. The code is the only
 * authorization: unguessable, ten minutes, deleted on the first attempt.
 * Nothing here logs the code or the reply.
 */
export const pairExchange = new Hono<{ Bindings: Env }>();

pairExchange.post(
  "/",
  async (c, next) => {
    c.header("Cache-Control", "private, no-store");
    await next();
  },
  bodyLimit({ maxSize: 512, onError: (c) => c.json({ error: "body too large" }, 413) }),
  async (c) => {
    const now = Date.now();
    const ip = c.req.header("cf-connecting-ip")?.trim() || "unknown";
    const rk = rateKey(ip);
    let rate: RateState = newRateState();
    try {
      const saved = JSON.parse((await c.env.TOKENS.get(rk)) ?? "null") as RateState | null;
      if (saved && Array.isArray(saved.stamps)) rate = { stamps: saved.stamps, blockedUntil: Number(saved.blockedUntil) || 0 };
    } catch {
      /* start fresh */
    }
    const wait = rateLimitDelayMs(rate, now, PAIR_RATE_RULES);
    if (wait > 0) {
      c.header("Retry-After", String(Math.ceil(wait / 1000)));
      return c.json({ error: "Too many tries. Wait a minute and scan again." }, 429);
    }
    await c.env.TOKENS.put(rk, JSON.stringify(recordRequest(rate, now, PAIR_RATE_RULES)), { expirationTtl: 3600 });

    const body = (await c.req.json().catch(() => null)) as { code?: unknown } | null;
    const parts = splitCode(body?.code);
    if (!parts) return c.json({ error: "That is not a Meetspike setup code." }, 400);

    // Checked before the code is spent, so fixing the Worker lets the same code work.
    const ingestSecret = c.env.INGEST_ADMIN_SECRET?.trim() ?? "";
    if (!ingestSecret) return c.json({ error: "INGEST_ADMIN_SECRET is not set" }, 503);

    // Single use: any attempt on a real id burns it, right secret or not.
    let stored;
    try {
      stored = await takePairing(c.env.DB, parts.id);
    } catch (err) {
      if (missingPairTable(err)) return c.json({ error: GONE }, 404);
      throw err;
    }
    if (!stored) return c.json({ error: GONE }, 404);
    if (!(await redeemable(stored, parts.secret, now))) {
      console.log(JSON.stringify({ event: "pair_rejected" }));
      return c.json({ error: GONE }, 404);
    }
    const access = accessToken(c.env);
    console.log(JSON.stringify({ event: "pair_redeemed", access: access !== null }));
    return c.json({ ok: true, ingestSecret, access });
  },
);
