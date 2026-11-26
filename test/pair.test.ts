import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { after, before, describe, it } from "node:test";
import { pairExchange, pairStart } from "../src/routes/pair.ts";
import {
  PAIR_CODE_LEN,
  PAIR_TTL_S,
  newPairingCode,
  pairingUrl,
  redeemable,
  splitCode,
  storedPairing,
} from "../src/lib/pairing.ts";
import { fakeKv, sqliteD1 } from "./sqlite-d1.ts";
import { clearAccessKeyCache } from "../src/lib/access-jwt.ts";
import { ACCESS_ENV, makeAccessTeam, useGlobalFetch, type AccessTeam } from "./access-fixture.ts";
// @ts-expect-error: plain browser module, no types.
import { encodeQr, qrSvg } from "../public/qrcode.js";

const SECRET = "ingest-secret-fixture-123";
const ORIGIN = "https://meetspike.example";

/** fakeKv plus the expirationTtl each put asked for. */
function kv(initial: Record<string, string> = {}) {
  const base = fakeKv(initial);
  const ttl = new Map<string, number | undefined>();
  return {
    ...base,
    ttl,
    put: async (k: string, v: string, opts?: { expirationTtl?: number }) => {
      ttl.set(k, opts?.expirationTtl);
      await base.put(k, v);
    },
  };
}

type CodeRow = { id: string; secret_hash: string; expires_at: number };

function makeEnv(extra: Record<string, unknown> = {}) {
  const tokens = kv();
  const { db, raw } = sqliteD1();
  const codes = () => raw.prepare("SELECT id, secret_hash, expires_at FROM pair_codes").all() as unknown as CodeRow[];
  return { env: { TOKENS: tokens, DB: db, INGEST_ADMIN_SECRET: SECRET, ...ACCESS_ENV, ...extra }, tokens, raw, codes };
}

/** A signed-in user's Access token, signed by a local test key (see access-fixture.ts). */
let team: AccessTeam;
let ACCESS: Record<string, string>;
let restoreFetch: () => void;

before(async () => {
  clearAccessKeyCache();
  team = await makeAccessTeam();
  restoreFetch = useGlobalFetch(team);
  ACCESS = { "cf-access-jwt-assertion": await team.userToken() };
});

after(() => {
  restoreFetch();
  clearAccessKeyCache();
});

async function start(env: unknown, headers: Record<string, string> = ACCESS, url = `${ORIGIN}/start`) {
  return pairStart.request(url, { method: "POST", headers }, env as never);
}

async function exchange(env: unknown, body: unknown, ip = "203.0.113.7") {
  return pairExchange.request(`${ORIGIN}/`, {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": ip },
    body: typeof body === "string" ? body : JSON.stringify(body),
  }, env as never);
}

function codeFrom(url: string): string {
  const u = new URL(url);
  assert.equal(u.protocol, "meetspike:");
  assert.equal(u.host, "pair");
  assert.equal(u.searchParams.get("origin"), ORIGIN);
  return u.searchParams.get("code") ?? "";
}

describe("pairing codes", () => {
  it("are 48 URL-safe characters and different every time", () => {
    const a = newPairingCode();
    const b = newPairingCode();
    assert.equal(a.length, PAIR_CODE_LEN);
    assert.match(a, /^[A-Za-z0-9_-]{48}$/);
    assert.notEqual(a, b);
    assert.deepEqual(splitCode(a), { id: a.slice(0, 16), secret: a.slice(16) });
    for (const bad of [null, 42, "", "short", `${a}x`, `${a.slice(0, 47)}!`]) assert.equal(splitCode(bad), null);
  });

  it("only redeem with the right secret before expiry", async () => {
    const now = Date.parse("2026-11-25T12:00:00Z");
    const stored = await storedPairing("s".repeat(32), now);
    assert.doesNotMatch(JSON.stringify(stored), /s{32}/, "only a hash is stored, not the secret");
    assert.equal(await redeemable(stored, "s".repeat(32), now + 1000), true);
    assert.equal(await redeemable(stored, "t".repeat(32), now + 1000), false);
    assert.equal(await redeemable(stored, "s".repeat(32), now + PAIR_TTL_S * 1000 + 1), false);
  });

  it("put only the origin and code in the link", () => {
    assert.equal(pairingUrl(ORIGIN, "abc"), "meetspike://pair?origin=https%3A%2F%2Fmeetspike.example&code=abc");
  });

});

