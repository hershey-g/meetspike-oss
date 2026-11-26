import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { api } from "../src/routes/api.ts";
import { fakeKv, sqliteD1 } from "./sqlite-d1.ts";

const SECRET = "admin-secret-xyz";
const URL_ = "https://app.example/whoop-web/app/ios";

describe("iPhone latest build", () => {
  it("needs the admin secret, starts empty, and stores a posted build", async () => {
    const { db } = sqliteD1();
    const env = { DB: db, TOKENS: fakeKv(), INGEST_ADMIN_SECRET: SECRET };
    const auth = { authorization: `Bearer ${SECRET}` };
    assert.equal((await api.request(URL_, {}, env as never)).status, 401);
    assert.equal((await api.request(URL_, { method: "POST", body: JSON.stringify({ build: 3 }) }, env as never)).status, 401);
    const empty = await api.request(URL_, { headers: auth }, env as never);
    assert.deepEqual(await empty.json(), { ok: true, build: null });
    const post = (body: unknown) => api.request(URL_, {
      method: "POST", body: JSON.stringify(body), headers: { ...auth, "content-type": "application/json" },
    }, env as never);
    for (const bad of [{}, { build: 0 }, { build: -1 }, { build: 2.5 }, { build: "3" }]) {
      assert.equal((await post(bad)).status, 400, JSON.stringify(bad));
    }
    assert.deepEqual(await (await post({ build: 3 })).json(), { ok: true, build: 3 });
    const got = await api.request(URL_, { headers: auth }, env as never);
    assert.equal(got.headers.get("cache-control"), "private, no-store");
    assert.deepEqual(await got.json(), { ok: true, build: 3 });
  });

  const auth = { authorization: `Bearer ${SECRET}`, "content-type": "application/json" };
  const setup = (initial: Record<string, string> = {}, secret: string | null = SECRET) => {
    const { db } = sqliteD1();
    const tokens = fakeKv(initial);
    const env = { DB: db, TOKENS: tokens, INGEST_ADMIN_SECRET: secret ?? undefined };
    const post = (body: string, headers: Record<string, string> = auth) =>
      api.request(URL_, { method: "POST", body, headers }, env as never);
    const get = (headers: Record<string, string> = auth) => api.request(URL_, { headers }, env as never);
    return { tokens, post, get };
  };

  it("returns 503 on both routes when INGEST_ADMIN_SECRET is unset", async () => {
    const { post, get, tokens } = setup({}, null);
    assert.equal((await get()).status, 503);
    assert.equal((await post(JSON.stringify({ build: 3 }))).status, 503);
    assert.equal(tokens.store.size, 0);
  });

  it("rejects a wrong non-empty secret with 401", async () => {
    const { post, get, tokens } = setup();
    const wrong = { authorization: "Bearer not-the-secret", "content-type": "application/json" };
    assert.equal((await get(wrong)).status, 401);
    assert.equal((await post(JSON.stringify({ build: 3 }), wrong)).status, 401);
    assert.equal(tokens.store.size, 0);
  });

  it("rejects invalid JSON with 400 and an oversized body with 413", async () => {
    const { post, tokens } = setup();
    assert.equal((await post("{not json")).status, 400);
    assert.equal((await post(JSON.stringify({ build: 3, pad: "x".repeat(400) }))).status, 413);
    assert.equal(tokens.store.size, 0);
  });

  it("reads a corrupt KV value as null", async () => {
    for (const bad of ["abc", "0", "-4", "2.5", ""]) {
      const { get } = setup({ "app:ios-latest-build": bad });
      assert.deepEqual(await (await get()).json(), { ok: true, build: null }, bad);
    }
  });

  it("ignores a lower or equal build and replies with the stored one", async () => {
    const { post, get } = setup();
    assert.deepEqual(await (await post(JSON.stringify({ build: 5 }))).json(), { ok: true, build: 5 });
    assert.deepEqual(await (await post(JSON.stringify({ build: 3 }))).json(), { ok: true, build: 5 });
    assert.deepEqual(await (await post(JSON.stringify({ build: 5 }))).json(), { ok: true, build: 5 });
    assert.deepEqual(await (await get()).json(), { ok: true, build: 5 });
    assert.deepEqual(await (await post(JSON.stringify({ build: 6 }))).json(), { ok: true, build: 6 });
  });

  it("stores over a corrupt KV value", async () => {
    const { post } = setup({ "app:ios-latest-build": "garbage" });
    assert.deepEqual(await (await post(JSON.stringify({ build: 2 }))).json(), { ok: true, build: 2 });
  });

  it("lowers the build only with force: true", async () => {
    const { post, get } = setup({ "app:ios-latest-build": "5" });
    assert.deepEqual(await (await post(JSON.stringify({ build: 3, force: "yes" }))).json(), { ok: true, build: 5 });
    assert.deepEqual(await (await post(JSON.stringify({ build: 3, force: true }))).json(), { ok: true, build: 3 });
    assert.deepEqual(await (await get()).json(), { ok: true, build: 3 });
  });
});
