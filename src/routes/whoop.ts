import type { Context } from "hono";
import type { Env } from "../env.ts";
import { redirectUri } from "../env.ts";
import { putWhoopTokens } from "../lib/tokens.ts";
import {
  WHOOP_AUTHORIZE,
  WHOOP_CALLBACK_PATH,
  WHOOP_SCOPES,
  WHOOP_STATE_PREFIX,
  WHOOP_TOKEN,
} from "../sources/whoop/endpoints.ts";

type Ctx = Context<{ Bindings: Env }>;

const STATE_TTL = 600;

/** WHOOP asks for an eight-character `state`. Six random bytes are exactly eight base64url characters. */
export function newWhoopState(): string {
  const buf = new Uint8Array(6);
  crypto.getRandomValues(buf);
  return btoa(String.fromCharCode(...buf)).replace(/\+/g, "-").replace(/\//g, "_");
}

function page(title: string, body: string): string {
  return `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${title}</title>
     <body style="font-family:system-ui;background:#0c1014;color:#e8ece8;padding:2rem;line-height:1.5">
     <h1>${title}</h1>${body}
     <p><a style="color:#9fd3c7" href="/setup">Back to setup</a></p></body>`;
}

/** GET /auth/whoop/start — send the browser to WHOOP to approve access. */
export async function whoopStart(c: Ctx): Promise<Response> {
  if (!c.env.WHOOP_CLIENT_ID) return c.text("WHOOP_CLIENT_ID missing — add it as a Worker secret, then try again.", 500);
  const state = newWhoopState();
  const redirect = redirectUri(c.env.WHOOP_REDIRECT_URI, c.req.url, WHOOP_CALLBACK_PATH);
  // Remember the exact redirect we sent: the token exchange must repeat it.
  await c.env.TOKENS.put(`${WHOOP_STATE_PREFIX}${state}`, redirect, { expirationTtl: STATE_TTL });
  const url = new URL(WHOOP_AUTHORIZE);
  url.searchParams.set("client_id", c.env.WHOOP_CLIENT_ID);
  url.searchParams.set("redirect_uri", redirect);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", WHOOP_SCOPES.join(" "));
  url.searchParams.set("state", state);
  return c.redirect(url.toString());
}

/** GET /api/whoop/callback — trade the code for tokens and store them in KV. */
export async function whoopCallback(c: Ctx): Promise<Response> {
  const err = c.req.query("error");
  if (err) return c.text(`whoop oauth error: ${err}`, 400);
  const code = c.req.query("code");
  const state = c.req.query("state");
  if (!code || !state) return c.text("missing code or state", 400);
  const key = `${WHOOP_STATE_PREFIX}${state}`;
  const redirect = await c.env.TOKENS.get(key);
  if (!redirect) return c.text("unknown or expired state", 400);
  await c.env.TOKENS.delete(key);
  if (!c.env.WHOOP_CLIENT_ID || !c.env.WHOOP_CLIENT_SECRET) {
    return c.text("WHOOP_CLIENT_ID / WHOOP_CLIENT_SECRET missing", 500);
  }

  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: redirect,
    client_id: c.env.WHOOP_CLIENT_ID,
    client_secret: c.env.WHOOP_CLIENT_SECRET,
  });
  const res = await fetch(WHOOP_TOKEN, {
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
  await putWhoopTokens(c.env, {
    access_token: json.access_token,
    refresh_token: json.refresh_token,
    expires_at: new Date(Date.now() + (json.expires_in ?? 3600) * 1000).toISOString(),
    scope: json.scope,
  });
  const note = json.refresh_token
    ? "<p>WHOOP is connected. Meetspike can now read your recovery, strain, sleep and workouts.</p>"
    : "<p>WHOOP is connected, but it did not send a long-lived key, so this will stop working in about an hour. Check that the <code>offline</code> scope is ticked on your WHOOP app, then connect again.</p>";
  return c.html(page("WHOOP connected", note));
}
