import type { Env } from "../env.ts";
import type { TokenBundle } from "../types.ts";
import { OURA_TOKEN } from "../sources/oura/endpoints.ts";
import { GOOGLE_TOKEN, GOOGLE_TOKEN_KEY } from "../sources/calendar/endpoints.ts";
import { WHOOP_TOKEN, WHOOP_TOKEN_KEY } from "../sources/whoop/endpoints.ts";
import { nowIso } from "./time.ts";

const OURA_KEY = "oura:tokens";
const GOOGLE_KEY = GOOGLE_TOKEN_KEY;
const SKEW_MS = 60_000;

export async function getOuraTokens(env: Env): Promise<TokenBundle | null> {
  const raw = await env.TOKENS.get(OURA_KEY);
  if (!raw) return null;
  return JSON.parse(raw) as TokenBundle;
}

export async function putOuraTokens(env: Env, bundle: TokenBundle): Promise<void> {
  await env.TOKENS.put(OURA_KEY, JSON.stringify(bundle));
}

export async function getValidAccessToken(env: Env): Promise<string> {
  const bundle = await getOuraTokens(env);
  if (!bundle) throw new Error("no oura tokens — complete OAuth at /auth/oura/start");
  const expires = Date.parse(bundle.expires_at);
  if (Number.isFinite(expires) && expires - SKEW_MS > Date.now()) {
    return bundle.access_token;
  }
  return refreshOuraToken(env, bundle);
}

export class MembershipLapsedError extends Error {
  constructor() {
    super("Oura membership lapsed (403) — token is valid but data is unavailable");
    this.name = "MembershipLapsedError";
  }
}

export async function refreshOuraToken(env: Env, bundle: TokenBundle): Promise<string> {
  if (!bundle.refresh_token) throw new Error("oura token expired and no refresh_token");
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: bundle.refresh_token,
    client_id: env.OURA_CLIENT_ID,
    client_secret: env.OURA_CLIENT_SECRET,
  });
  const res = await fetch(OURA_TOKEN, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`oura refresh failed ${res.status}: ${text}`);
  }
  const json = (await res.json()) as {
    access_token: string;
    refresh_token?: string;
    expires_in?: number;
    scope?: string;
  };
  const next: TokenBundle = {
    access_token: json.access_token,
    refresh_token: json.refresh_token ?? bundle.refresh_token,
    expires_at: new Date(Date.now() + (json.expires_in ?? 30 * 24 * 3600) * 1000).toISOString(),
    scope: json.scope ?? bundle.scope,
  };
  await putOuraTokens(env, next);
  return next.access_token;
}

export async function getGoogleTokens(env: Env): Promise<TokenBundle | null> {
  const raw = await env.TOKENS.get(GOOGLE_KEY);
  if (!raw) return null;
  return JSON.parse(raw) as TokenBundle;
}

export async function putGoogleTokens(env: Env, bundle: TokenBundle): Promise<void> {
  await env.TOKENS.put(GOOGLE_KEY, JSON.stringify(bundle));
}

export async function getValidGoogleAccessToken(env: Env): Promise<string> {
  const bundle = await getGoogleTokens(env);
  if (!bundle) throw new Error("no google tokens — complete OAuth at /auth/google/start");
  const expires = Date.parse(bundle.expires_at);
  if (Number.isFinite(expires) && expires - SKEW_MS > Date.now()) {
    return bundle.access_token;
  }
  return refreshGoogleToken(env, bundle);
}

export async function refreshGoogleToken(env: Env, bundle: TokenBundle): Promise<string> {
  if (!bundle.refresh_token) throw new Error("google token expired and no refresh_token");
  if (!env.GOOGLE_CLIENT_ID || !env.GOOGLE_CLIENT_SECRET) {
    throw new Error("GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET missing");
  }
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: bundle.refresh_token,
    client_id: env.GOOGLE_CLIENT_ID,
    client_secret: env.GOOGLE_CLIENT_SECRET,
  });
  const res = await fetch(GOOGLE_TOKEN, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`google refresh failed ${res.status}: ${text}`);
  }
  const json = (await res.json()) as {
    access_token: string;
    refresh_token?: string;
    expires_in?: number;
    scope?: string;
  };
  const next: TokenBundle = {
    access_token: json.access_token,
    refresh_token: json.refresh_token ?? bundle.refresh_token,
    expires_at: new Date(Date.now() + (json.expires_in ?? 3600) * 1000).toISOString(),
    scope: json.scope ?? bundle.scope,
  };
  await putGoogleTokens(env, next);
  return next.access_token;
}

export async function getWhoopTokens(env: Env): Promise<TokenBundle | null> {
  const raw = await env.TOKENS.get(WHOOP_TOKEN_KEY);
  if (!raw) return null;
  return JSON.parse(raw) as TokenBundle;
}

export async function putWhoopTokens(env: Env, bundle: TokenBundle): Promise<void> {
  await env.TOKENS.put(WHOOP_TOKEN_KEY, JSON.stringify(bundle));
}

export async function getValidWhoopAccessToken(env: Env): Promise<string> {
  const bundle = await getWhoopTokens(env);
  if (!bundle) throw new Error("no whoop tokens — connect WHOOP at /auth/whoop/start");
  const expires = Date.parse(bundle.expires_at);
  if (Number.isFinite(expires) && expires - SKEW_MS > Date.now()) {
    return bundle.access_token;
  }
  return refreshWhoopToken(env, bundle);
}

/**
 * WHOOP rotates refresh tokens: every refresh returns a new one and retires
 * the old one, so the new bundle is stored before the access token is used.
 */
export async function refreshWhoopToken(env: Env, bundle: TokenBundle): Promise<string> {
  if (!bundle.refresh_token) {
    throw new Error("whoop token expired and no refresh_token — reconnect WHOOP at /auth/whoop/start");
  }
  if (!env.WHOOP_CLIENT_ID || !env.WHOOP_CLIENT_SECRET) {
    throw new Error("WHOOP_CLIENT_ID / WHOOP_CLIENT_SECRET missing");
  }
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: bundle.refresh_token,
    client_id: env.WHOOP_CLIENT_ID,
    client_secret: env.WHOOP_CLIENT_SECRET,
    scope: "offline",
  });
  const res = await fetch(WHOOP_TOKEN, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`whoop refresh failed ${res.status}: ${text}`);
  }
  const json = (await res.json()) as {
    access_token: string;
    refresh_token?: string;
    expires_in?: number;
    scope?: string;
  };
  const next: TokenBundle = {
    access_token: json.access_token,
    refresh_token: json.refresh_token ?? bundle.refresh_token,
    expires_at: new Date(Date.now() + (json.expires_in ?? 3600) * 1000).toISOString(),
    scope: json.scope ?? bundle.scope,
  };
  await putWhoopTokens(env, next);
  return next.access_token;
}

export { nowIso, GOOGLE_KEY };
