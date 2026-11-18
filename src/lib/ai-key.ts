/**
 * The user's own Claude API key, stored encrypted in the TOKENS KV namespace.
 *
 * The key is sealed with AES-GCM under a key derived from the AI_KEY_SECRET
 * Worker secret, so a KV dump alone does not reveal it. It never goes back to
 * the browser: the status call returns only its last four characters.
 */
import type { Env } from "../env.ts";

export const AI_KEY_KV = "ai:anthropic";

type Sealed = { v: 1; iv: string; ct: string; tail: string; savedAt: string };

function b64(bytes: ArrayBuffer | Uint8Array): string {
  const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (const b of u8) s += String.fromCharCode(b);
  return btoa(s);
}

function unb64(text: string): Uint8Array {
  const s = atob(text);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i += 1) out[i] = s.charCodeAt(i);
  return out;
}

/** True when the Worker has a secret long enough to seal keys with. */
export function canStoreAiKey(env: Env): boolean {
  return (env.AI_KEY_SECRET?.trim().length ?? 0) >= 32;
}

async function cryptoKey(env: Env): Promise<CryptoKey> {
  const secret = env.AI_KEY_SECRET?.trim() ?? "";
  if (secret.length < 32) throw new Error("AI_KEY_SECRET is not set (32+ characters)");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`meetspike-ai-key:${secret}`));
  return crypto.subtle.importKey("raw", digest, "AES-GCM", false, ["encrypt", "decrypt"]);
}

/** Loose shape check so an obvious paste mistake fails before any network call. */
export function looksLikeAnthropicKey(key: string): boolean {
  return /^sk-ant-[A-Za-z0-9_-]{20,}$/.test(key.trim());
}

export async function saveAiKey(env: Env, apiKey: string, now = new Date()): Promise<{ tail: string; savedAt: string }> {
  const key = apiKey.trim();
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await cryptoKey(env), new TextEncoder().encode(key));
  const sealed: Sealed = { v: 1, iv: b64(iv), ct: b64(ct), tail: key.slice(-4), savedAt: now.toISOString() };
  await env.TOKENS.put(AI_KEY_KV, JSON.stringify(sealed));
  return { tail: sealed.tail, savedAt: sealed.savedAt };
}

export async function aiKeyInfo(env: Env): Promise<{ tail: string; savedAt: string } | null> {
  const raw = await env.TOKENS.get(AI_KEY_KV);
  if (!raw) return null;
  try {
    const s = JSON.parse(raw) as Sealed;
    return { tail: s.tail, savedAt: s.savedAt };
  } catch {
    return null;
  }
}

/** The plain key, or null when none is stored or it cannot be opened (secret rotated). */
export async function loadAiKey(env: Env): Promise<string | null> {
  const raw = await env.TOKENS.get(AI_KEY_KV);
  if (!raw || !canStoreAiKey(env)) return null;
  try {
    const s = JSON.parse(raw) as Sealed;
    const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(s.iv) }, await cryptoKey(env), unb64(s.ct));
    return new TextDecoder().decode(pt);
  } catch {
    return null;
  }
}

export async function deleteAiKey(env: Env): Promise<void> {
  await env.TOKENS.delete(AI_KEY_KV);
}