describe("POST /api/pair/start", () => {
  it("stores a hashed, ten-minute code in D1 and returns a link without secrets", async () => {
    const { env, tokens, codes } = makeEnv({ PHONE_ACCESS_CLIENT_ID: "cid.access", PHONE_ACCESS_CLIENT_SECRET: "csecret" });
    const res = await start(env);
    assert.equal(res.status, 200);
    assert.match(res.headers.get("cache-control") ?? "", /no-store/);
    const text = await res.text();
    assert.doesNotMatch(text, new RegExp(SECRET));
    assert.doesNotMatch(text, /csecret|cid\.access/);
    const body = JSON.parse(text);
    assert.equal(body.includesAccessToken, true);
    assert.equal(body.origin, ORIGIN);
    const code = codeFrom(body.url);
    const rows = codes();
    assert.equal(rows.length, 1);
    assert.equal(rows[0].id, code.slice(0, 16));
    assert.doesNotMatch(JSON.stringify(rows[0]), new RegExp(code.slice(16)));
    const ttl = rows[0].expires_at - Date.now();
    assert.ok(ttl > 590_000 && ttl <= 600_000, String(ttl));
    assert.equal(tokens.store.size, 0, "nothing in KV");
    const expires = Date.parse(body.expiresAt) - Date.now();
    assert.ok(expires > 590_000 && expires <= 600_000, String(expires));
  });

  it("refuses without Cloudflare Access in front", async () => {
    const { env, codes } = makeEnv();
    const res = await start(env, {});
    assert.equal(res.status, 403);
    assert.equal(codes().length, 0);
  });

  it("refuses a forged or wrong Access header", async () => {
    const { env, codes } = makeEnv();
    const other = await makeAccessTeam(team.kid);
    const now = Math.floor(Date.now() / 1000);
    for (const token of [
      "header.payload.signature",
      await other.userToken(),
      await team.userToken({ aud: ["some-other-app"] }),
      await team.userToken({ exp: now - 3600 }),
      await team.userToken({ email: undefined, common_name: "phone.access" }),
    ]) {
      const res = await start(env, { "cf-access-jwt-assertion": token });
      assert.equal(res.status, 403);
      assert.doesNotMatch(await res.text(), new RegExp(SECRET));
    }
    assert.equal(codes().length, 0);
  });

  it("fails closed when ACCESS_TEAM_DOMAIN or ACCESS_AUD is missing", async () => {
    for (const missing of [{ ACCESS_AUD: "" }, { ACCESS_TEAM_DOMAIN: "" }]) {
      const { env, codes } = makeEnv(missing);
      const res = await start(env);
      assert.equal(res.status, 503);
      assert.match((await res.json()).error, /ACCESS_TEAM_DOMAIN and ACCESS_AUD/);
      assert.equal(codes().length, 0);
    }
  });

  it("lets wrangler dev on plain-http localhost through without Access", async () => {
    const { env, codes } = makeEnv({ ACCESS_TEAM_DOMAIN: "", ACCESS_AUD: "" });
    const res = await start(env, {}, "http://localhost:8787/start");
    assert.equal(res.status, 200);
    assert.equal(codes().length, 1);
  });

  it("explains when the ingest secret is missing", async () => {
    const { env, codes } = makeEnv({ INGEST_ADMIN_SECRET: " " });
    const res = await start(env);
    assert.equal(res.status, 503);
    assert.match((await res.json()).error, /INGEST_ADMIN_SECRET/);
    assert.equal(codes().length, 0);
  });

  it("makes older codes stop working when a new one is made", async () => {
    const { env, codes } = makeEnv();
    const first = codeFrom((await (await start(env)).json()).url);
    const second = codeFrom((await (await start(env)).json()).url);
    assert.deepEqual(codes().map((r) => r.id), [second.slice(0, 16)]);
    assert.equal((await exchange(env, { code: first })).status, 404);
    assert.equal((await exchange(env, { code: second }, "203.0.113.50")).status, 200);
  });

  it("explains a missing D1 migration instead of failing with a 500", async () => {
    const { env, raw } = makeEnv();
    raw.exec("DROP TABLE pair_codes");
    const res = await start(env);
    assert.equal(res.status, 503);
    assert.match((await res.json()).error, /0016_pair_codes/);
  });
});

