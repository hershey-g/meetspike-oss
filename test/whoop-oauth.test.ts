import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";
import { auth } from "../src/routes/auth.ts";
import { api } from "../src/routes/api.ts";
import { getValidWhoopAccessToken, getWhoopTokens, putWhoopTokens } from "../src/lib/tokens.ts";
import { WhoopRateLimitError, listWhoopCollection, resetWhoopRateState, whoopFetch } from "../src/sources/whoop/client.ts";
import { WHOOP_API, WHOOP_SCOPES, WHOOP_TOKEN } from "../src/sources/whoop/endpoints.ts";

/** In-memory stand-in for the TOKENS KV namespace. */
function fakeKv() {
  const store = new Map<string, string>();
  return {
    store,
    get: async (k: string) => store.get(k) ?? null,
    put: async (k: string, v: string) => void store.set(k, v),
    delete: async (k: string) => void store.delete(k),
  };
}

function makeEnv(extra: Record<string, unknown> = {}) {
  const kv = fakeKv();
  // Made-up values. Nothing here is a real credential.
  const env = { TOKENS: kv, WHOOP_CLIENT_ID: "test-client-id", WHOOP_CLIENT_SECRET: "test-client-secret", ...extra };
  return { kv, env: env as never };
}

type Call = { url: string; init?: RequestInit };
const realFetch = globalThis.fetch;
let calls: Call[] = [];

/** Route every outgoing request through `handler`; nothing reaches the network. */
function mockFetch(handler: (call: Call) => Response) {
  calls = [];
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const call = { url: String(input), init };
    calls.push(call);
    return handler(call);
  }) as typeof fetch;
}

function json(body: unknown, status = 200, headers: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
}

function form(call: Call): URLSearchParams {
  return new URLSearchParams(String(call.init?.body ?? ""));
}

const future = () => new Date(Date.now() + 3_600_000).toISOString();
const past = () => new Date(Date.now() - 60_000).toISOString();

beforeEach(() => resetWhoopRateState());
afterEach(() => {
  globalThis.fetch = realFetch;
});

describe("WHOOP OAuth — start", () => {
  it("redirects to WHOOP with every scope, an 8-character state and this Worker's callback", async () => {
    const { env, kv } = makeEnv();
    const res = await auth.request("https://app.example/whoop/start", {}, env);
    assert.equal(res.status, 302);
    const to = new URL(res.headers.get("location") ?? "");
    assert.equal(`${to.origin}${to.pathname}`, "https://api.prod.whoop.com/oauth/oauth2/auth");
    assert.equal(to.searchParams.get("client_id"), "test-client-id");
    assert.equal(to.searchParams.get("response_type"), "code");
    assert.equal(to.searchParams.get("redirect_uri"), "https://app.example/api/whoop/callback");
    assert.equal(
      to.searchParams.get("scope"),
      "read:recovery read:cycles read:sleep read:workout read:profile read:body_measurement offline",
    );
    assert.deepEqual(to.searchParams.get("scope")?.split(" "), [...WHOOP_SCOPES]);
    const state = to.searchParams.get("state") ?? "";
    assert.equal(state.length, 8);
    assert.equal(kv.store.get(`oauth:whoop:state:${state}`), "https://app.example/api/whoop/callback");
  });

  it("uses WHOOP_REDIRECT_URI when it is set, and says so plainly when the client id is missing", async () => {
    const { env } = makeEnv({ WHOOP_REDIRECT_URI: "https://custom.example/api/whoop/callback" });
    const res = await auth.request("https://app.example/whoop/start", {}, env);
    assert.equal(
      new URL(res.headers.get("location") ?? "").searchParams.get("redirect_uri"),
      "https://custom.example/api/whoop/callback",
    );
    const none = await auth.request("https://app.example/whoop/start", {}, makeEnv({ WHOOP_CLIENT_ID: "" }).env);
    assert.equal(none.status, 500);
    assert.match(await none.text(), /WHOOP_CLIENT_ID missing/);
  });
});

