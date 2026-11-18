import { Hono } from "hono";
import type { Env } from "../env.ts";
import { redirectUri } from "../env.ts";
import { whoopStart } from "./whoop.ts";
import { OAUTH_SCOPES, OURA_AUTHORIZE, OURA_TOKEN } from "../sources/oura/endpoints.ts";
import {
  GOOGLE_AUTHORIZE,
  GOOGLE_SCOPES,
  GOOGLE_STATE_PREFIX,
  GOOGLE_TOKEN,
} from "../sources/calendar/endpoints.ts";
import { codeChallengeS256, newCodeVerifier, newState } from "../lib/pkce.ts";
import { putGoogleTokens, putOuraTokens } from "../lib/tokens.ts";

export const auth = new Hono<{ Bindings: Env }>();

const STATE_TTL = 600;
const OURA_CALLBACK_PATH = "/auth/oura/callback";
const GOOGLE_CALLBACK_PATH = "/auth/google/callback";

/**
 * What /start remembers for /callback: the PKCE verifier and the exact
 * redirect_uri it sent. The token exchange must repeat that redirect_uri, and
 * it depends on which host the sign-in started on (workers.dev, the old custom
 * host, the new one), so it is stored rather than recomputed.
 */
type PendingAuth = { verifier: string; redirect: string };

function savePending(c: { env: Env }, key: string, pending: PendingAuth): Promise<void> {
  return c.env.TOKENS.put(key, JSON.stringify(pending), { expirationTtl: STATE_TTL });
}

/** Reads and deletes a pending sign-in. Older entries held only the verifier. */
async function takePending(c: { env: Env }, key: string, fallbackRedirect: string): Promise<PendingAuth | null> {
  const raw = await c.env.TOKENS.get(key);
  if (!raw) return null;
  await c.env.TOKENS.delete(key);
  if (raw.startsWith("{")) {
    try {
      const parsed = JSON.parse(raw) as Partial<PendingAuth>;
      if (typeof parsed.verifier === "string" && typeof parsed.redirect === "string") {
        return { verifier: parsed.verifier, redirect: parsed.redirect };
      }
    } catch {
      /* fall through: treat as a bare verifier */
    }
  }
  return { verifier: raw, redirect: fallbackRedirect };
}

// The WHOOP callback lives at /api/whoop/callback (see routes/api.ts).
auth.get("/whoop/start", whoopStart);

auth.get("/oura/start", async (c) => {
  if (!c.env.OURA_CLIENT_ID) return c.text("OURA_CLIENT_ID missing", 500);
  const state = newState();
  const verifier = newCodeVerifier();
  const challenge = await codeChallengeS256(verifier);
  const redirect = redirectUri(c.env.OURA_REDIRECT_URI, c.req.url, OURA_CALLBACK_PATH);
  await savePending(c, `oauth:state:${state}`, { verifier, redirect });
  const url = new URL(OURA_AUTHORIZE);
  url.searchParams.set("client_id", c.env.OURA_CLIENT_ID);
  url.searchParams.set("redirect_uri", redirect);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", OAUTH_SCOPES.join(" "));
  url.searchParams.set("state", state);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  return c.redirect(url.toString());
});