describe("POST /hooks/pair", () => {
  async function freshCode(extra: Record<string, unknown> = {}) {
    const made = makeEnv(extra);
    const body = await (await start(made.env)).json();
    return { ...made, code: codeFrom(body.url) };
  }

  it("trades a code once for the ingest secret, without an Access token when none is set", async () => {
    const { env, codes, code } = await freshCode();
    const res = await exchange(env, { code });
    assert.equal(res.status, 200);
    assert.match(res.headers.get("cache-control") ?? "", /no-store/);
    assert.deepEqual(await res.json(), { ok: true, ingestSecret: SECRET, access: null });
    assert.equal(codes().length, 0, "deleted on use");
    const again = await exchange(env, { code });
    assert.equal(again.status, 404);
    assert.doesNotMatch(await again.text(), new RegExp(SECRET));
  });

  it("includes the phone's Access service token when the Worker has one", async () => {
    const { env, code } = await freshCode({ PHONE_ACCESS_CLIENT_ID: "cid.access", PHONE_ACCESS_CLIENT_SECRET: "csecret" });
    const body = await (await exchange(env, { code })).json();
    assert.deepEqual(body.access, { clientId: "cid.access", clientSecret: "csecret" });
  });

  it("burns the code on a wrong secret and answers like an unknown code", async () => {
    const { env, codes, code } = await freshCode();
    const wrong = code.slice(0, 16) + (code[16] === "A" ? "B" : "A") + code.slice(17);
    const res = await exchange(env, { code: wrong });
    assert.equal(res.status, 404);
    const unknown = await exchange(env, { code: `Z${code.slice(1)}` }, "203.0.113.8");
    assert.deepEqual(await res.json(), await unknown.json());
    assert.equal(codes().length, 0);
    assert.equal((await exchange(env, { code }, "203.0.113.9")).status, 404, "the real code no longer works");
  });

  it("rejects an expired code", async () => {
    const { env, raw, codes, code } = await freshCode();
    raw.prepare("UPDATE pair_codes SET expires_at = ?").run(Date.now() - 1);
    const res = await exchange(env, { code });
    assert.equal(res.status, 404);
    assert.equal(codes().length, 0);
  });

  it("pays out once when two phones race with the same code", async () => {
    const { env, code } = await freshCode();
    const [a, b] = await Promise.all([exchange(env, { code }, "203.0.113.60"), exchange(env, { code }, "203.0.113.61")]);
    assert.deepEqual([a.status, b.status].sort(), [200, 404]);
  });

  it("does not spend the code when the Worker has no ingest secret", async () => {
    const { env, codes, code } = await freshCode();
    const broken = { ...env, INGEST_ADMIN_SECRET: "" };
    assert.equal((await exchange(broken, { code })).status, 503);
    assert.equal(codes().length, 1);
    assert.equal((await exchange(env, { code }, "203.0.113.70")).status, 200);
  });

  it("rejects junk without touching codes", async () => {
    const { env } = makeEnv();
    for (const body of [{}, { code: 5 }, { code: "short" }, "not json"]) {
      const res = await exchange(env, body, `198.51.100.${String(JSON.stringify(body).length)}`);
      assert.equal(res.status, 400, JSON.stringify(body));
    }
    const big = await exchange(env, { code: "x".repeat(2000) }, "198.51.100.200");
    assert.equal(big.status, 413);
  });

  it("rate limits each address to five tries a minute", async () => {
    const { env, tokens } = makeEnv();
    for (let i = 0; i < 5; i++) assert.equal((await exchange(env, { code: "nope" })).status, 400);
    const limited = await exchange(env, { code: "nope" });
    assert.equal(limited.status, 429);
    assert.ok(Number(limited.headers.get("retry-after")) > 0);
    assert.equal((await exchange(env, { code: "nope" }, "203.0.113.99")).status, 400, "other addresses still work");
    assert.equal(tokens.ttl.get("pair:rl:203.0.113.7"), 3600);
  });
});

