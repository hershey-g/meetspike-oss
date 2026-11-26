/**
 * Verifies the `Cf-Access-Jwt-Assertion` header that Cloudflare Access adds
 * to every request it lets through.
 *
 * A bare header check is not enough: a request that reaches the Worker some
 * other way (a preview URL, workers.dev, a route without an Access app) can
 * send any header it likes. So the token is checked properly: RS256 signature
 * against the team's published keys, issuer, audience (the Access
 * application's AUD tag), expiry and not-before.
 *
 * Config, both required (fail closed without them):
 *   ACCESS_TEAM_DOMAIN  e.g. https://myteam.cloudflareaccess.com
 *   ACCESS_AUD          the Access application's Application Audience (AUD) tag;
 *                       comma-separated if more than one app covers /api/*
 */

export const ACCESS_JWT_HEADER = "cf-access-jwt-assertion";

/** Seconds of clock skew allowed on exp and nbf. */
const LEEWAY_S = 30;
/** Keys are refetched after this long, and at most this often on an unknown kid. */
const KEYS_TTL_MS = 60 * 60 * 1000;
const KEYS_MIN_REFETCH_MS = 30 * 1000;
/** A real Access token is about 1 KB. Anything far bigger is not one. */
const MAX_TOKEN_LEN = 8192;

export type AccessConfig = { issuer: string; certsUrl: string; aud: string[] };

export type AccessClaims = {
  iss: string;
  aud: string | string[];
  exp: number;
  nbf?: number;
  iat?: number;
  sub?: string;
  email?: string;
  common_name?: string;
  type?: string;
};

export type AccessCheck =
  | { ok: true; claims: AccessClaims }
  | { ok: false; reason: "missing" | "malformed" | "unknown_key" | "bad_signature" | "bad_claims" | "not_user" | "keys_unavailable" };

type Fetcher = (input: string, init?: RequestInit) => Promise<Response>;

/**
 * Reads ACCESS_TEAM_DOMAIN and ACCESS_AUD. Null unless both are set and the
 * team domain is a `<team>.cloudflareaccess.com` host, so a typo can never
 * point the Worker at somebody else's keys.
 */
export function accessConfig(env: { ACCESS_TEAM_DOMAIN?: string; ACCESS_AUD?: string }): AccessConfig | null {
  const rawTeam = env.ACCESS_TEAM_DOMAIN?.trim() ?? "";
  const aud = (env.ACCESS_AUD ?? "").split(",").map((a) => a.trim()).filter(Boolean);
  if (!rawTeam || aud.length === 0) return null;
  let host: string;
  try {
    const url = new URL(/^https?:\/\//i.test(rawTeam) ? rawTeam : `https://${rawTeam}`);
    if (url.protocol !== "https:" || url.username || url.password || url.port) return null;
    if (url.pathname !== "/" && url.pathname !== "") return null;
    if (url.search || url.hash) return null;
    host = url.hostname.toLowerCase();
  } catch {
    return null;
  }
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.cloudflareaccess\.com$/.test(host)) return null;
  const issuer = `https://${host}`;
  return { issuer, certsUrl: `${issuer}/cdn-cgi/access/certs`, aud };
}

function b64urlBytes(part: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(part)) return null;
  const b64 = part.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (part.length % 4)) % 4);
  try {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i += 1) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