auth.get("/oura/callback", async (c) => {
  const err = c.req.query("error");
  if (err) return c.text(`oura oauth error: ${err}`, 400);
  const code = c.req.query("code");
  const state = c.req.query("state");
  if (!code || !state) return c.text("missing code or state", 400);
  const pending = await takePending(
    c,
    `oauth:state:${state}`,
    redirectUri(c.env.OURA_REDIRECT_URI, c.req.url, OURA_CALLBACK_PATH),
  );
  if (!pending) return c.text("unknown or expired state", 400);

  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: pending.redirect,
    client_id: c.env.OURA_CLIENT_ID,
    client_secret: c.env.OURA_CLIENT_SECRET,
    code_verifier: pending.verifier,
  });
  const res = await fetch(OURA_TOKEN, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!res.ok) return c.text(`token exchange failed ${res.status}: ${await res.text()}`, 502);
  const json = (await res.json()) as {
    access_token: string;
    refresh_token?: string;
    expires_in?: number;
    scope?: string;
  };
  await putOuraTokens(c.env, {
    access_token: json.access_token,
    refresh_token: json.refresh_token,
    expires_at: new Date(Date.now() + (json.expires_in ?? 30 * 24 * 3600) * 1000).toISOString(),
    scope: json.scope,
  });
  return c.html(
    `<!doctype html><meta charset="utf-8"><title>Oura connected</title>
     <body style="font-family:system-ui;background:#0c1014;color:#e8ece8;padding:2rem">
     <h1>Oura token stored</h1>
     <p>KV key <code>oura:tokens</code> written. You can close this tab.</p>
     <p><a style="color:#9fd3c7" href="/setup">Back to setup</a></p></body>`,
  );
});

auth.get("/google/start", async (c) => {
  if (!c.env.GOOGLE_CLIENT_ID) return c.text("GOOGLE_CLIENT_ID missing", 500);
  const redirect = redirectUri(c.env.GOOGLE_REDIRECT_URI, c.req.url, GOOGLE_CALLBACK_PATH);
  const state = newState();
  const verifier = newCodeVerifier();
  const challenge = await codeChallengeS256(verifier);
  await savePending(c, `${GOOGLE_STATE_PREFIX}${state}`, { verifier, redirect });
  const url = new URL(GOOGLE_AUTHORIZE);
  url.searchParams.set("client_id", c.env.GOOGLE_CLIENT_ID);
  url.searchParams.set("redirect_uri", redirect);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", GOOGLE_SCOPES.join(" "));
  url.searchParams.set("state", state);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("access_type", "offline");
  url.searchParams.set("prompt", "consent");
  return c.redirect(url.toString());
});

auth.get("/google/callback", async (c) => {
  const err = c.req.query("error");
  if (err) return c.text(`google oauth error: ${err}`, 400);
  const code = c.req.query("code");
  const state = c.req.query("state");
  if (!code || !state) return c.text("missing code or state", 400);
  const pending = await takePending(
    c,
    `${GOOGLE_STATE_PREFIX}${state}`,
    redirectUri(c.env.GOOGLE_REDIRECT_URI, c.req.url, GOOGLE_CALLBACK_PATH),
  );
  if (!pending) return c.text("unknown or expired state", 400);
  if (!c.env.GOOGLE_CLIENT_ID || !c.env.GOOGLE_CLIENT_SECRET) {
    return c.text("Google OAuth env incomplete", 500);
  }

  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: pending.redirect,
    client_id: c.env.GOOGLE_CLIENT_ID,
    client_secret: c.env.GOOGLE_CLIENT_SECRET,
    code_verifier: pending.verifier,
  });
  const res = await fetch(GOOGLE_TOKEN, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!res.ok) return c.text(`token exchange failed ${res.status}: ${await res.text()}`, 502);
  const json = (await res.json()) as {
    access_token: string;
    refresh_token?: string;
    expires_in?: number;
    scope?: string;
  };
  await putGoogleTokens(c.env, {
    access_token: json.access_token,
    refresh_token: json.refresh_token,
    expires_at: new Date(Date.now() + (json.expires_in ?? 3600) * 1000).toISOString(),
    scope: json.scope,
  });
  return c.html(
    `<!doctype html><meta charset="utf-8"><title>Google Calendar connected</title>
     <body style="font-family:system-ui;background:#0c1014;color:#e8ece8;padding:2rem">
     <h1>Google token stored</h1>
     <p>KV key <code>google:tokens</code> written (calendar.readonly). You can close this tab.</p>
     <p><a style="color:#9fd3c7" href="/setup">Back to setup</a></p></body>`,
  );
});