describe("WHOOP OAuth — callback at /api/whoop/callback", () => {
  it("trades the code for tokens and stores them under whoop:tokens", async () => {
    const { env, kv } = makeEnv();
    kv.store.set("oauth:whoop:state:abcd1234", "https://app.example/api/whoop/callback");
    mockFetch(() => json({ access_token: "access-1", refresh_token: "refresh-1", expires_in: 3600, scope: "offline read:recovery" }));

    const res = await api.request("https://app.example/whoop/callback?code=the-code&state=abcd1234", {}, env);
    assert.equal(res.status, 200);
    assert.match(await res.text(), /WHOOP is connected/);

    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, WHOOP_TOKEN);
    const sent = form(calls[0]);
    assert.equal(sent.get("grant_type"), "authorization_code");
    assert.equal(sent.get("code"), "the-code");
    assert.equal(sent.get("redirect_uri"), "https://app.example/api/whoop/callback");
    assert.equal(sent.get("client_id"), "test-client-id");
    assert.equal(sent.get("client_secret"), "test-client-secret");

    const stored = await getWhoopTokens(env);
    assert.equal(stored?.access_token, "access-1");
    assert.equal(stored?.refresh_token, "refresh-1");
    assert.ok(Date.parse(stored?.expires_at ?? "") > Date.now() + 3_000_000);
    assert.equal(kv.store.has("oauth:whoop:state:abcd1234"), false, "state is single-use");
  });

  it("rejects an unknown state, a missing code and a provider error without calling WHOOP", async () => {
    const { env } = makeEnv();
    mockFetch(() => json({}));
    const unknown = await api.request("https://app.example/whoop/callback?code=x&state=nope1234", {}, env);
    assert.equal(unknown.status, 400);
    const missing = await api.request("https://app.example/whoop/callback?state=nope1234", {}, env);
    assert.equal(missing.status, 400);
    const denied = await api.request("https://app.example/whoop/callback?error=access_denied", {}, env);
    assert.equal(denied.status, 400);
    assert.equal(calls.length, 0);
  });

  it("reports a failed exchange and stores nothing", async () => {
    const { env, kv } = makeEnv();
    kv.store.set("oauth:whoop:state:abcd1234", "https://app.example/api/whoop/callback");
    mockFetch(() => new Response("invalid_grant", { status: 400 }));
    const res = await api.request("https://app.example/whoop/callback?code=bad&state=abcd1234", {}, env);
    assert.equal(res.status, 502);
    assert.equal(await getWhoopTokens(env), null);
  });
});

describe("WHOOP tokens — refresh", () => {
  it("returns a live token without calling WHOOP", async () => {
    const { env } = makeEnv();
    await putWhoopTokens(env, { access_token: "live", refresh_token: "r", expires_at: future() });
    mockFetch(() => json({}));
    assert.equal(await getValidWhoopAccessToken(env), "live");
    assert.equal(calls.length, 0);
  });

  it("refreshes an expired token and keeps the rotated refresh token", async () => {
    const { env } = makeEnv();
    await putWhoopTokens(env, { access_token: "old", refresh_token: "refresh-old", expires_at: past(), scope: "offline" });
    mockFetch(() => json({ access_token: "new", refresh_token: "refresh-new", expires_in: 3600 }));

    assert.equal(await getValidWhoopAccessToken(env), "new");
    const sent = form(calls[0]);
    assert.equal(calls[0].url, WHOOP_TOKEN);
    assert.equal(sent.get("grant_type"), "refresh_token");
    assert.equal(sent.get("refresh_token"), "refresh-old");
    assert.equal(sent.get("scope"), "offline");
    assert.equal(sent.get("client_id"), "test-client-id");

    const stored = await getWhoopTokens(env);
    assert.equal(stored?.access_token, "new");
    assert.equal(stored?.refresh_token, "refresh-new", "WHOOP retires the old refresh token");
    assert.equal(stored?.scope, "offline");
  });

  it("fails clearly when there is nothing to refresh with, or WHOOP refuses", async () => {
    const none = makeEnv();
    await assert.rejects(getValidWhoopAccessToken(none.env), /no whoop tokens/);

    const noRefresh = makeEnv();
    await putWhoopTokens(noRefresh.env, { access_token: "old", expires_at: past() });
    await assert.rejects(getValidWhoopAccessToken(noRefresh.env), /no refresh_token/);

    const refused = makeEnv();
    await putWhoopTokens(refused.env, { access_token: "old", refresh_token: "dead", expires_at: past() });
    mockFetch(() => new Response("invalid_grant", { status: 400 }));
    await assert.rejects(getValidWhoopAccessToken(refused.env), /whoop refresh failed 400/);
    assert.equal((await getWhoopTokens(refused.env))?.access_token, "old", "a failed refresh does not clobber the bundle");
  });
});