describe("wiring and setup page", () => {
  const root = new URL("..", import.meta.url);
  const read = (p: string) => readFileSync(new URL(p, root), "utf8");

  it("mounts start under /api (Access) and the exchange under /hooks (bypassed)", () => {
    const index = read("src/index.ts");
    assert.match(index, /app\.route\("\/api\/pair", pairStart\)/);
    assert.match(index, /app\.route\("\/hooks\/pair", pairExchange\)/);
    assert.ok(index.indexOf('"/api/pair"') < index.indexOf('app.route("/api", api)'));
  });

  it("draws the QR in the page with the vendored encoder, no CDN", () => {
    const js = read("public/setup.js");
    assert.match(js, /import \{ qrSvg \} from "\/qrcode\.js"/);
    assert.match(js, /\/api\/pair\/start/);
    assert.doesNotMatch(read("public/setup.html") + js, /https?:\/\/[^"'\s]*(cdn|unpkg|jsdelivr)/i);
    assert.match(read("public/qrcode.js"), /MIT License/);
  });

  it("keeps em dashes out of the new copy", () => {
    const html = read("public/setup.html");
    const section = html.slice(html.indexOf('id="step-phone"'));
    assert.doesNotMatch(section, /\u2014/);
    const js = read("public/setup.js");
    assert.doesNotMatch(js.slice(js.indexOf("Step 8"), js.indexOf('document.addEventListener("click"')), /\u2014/);
  });
});

describe("QR encoder", () => {
  function finderAt(qr: { get(x: number, y: number): boolean }, x0: number, y0: number) {
    for (let dy = 0; dy < 7; dy++) {
      for (let dx = 0; dx < 7; dx++) {
        const ring = Math.max(Math.abs(dx - 3), Math.abs(dy - 3));
        assert.equal(qr.get(x0 + dx, y0 + dy), ring !== 2, `finder at ${x0},${y0} (${dx},${dy})`);
      }
    }
  }

  it("picks the smallest version and draws the three finder patterns", () => {
    const small = encodeQr("hello");
    assert.equal(small.version, 1);
    assert.equal(small.size, 21);
    const link = encodeQr(pairingUrl("https://hg-biometrics.someone.workers.dev", newPairingCode()));
    assert.equal(link.size, link.version * 4 + 17);
    assert.ok(link.version <= 10, `version ${link.version}`);
    for (const qr of [small, link]) {
      finderAt(qr, 0, 0);
      finderAt(qr, qr.size - 7, 0);
      finderAt(qr, 0, qr.size - 7);
      assert.equal(qr.get(8, qr.size - 8), true, "dark module");
      assert.equal(qr.get(-1, 0), false);
    }
  });

  it("is deterministic and renders an SVG with a quiet zone and an accessible name", () => {
    const a = qrSvg("meetspike://pair?origin=x&code=y", 'Setup "code"');
    assert.equal(a, qrSvg("meetspike://pair?origin=x&code=y", 'Setup "code"'));
    const size = encodeQr("meetspike://pair?origin=x&code=y").size;
    assert.match(a, new RegExp(`viewBox="0 0 ${size + 8} ${size + 8}"`));
    assert.match(a, /aria-label="Setup &quot;code&quot;"/);
    assert.throws(() => encodeQr("x".repeat(3000)), /Data too long/);
  });
});
