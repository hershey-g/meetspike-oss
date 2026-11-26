/**
 * One-time codes that pair the iPhone app without typing secrets.
 *
 * The setup page (behind Cloudflare Access) asks for a code. The QR it shows
 * holds only `meetspike://pair?origin=<origin>&code=<code>`, never a secret.
 * The phone trades the code once, over HTTPS, at POST /hooks/pair for the
 * ingest secret (and the Access service token, when the Worker has one).
 *
 * A code is 48 URL-safe characters: a 16-character id that names the KV key
 * and a 32-character secret (192 random bits). KV keeps only the SHA-256 of
 * the secret, so a database read alone cannot redeem a code, and the secret
 * is compared in constant time. Codes live in D1 (`pair_codes`, migration
 * 0016), last ten minutes, and are deleted on the first attempt, right or
 * wrong, by one atomic DELETE ... RETURNING. Making a new code deletes every
 * older one, so only the code on screen works.
 */
import { timingSafeEqual } from "./secret.ts";

export const PAIR_PREFIX = "pair:";
export const PAIR_TTL_S = 600;
export const PAIR_ID_LEN = 16;
export const PAIR_SECRET_LEN = 32;
export const PAIR_CODE_LEN = PAIR_ID_LEN + PAIR_SECRET_LEN;
const CODE_RE = new RegExp(`^[A-Za-z0-9_-]{${PAIR_CODE_LEN}}$`);

/** Exchange attempts allowed per client IP. Codes are unguessable; this only caps noise. */
export const PAIR_RATE_RULES = [
  { limit: 5, windowMs: 60_000 },
  { limit: 20, windowMs: 3_600_000 },
] as const;

export type StoredPairing = { h: string; exp: number };

function base64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** 12 random bytes make 16 characters; 24 make 32. */
export function newPairingCode(random: (n: number) => Uint8Array = (n) => crypto.getRandomValues(new Uint8Array(n))): string {
  return base64url(random(12)) + base64url(random(24));
}

export function splitCode(code: unknown): { id: string; secret: string } | null {
  if (typeof code !== "string" || !CODE_RE.test(code)) return null;
  return { id: code.slice(0, PAIR_ID_LEN), secret: code.slice(PAIR_ID_LEN) };
}

export function rateKey(ip: string): string {
  return `${PAIR_PREFIX}rl:${ip}`;
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function storedPairing(secret: string, now: number): Promise<StoredPairing> {
  return { h: await sha256Hex(secret), exp: now + PAIR_TTL_S * 1000 };
}

/** Saves a new code and deletes every older one: only the newest code works. */
export async function saveNewPairing(db: D1Database, id: string, stored: StoredPairing): Promise<void> {
  await db.prepare("DELETE FROM pair_codes").run();
  await db.prepare("INSERT INTO pair_codes (id, secret_hash, expires_at) VALUES (?1, ?2, ?3)").bind(id, stored.h, stored.exp).run();
}

/**
 * Deletes the code and returns what it held, in one statement. Of two racing
 * requests for the same id, only one gets a row back.
 */
export async function takePairing(db: D1Database, id: string): Promise<StoredPairing | null> {
  const row = await db
    .prepare("DELETE FROM pair_codes WHERE id = ?1 RETURNING secret_hash, expires_at")
    .bind(id)
    .first<{ secret_hash: unknown; expires_at: unknown }>();
  if (!row || typeof row.secret_hash !== "string" || typeof row.expires_at !== "number") return null;
  return { h: row.secret_hash, exp: row.expires_at };
}

/** True when D1 says the pairing table is missing (migration 0016 not applied). */
export function missingPairTable(err: unknown): boolean {
  return /no such table:\s*pair_codes/i.test(String((err as Error)?.message ?? err));
}

/** True when `secret` matches and the code has not expired. Constant time on the hash. */
export async function redeemable(stored: StoredPairing, secret: string, now: number): Promise<boolean> {
  const match = timingSafeEqual(await sha256Hex(secret), stored.h);
  return match && now <= stored.exp;
}

/** The link inside the QR code. The phone opens it, or scans it in Settings. */
export function pairingUrl(origin: string, code: string): string {
  return `meetspike://pair?origin=${encodeURIComponent(origin)}&code=${encodeURIComponent(code)}`;
}