function b64urlJson(part: string): Record<string, unknown> | null {
  const bytes = b64urlBytes(part);
  if (!bytes) return null;
  try {
    const value = JSON.parse(new TextDecoder().decode(bytes)) as unknown;
    return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

type KeySet = { keys: Map<string, CryptoKey>; fetchedAt: number };
const keyCache = new Map<string, KeySet>();

/** Tests only: forget cached keys. */
export function clearAccessKeyCache(): void {
  keyCache.clear();
}

async function fetchKeys(certsUrl: string, fetcher: Fetcher, now: number): Promise<KeySet | null> {
  let res: Response;
  try {
    res = await fetcher(certsUrl, { headers: { Accept: "application/json" } });
  } catch {
    return null;
  }
  if (!res.ok) return null;
  const body = (await res.json().catch(() => null)) as { keys?: unknown } | null;
  if (!body || !Array.isArray(body.keys)) return null;
  const keys = new Map<string, CryptoKey>();
  for (const jwk of body.keys as Array<Record<string, unknown>>) {
    if (!jwk || jwk.kty !== "RSA" || typeof jwk.kid !== "string" || typeof jwk.n !== "string" || typeof jwk.e !== "string") continue;
    if (jwk.alg !== undefined && jwk.alg !== "RS256") continue;
    if (jwk.use !== undefined && jwk.use !== "sig") continue;
    try {
      const key = await crypto.subtle.importKey(
        "jwk",
        { kty: "RSA", n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
        { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
        false,
        ["verify"],
      );
      keys.set(jwk.kid, key);
    } catch {
      /* skip a key we cannot read */
    }
  }
  if (keys.size === 0) return null;
  const set = { keys, fetchedAt: now };
  keyCache.set(certsUrl, set);
  return set;
}

async function keyFor(kid: string, config: AccessConfig, fetcher: Fetcher, now: number): Promise<CryptoKey | null | "unavailable"> {
  let set = keyCache.get(config.certsUrl);
  if (!set || now - set.fetchedAt > KEYS_TTL_MS) {
    set = (await fetchKeys(config.certsUrl, fetcher, now)) ?? set;
    if (!set) return "unavailable";
  }
  const hit = set.keys.get(kid);
  if (hit) return hit;
  // Access rotates its signing key; refetch once in a while for a new kid.
  if (now - set.fetchedAt < KEYS_MIN_REFETCH_MS) return null;
  const fresh = await fetchKeys(config.certsUrl, fetcher, now);
  return fresh?.keys.get(kid) ?? null;
}

/**
 * Verifies one Access token. `requireUser` rejects service-token logins
 * (they carry `common_name` and no email), so only a person who signed in
 * can pass.
 */
export async function verifyAccessJwt(
  token: string | null | undefined,
  config: AccessConfig,
  opts: { now?: number; fetcher?: Fetcher; requireUser?: boolean } = {},
): Promise<AccessCheck> {
  const now = opts.now ?? Date.now();
  const fetcher: Fetcher = opts.fetcher ?? ((input, init) => fetch(input, init));
  const raw = token?.trim() ?? "";
  if (!raw) return { ok: false, reason: "missing" };
  if (raw.length > MAX_TOKEN_LEN) return { ok: false, reason: "malformed" };
  const parts = raw.split(".");
  if (parts.length !== 3) return { ok: false, reason: "malformed" };
  const [h, p, s] = parts;
  const header = b64urlJson(h);
  const payload = b64urlJson(p);
  const signature = b64urlBytes(s);
  if (!header || !payload || !signature || signature.length === 0) return { ok: false, reason: "malformed" };
  if (header.alg !== "RS256" || typeof header.kid !== "string" || !header.kid) return { ok: false, reason: "malformed" };

  const key = await keyFor(header.kid, config, fetcher, now);
  if (key === "unavailable") return { ok: false, reason: "keys_unavailable" };
  if (!key) return { ok: false, reason: "unknown_key" };
  let valid = false;
  try {
    valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, new TextEncoder().encode(`${h}.${p}`));
  } catch {
    valid = false;
  }
  if (!valid) return { ok: false, reason: "bad_signature" };

  const nowS = Math.floor(now / 1000);
  const aud = payload.aud;
  const audOk = typeof aud === "string"
    ? config.aud.includes(aud)
    : Array.isArray(aud) && aud.some((a) => typeof a === "string" && config.aud.includes(a));
  if (payload.iss !== config.issuer || !audOk) return { ok: false, reason: "bad_claims" };
  if (typeof payload.exp !== "number" || !Number.isFinite(payload.exp) || nowS > payload.exp + LEEWAY_S) {
    return { ok: false, reason: "bad_claims" };
  }
  if (payload.nbf !== undefined && (typeof payload.nbf !== "number" || nowS + LEEWAY_S < payload.nbf)) {
    return { ok: false, reason: "bad_claims" };
  }
  const claims = payload as unknown as AccessClaims;
  if (opts.requireUser) {
    const email = typeof claims.email === "string" ? claims.email.trim() : "";
    if (!email || claims.common_name !== undefined) return { ok: false, reason: "not_user" };
  }
  return { ok: true, claims };
}

function isLocalDev(url: string): boolean {
  const u = new URL(url);
  return u.protocol === "http:" && (u.hostname === "localhost" || u.hostname === "127.0.0.1");
}

export type AccessGate =
  | { ok: true }
  | { ok: false; status: 403 | 503; error: string; reason: string };

/**
 * The gate for routes that must only run for a signed-in person behind
 * Access. Plain-http localhost (wrangler dev) is let through; everything
 * else needs ACCESS_TEAM_DOMAIN and ACCESS_AUD set and a valid user token.
 */
export async function requireAccessUser(
  headers: { get(name: string): string | null },
  url: string,
  env: { ACCESS_TEAM_DOMAIN?: string; ACCESS_AUD?: string },
  opts: { now?: number; fetcher?: Fetcher } = {},
): Promise<AccessGate> {
  if (isLocalDev(url)) return { ok: true };
  const config = accessConfig(env);
  if (!config) {
    return {
      ok: false,
      status: 503,
      reason: "not_configured",
      error: "Set ACCESS_TEAM_DOMAIN and ACCESS_AUD on the Worker first (setup step 8).",
    };
  }
  const check = await verifyAccessJwt(headers.get(ACCESS_JWT_HEADER), config, { ...opts, requireUser: true });
  if (check.ok) return { ok: true };
  if (check.reason === "keys_unavailable") {
    return { ok: false, status: 503, reason: check.reason, error: "Could not check your Cloudflare Access sign-in. Try again in a minute." };
  }
  return { ok: false, status: 403, reason: check.reason, error: "Sign in through Cloudflare Access to make a setup code." };
}
