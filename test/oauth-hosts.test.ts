import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import { auth } from "../src/routes/auth.ts";
import { api } from "../src/routes/api.ts";

// During a hostname move the same Worker answers on two addresses. Every
// OAuth flow must send, and later repeat, the callback on the host the
// sign-in started on. Hosts below are made up.
const OLD = "https://old-host.example";
const NEW = "https://new-host.example";

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
  const env = {
    TOKENS: kv,
    WHOOP_CLIENT_ID: "test-whoop-id",
    WHOOP_CLIENT_SECRET: "test-whoop-secret",
    OURA_CLIENT_ID: "test-oura-id",
    OURA_CLIENT_SECRET: "test-oura-secret",
    GOOGLE_CLIENT_ID: "test-google-id",
    GOOGLE_CLIENT_SECRET: "test-google-secret",
    ...extra,
  };
  return { kv, env: env as never };
}

const realFetch = globalThis.fetch;
let sent: URLSearchParams[] = [];
function mockTokenEndpoint() {
  sent = [];
  globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    sent.push(new URLSearchParams(String(init?.body ?? "")));
    return new Response(JSON.stringify({ access_token: "a", refresh_token: "r", expires_in: 3600 }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch;
}
afterEach(() => {
  globalThis.fetch = realFetch;
});

const providers = [
  { name: "WHOOP", start: "/whoop/start", callback: "/api/whoop/callback", app: api, cbPath: "/whoop/callback" },
  { name: "Oura", start: "/oura/start", callback: "/auth/oura/callback", app: auth, cbPath: "/oura/callback" },
  { name: "Google", start: "/google/start", callback: "/auth/google/callback", app: auth, cbPath: "/google/callback" },
] as const;

describe("OAuth on two hostnames at once", () => {
  for (const p of providers) {
    for (const host of [OLD, NEW]) {
      it(`${p.name}: a sign-in started on ${host} comes back to and exchanges on ${host}`, async () => {
        const { env } = makeEnv();
        const start = await auth.request(`${host}${p.start}`, {}, env);
        assert.equal(start.status, 302);
        const to = new URL(start.headers.get("location") ?? "");
        assert.equal(to.searchParams.get("redirect_uri"), `${host}${p.callback}`);
        const state = to.searchParams.get("state") ?? "";

        mockTokenEndpoint();
        const cb = await p.app.request(`${host}${p.cbPath}?code=c1&state=${encodeURIComponent(state)}`, {}, env);
        assert.equal(cb.status, 200);
        assert.equal(sent.length, 1);
        assert.equal(sent[0].get("redirect_uri"), `${host}${p.callback}`);
      });
    }
  }

  it("an explicit *_REDIRECT_URI still wins over the request host", async () => {
    const { env } = makeEnv({ OURA_REDIRECT_URI: `${NEW}/auth/oura/callback` });
    const start = await auth.request(`${OLD}/oura/start`, {}, env);
    const to = new URL(start.headers.get("location") ?? "");
    assert.equal(to.searchParams.get("redirect_uri"), `${NEW}/auth/oura/callback`);
  });

  it("repeats the redirect it sent even if the callback lands on another host", async () => {
    const { env } = makeEnv();
    const start = await auth.request(`${NEW}/google/start`, {}, env);
    const state = new URL(start.headers.get("location") ?? "").searchParams.get("state") ?? "";
    mockTokenEndpoint();
    const cb = await auth.request(`${OLD}/google/callback?code=c1&state=${encodeURIComponent(state)}`, {}, env);
    assert.equal(cb.status, 200);
    assert.equal(sent[0].get("redirect_uri"), `${NEW}/auth/google/callback`);
    assert.ok(sent[0].get("code_verifier"));
  });

  it("accepts a pending Oura sign-in stored by the previous release (bare verifier)", async () => {
    const { env, kv } = makeEnv();
    kv.store.set("oauth:state:legacy", "legacy-verifier");
    mockTokenEndpoint();
    const cb = await auth.request(`${NEW}/oura/callback?code=c1&state=legacy`, {}, env);
    assert.equal(cb.status, 200);
    assert.equal(sent[0].get("code_verifier"), "legacy-verifier");
    assert.equal(sent[0].get("redirect_uri"), `${NEW}/auth/oura/callback`);
    assert.equal(kv.store.has("oauth:state:legacy"), false);
  });

  it("rejects an unknown state", async () => {
    const { env } = makeEnv();
    const cb = await auth.request(`${NEW}/oura/callback?code=c1&state=nope`, {}, env);
    assert.equal(cb.status, 400);
  });
});
