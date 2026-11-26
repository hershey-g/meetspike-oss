import { bytesToHex } from "./hash.ts";

export const OURA_SIGNATURE_HEADER = "x-oura-signature";
export const OURA_TIMESTAMP_HEADER = "x-oura-timestamp";
export const WHOOP_SIGNATURE_HEADER = "x-whoop-signature";
export const WHOOP_TIMESTAMP_HEADER = "x-whoop-signature-timestamp";
export const DEFAULT_REPLAY_WINDOW_S = 300;

export type HmacVerifyResult = { ok: true } | { ok: false; status: 401; reason: string };

/** WHOOP signs timestamp + raw body, with a millisecond timestamp and base64 MAC. */
export async function verifyWhoopSignature(opts: {
  secret: string;
  signature: string | null;
  timestamp: string | null;
  rawBody: string;
  nowMs?: number;
}): Promise<HmacVerifyResult> {
  const { secret, signature, timestamp, rawBody } = opts;
  if (!secret || !signature || !timestamp) {
    return { ok: false, status: 401, reason: "missing signing configuration or headers" };
  }
  const ts = Number(timestamp);
  if (!/^\d+$/.test(timestamp) || !Number.isSafeInteger(ts)) {
    return { ok: false, status: 401, reason: "invalid timestamp" };
  }
  if (Math.abs((opts.nowMs ?? Date.now()) - ts) > DEFAULT_REPLAY_WINDOW_S * 1000) {
    return { ok: false, status: 401, reason: "timestamp outside replay window" };
  }
  // Canonical base64 for 32 bytes has two zero padding bits and one '='.
  if (!/^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/.test(signature)) {
    return { ok: false, status: 401, reason: "invalid signature encoding" };
  }
  const encoder = new TextEncoder();
  const bytes = Uint8Array.from(atob(signature), (char) => char.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"],
  );
  if (!(await crypto.subtle.verify("HMAC", key, bytes, encoder.encode(`${timestamp}${rawBody}`)))) {
    return { ok: false, status: 401, reason: "signature mismatch" };
  }
  return { ok: true };
}

/**
 * Oura signs `timestamp + rawBody` with HMAC-SHA256 of the OAuth client secret.
 * Compare hex, case-insensitive. Reject stale timestamps.
 * Use the RAW request body, never JSON.stringify of a parsed object.
 */
export async function verifyOuraSignature(opts: {
  secret: string;
  signature: string | null;
  timestamp: string | null;
  rawBody: string;
  nowMs?: number;
  replayWindowS?: number;
}): Promise<HmacVerifyResult> {
  const { secret, signature, timestamp, rawBody } = opts;
  if (!signature || !timestamp) {
    return { ok: false, status: 401, reason: "missing signature or timestamp" };
  }
  const ts = Number(timestamp);
  if (!Number.isFinite(ts)) {
    return { ok: false, status: 401, reason: "invalid timestamp" };
  }
  const now = opts.nowMs ?? Date.now();
  const windowS = opts.replayWindowS ?? DEFAULT_REPLAY_WINDOW_S;
  const tsMs = ts > 1e12 ? ts : ts * 1000;
  if (Math.abs(now - tsMs) > windowS * 1000) {
    return { ok: false, status: 401, reason: "timestamp outside replay window" };
  }
  const expected = await hmacSha256Hex(secret, `${timestamp}${rawBody}`);
  if (!timingSafeEqualHex(expected, signature)) {
    return { ok: false, status: 401, reason: "signature mismatch" };
  }
  return { ok: true };
}

export async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return bytesToHex(new Uint8Array(sig)).toUpperCase();
}

export function timingSafeEqualHex(a: string, b: string): boolean {
  const aa = a.trim().toUpperCase();
  const bb = b.trim().toUpperCase();
  if (aa.length !== bb.length) return false;
  let out = 0;
  for (let i = 0; i < aa.length; i++) out |= aa.charCodeAt(i) ^ bb.charCodeAt(i);
  return out === 0;
}