describe("WHOOP client", () => {
  it("refreshes once on a 401 and retries with the new token", async () => {
    const { env } = makeEnv();
    await putWhoopTokens(env, { access_token: "stale", refresh_token: "r1", expires_at: future() });
    mockFetch((call) => {
      if (call.url === WHOOP_TOKEN) return json({ access_token: "fresh", refresh_token: "r2", expires_in: 3600 });
      const bearer = new Headers(call.init?.headers).get("authorization");
      return bearer === "Bearer fresh" ? json({ records: [] }) : new Response("expired", { status: 401 });
    });
    const res = await whoopFetch(env, "/v2/recovery");
    assert.equal(res.status, 200);
    assert.deepEqual(
      calls.map((c) => c.url.replace(new URL(WHOOP_API).origin, "")),
      ["/developer/v2/recovery", "/oauth/oauth2/token", "/developer/v2/recovery"],
    );
  });

  it("follows next_token across pages with limit 25 and the requested window", async () => {
    const { env } = makeEnv();
    await putWhoopTokens(env, { access_token: "live", refresh_token: "r", expires_at: future() });
    mockFetch((call) => {
      const page = new URL(call.url).searchParams.get("nextToken");
      return page ? json({ records: [{ id: 3 }], next_token: "" }) : json({ records: [{ id: 1 }, { id: 2 }], next_token: "page-2" });
    });
    const tally = { requests: 0 };
    const records = await listWhoopCollection(
      env,
      "cycle",
      { startIso: "2026-11-01T00:00:00.000Z", endIso: "2026-11-08T00:00:00.000Z" },
      { tally },
    );
    assert.deepEqual(records, [{ id: 1 }, { id: 2 }, { id: 3 }]);
    assert.equal(tally.requests, 2);
    const first = new URL(calls[0].url);
    assert.equal(first.pathname, "/developer/v2/cycle");
    assert.equal(first.searchParams.get("limit"), "25");
    assert.equal(first.searchParams.get("start"), "2026-11-01T00:00:00.000Z");
    assert.equal(first.searchParams.get("end"), "2026-11-08T00:00:00.000Z");
    assert.equal(new URL(calls[1].url).searchParams.get("nextToken"), "page-2");
  });

  it("turns a 429 into a rate-limit error that carries WHOOP's reset time", async () => {
    const { env } = makeEnv();
    await putWhoopTokens(env, { access_token: "live", refresh_token: "r", expires_at: future() });
    mockFetch(() => new Response("slow down", { status: 429, headers: { "X-RateLimit-Reset": "42" } }));
    await assert.rejects(whoopFetch(env, "/v2/cycle"), (err: unknown) => {
      assert.ok(err instanceof WhoopRateLimitError);
      assert.equal(err.retryAfterS, 42);
      return true;
    });
    // The block is remembered: the next call is refused locally instead of hitting WHOOP again.
    await assert.rejects(whoopFetch(env, "/v2/cycle"), WhoopRateLimitError);
    assert.equal(calls.length, 1);
  });
});
