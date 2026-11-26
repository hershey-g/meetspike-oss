import assert from "node:assert/strict";
import { register } from "node:module";
import { afterEach, describe, it } from "node:test";
import { api } from "../src/routes/api.ts";
import { setPhoneOwner } from "../src/sources/whoop-web/reminder.ts";
import { sqliteD1 } from "./sqlite-d1.ts";

/**
 * Build 11, track A (server): reminders come as an Apple push (APNs) only when heart rate is not coming in.
 * Contract: src/sources/whoop-web/push.ts (new). Spec: "Build 11: only remind when heart rate is not coming in".
 *
 * The module does not exist yet. It is loaded with a dynamic import so every test fails on its own assertion
 * ("push.ts exists") instead of one import error taking the whole file down. The route tests and the cron test
 * go through the real api router and src/index.ts, so they fail on behavior either way.
 *
 * Shapes the spec leaves open, chosen here (the builder follows them):
 *   - sendApns(env, device, message, now, fetch): device is { token, environment };
 *     message is { kind, pushType: "alert" | "background", payload, expiration (unix seconds), collapseId? }.
 *     apns-priority follows pushType: "10" for alert, "5" for background.
 *   - runPushTick(...).sent is a list with one entry per push APNs accepted in this tick.
 *   - duePushes returns objects with at least { kind, anchorMs }; a row is { id, start_utc, end_utc, duration_s,
 *     deleted_at?, override? } where the rows already carry effective times (the output of applyOverrides with
 *     includeExcluded) and override.calendarStartUtc is the calendar's own start.
 *   - DUE_KINDS are "on" | "followUp" | "off".
 */

const P = (await import("../src/sources/whoop-web/push.ts").catch(() => null)) as typeof import("../src/sources/whoop-web/push.ts") | null;
function push() {
  assert.ok(P, "src/sources/whoop-web/push.ts exists and exports the Build 11 push contract");
  return P;
}

const SECRET = "admin-secret-xyz";
const MIN = 60_000;
const HOUR = 3_600_000;
const S = Date.parse("2026-11-20T19:30:00.000Z"); // 2:30 PM in New York (EST)
const E = S + 30 * MIN;
const TOKEN = "ab".repeat(32);
const TOKEN2 = "cd".repeat(32);
const TITLE = "Secret Board Meeting";
const DEVICE_KEY = "push:device";
const JWT_KEY = "push:jwt";
const OWNER_KEY = "reminders:phone_owner";
const NOW = 1_800_000_000_000;

// ---------------------------------------------------------------------------------------------------------------
// Helpers

async function makeKey() {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const b64 = Buffer.from(new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey))).toString("base64");
  const pem = `-----BEGIN PRIVATE KEY-----\n${b64.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
  return { pem, b64, publicKey: pair.publicKey };
}
const KEY = await makeKey();
const OTHER_KEY = await makeKey();

const pushEnv = (extra: Record<string, unknown> = {}) => ({
  // Fix pass F2: registerDevice also needs WHOOP web heart rate to be on, like the tick.
  WHOOP_WEB_HR: "enabled",
  APNS_KEY_P8: KEY.pem,
  APNS_KEY_ID: "KEYID12345",
  APNS_TEAM_ID: "TEAMID6789",
  ...extra,
});

type KvOpts = { expirationTtl?: number } | undefined;
function recKv(initial: Record<string, string> = {}) {
  const store = new Map(Object.entries(initial));
  const kv = {
    store,
    puts: [] as Array<{ key: string; value: string; opts: KvOpts }>,
    deletes: [] as string[],
    failGet: false,
    failPut: false,
    get: async (k: string) => {
      if (kv.failGet) throw new Error("kv get down");
      return store.get(k) ?? null;
    },
    put: async (k: string, v: string, opts?: KvOpts) => {
      if (kv.failPut) throw new Error("kv put down");
      kv.puts.push({ key: k, value: v, opts });
      store.set(k, v);
    },
    delete: async (k: string) => {
      kv.deletes.push(k);
      store.delete(k);
    },
  };
  return kv;
}

type Call = { url: string; method: string; headers: Headers; body: any; signal: unknown };
function stubFetch(handler: (call: Call, n: number) => { status: number; body?: unknown } | Error) {
  const calls: Call[] = [];
  const impl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const call: Call = {
      url: String(input),
      method: String(init?.method ?? "GET"),
      headers: new Headers(init?.headers as HeadersInit),
      body: init?.body === undefined ? undefined : (() => { try { return JSON.parse(String(init.body)); } catch { return String(init.body); } })(),
      signal: init?.signal,
    };
    calls.push(call);
    const r = handler(call, calls.length);
    if (r instanceof Error) throw r;
    const text = r.body === undefined ? "" : typeof r.body === "string" ? r.body : JSON.stringify(r.body);
    return new Response(text, { status: r.status });
  }) as typeof fetch;
  return { calls, impl };
}
const ok200 = () => stubFetch(() => ({ status: 200 }));

function captureLogs() {
  const lines: string[] = [];
  const saved = { log: console.log, error: console.error, warn: console.warn, info: console.info };
  const grab = (...args: unknown[]) => void lines.push(args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" "));
  console.log = grab;
  console.error = grab;
  console.warn = grab;
  console.info = grab;
  return {
    lines,
    stop: () => Object.assign(console, saved),
  };
}
let activeLogs: ReturnType<typeof captureLogs> | null = null;
const realFetch = globalThis.fetch;
afterEach(() => {
  activeLogs?.stop();
  activeLogs = null;
  globalThis.fetch = realFetch;
});
function logs() {
  activeLogs = captureLogs();
  return activeLogs;
}

function b64urlDecode(s: string): Uint8Array {
  return new Uint8Array(Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64"));
}
async function readJwt(jwt: string, publicKey: CryptoKey = KEY.publicKey) {
  const parts = jwt.split(".");
  assert.equal(parts.length, 3, "three JWT segments");
  const header = JSON.parse(Buffer.from(b64urlDecode(parts[0])).toString("utf8"));
  const claims = JSON.parse(Buffer.from(b64urlDecode(parts[1])).toString("utf8"));
  const sig = b64urlDecode(parts[2]);
  const verified = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, sig, new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  return { header, claims, sigLength: sig.length, verified };
}

type Raw = ReturnType<typeof sqliteD1>["raw"];
function insertMeeting(raw: Raw, id: string, startMs: number, endMs: number, title = TITLE) {
  const startUtc = new Date(startMs).toISOString();
  const endUtc = new Date(endMs).toISOString();
  raw
    .prepare(
      `INSERT INTO calendar_event (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, title, kind, attendee_count, after_hours, updated_at, start_local, end_local)
       VALUES (?, 'google', ?, ?, ?, -300, ?, ?, 'client', 2, 0, 't', ?, ?)`,
    )
    .run(id, startUtc.slice(0, 10), startUtc, endUtc, (endMs - startMs) / 1000, title, startUtc, endUtc);
}
function seedHr(raw: Raw, timeMs: number, source: "ble" | "codebox" = "ble", user = "owner", bpm = 151) {
  raw.prepare(`INSERT INTO whoop_web_hr_raw (user_id, source, time_ms, bpm, received_at) VALUES (?, ?, ?, ?, 't')`).run(user, source, timeMs, bpm);
}

function spyDb(db: D1Database) {
  const state = { failHr: false };
  const queries: string[] = [];
  const wrapped = {
    prepare(sql: string) {
      queries.push(sql);
      if (state.failHr && /whoop_web_hr_raw/.test(sql)) {
        const boom = async () => {
          throw new Error("d1 down");
        };
        const bad: any = { bind: () => bad, first: boom, all: boom, run: boom };
        return bad;
      }
      return db.prepare(sql);
    },
    batch: (s: never) => db.batch(s),
  };
  return { db: wrapped as unknown as D1Database, state, queries, hrQueries: () => queries.filter((q) => /whoop_web_hr_raw/.test(q)).length };
}

type Meeting = { id: string; start: number; end: number };
async function world(opts: { meetings?: Meeting[]; covered?: number[]; device?: boolean; env?: Record<string, unknown>; checkInAt?: number } = {}) {
  const { db, raw } = sqliteD1();
  const spy = spyDb(db);
  const kv = recKv();
  const meetings = opts.meetings ?? [{ id: "m1", start: S, end: E }];
  for (const m of meetings) insertMeeting(raw, m.id, m.start, m.end);
  await setPhoneOwner(kv as never, true, opts.checkInAt ?? S - 2 * HOUR, opts.covered ?? meetings.map((m) => m.start));
  if (opts.device !== false) kv.store.set(DEVICE_KEY, JSON.stringify({ token: TOKEN, environment: "production", verifiedAt: new Date(S - HOUR).toISOString() }));
  const env = { DB: spy.db, TOKENS: kv, WHOOP_WEB_HR: "enabled", ...pushEnv(), ...opts.env };
  return { raw, kv, spy, env: env as never };
}

const normalizeSpaces = (s: string) => s.replace(/[  ]/g, " ");
const doneKeys = (kv: { store: Map<string, string> }) => [...kv.store.keys()].filter((k) => k.startsWith("push:done:")).sort();

// ---------------------------------------------------------------------------------------------------------------
describe("push: config, parsing, device record", () => {
  it("the cron is every minute and the config check needs key, key id and team id", () => {
    const p = push();
    assert.equal(p.PUSH_CRON, "* * * * *");
    assert.equal(p.pushConfigured(pushEnv() as never), true);
    assert.equal(p.pushConfigured({} as never), false);
    assert.equal(p.pushConfigured(pushEnv({ APNS_KEY_P8: "" }) as never), false);
    assert.equal(p.pushConfigured(pushEnv({ APNS_KEY_ID: "" }) as never), false);
    assert.equal(p.pushConfigured(pushEnv({ APNS_TEAM_ID: undefined }) as never), false);
    assert.equal(p.pushConfigured({ APNS_TOPIC: "x" } as never), false, "the topic alone is not enough");
  });

  it("parsePushRegistration: undefined when absent, null when invalid, lowercased token otherwise", () => {
    const p = push();
    assert.equal(p.parsePushRegistration(undefined), undefined);
    assert.deepEqual(p.parsePushRegistration({ token: TOKEN, environment: "production" }), { token: TOKEN, environment: "production" });
    assert.deepEqual(p.parsePushRegistration({ token: TOKEN.toUpperCase(), environment: "development" }), { token: TOKEN, environment: "development" }, "lowercased");
    assert.deepEqual(p.parsePushRegistration({ token: "a".repeat(200), environment: "production" }), { token: "a".repeat(200), environment: "production" }, "200 is allowed");
    assert.deepEqual(
      p.parsePushRegistration({ token: TOKEN, environment: "production", extra: 1 }),
      { token: TOKEN, environment: "production" },
      "only the two fields come back",
    );
    for (const bad of [
      { token: "a".repeat(63), environment: "production" },
      { token: "a".repeat(201), environment: "production" },
      { token: "g".repeat(64), environment: "production" },
      { token: ` ${TOKEN}`, environment: "production" },
      { token: `${TOKEN}\n`, environment: "production" },
      { token: 12345, environment: "production" },
      { environment: "production" },
      { token: TOKEN },
      { token: TOKEN, environment: "staging" },
      { token: TOKEN, environment: "Production" },
      { token: TOKEN, environment: "" },
      { token: TOKEN, environment: undefined },
      null,
      "abcd",
      42,
      true,
      [],
      [{ token: TOKEN, environment: "production" }],
    ]) {
      assert.equal(p.parsePushRegistration(bad), null, JSON.stringify(bad));
    }
  });

  it("readDevice and clearDevice work on the push:device key", async () => {
    const p = push();
    const kv = recKv();
    assert.equal(await p.readDevice(kv as never), null);
    kv.store.set(DEVICE_KEY, JSON.stringify({ token: TOKEN, environment: "production", verifiedAt: "2026-11-20T00:00:00.000Z" }));
    assert.deepEqual(await p.readDevice(kv as never), { token: TOKEN, environment: "production", verifiedAt: "2026-11-20T00:00:00.000Z" });
    await p.clearDevice(kv as never);
    assert.equal(kv.store.has(DEVICE_KEY), false);
    assert.equal(await p.readDevice(kv as never), null);
    kv.store.set(DEVICE_KEY, "{not json");
    assert.equal(await p.readDevice(kv as never), null, "garbage reads as no device");
  });
});

// ---------------------------------------------------------------------------------------------------------------
describe("push: heartRateLive", () => {
  it("is true for a reading under 60 s old and false at 60 s", async () => {
    const p = push();
    const { db, raw } = sqliteD1();
    assert.equal(await p.heartRateLive(db, NOW), false, "no rows");
    seedHr(raw, NOW - 59_000);
    assert.equal(await p.heartRateLive(db, NOW), true, "59 s old");
    raw.prepare(`DELETE FROM whoop_web_hr_raw`).run();
    seedHr(raw, NOW - 60_000);
    assert.equal(await p.heartRateLive(db, NOW), false, "exactly 60 s old is not live");
    raw.prepare(`DELETE FROM whoop_web_hr_raw`).run();
    seedHr(raw, NOW - 59_999);
    assert.equal(await p.heartRateLive(db, NOW), true);
  });

  it("allows up to 60 s of clock skew into the future", async () => {
    const p = push();
    const { db, raw } = sqliteD1();
    seedHr(raw, NOW + 60_000);
    assert.equal(await p.heartRateLive(db, NOW), true, "60 s ahead still counts");
    raw.prepare(`DELETE FROM whoop_web_hr_raw`).run();
    seedHr(raw, NOW + 60_001);
    assert.equal(await p.heartRateLive(db, NOW), false, "more than 60 s ahead is a bad clock, not heart rate");
  });

  it("counts only the owner's phone and Mac readings, never the codebox ones", async () => {
    const p = push();
    const { db, raw } = sqliteD1();
    seedHr(raw, NOW - 5_000, "codebox");
    assert.equal(await p.heartRateLive(db, NOW), false, "codebox rows are backfilled history, not a live broadcast");
    seedHr(raw, NOW - 5_000, "ble", "someone-else");
    assert.equal(await p.heartRateLive(db, NOW), false, "another user id is not the owner");
    seedHr(raw, NOW - 5_000, "ble", "owner");
    assert.equal(await p.heartRateLive(db, NOW), true);
  });

  it("takes a window: 90 s for the off check", async () => {
    const p = push();
    const { db, raw } = sqliteD1();
    seedHr(raw, NOW - 80_000);
    assert.equal(await p.heartRateLive(db, NOW), false, "default window is 60 s");
    assert.equal(await p.heartRateLive(db, NOW, 90_000), true);
    assert.equal(await p.heartRateLive(db, NOW + 10_000, 90_000), false, "90 s old at the edge is not live");
  });

  it("throws when the query fails, so callers decide", async () => {
    const p = push();
    const broken = { prepare: () => ({ bind: () => ({ first: async () => { throw new Error("d1 down"); }, all: async () => { throw new Error("d1 down"); } }) }) };
    await assert.rejects(() => p.heartRateLive(broken as never, NOW));
  });
});

// ---------------------------------------------------------------------------------------------------------------
describe("push: apnsJwt", () => {
  it("signs ES256 with the key id as kid and the team id as iss, verifiable with the public key", async () => {
    const p = push();
    const kv = recKv();
    const jwt = await p.apnsJwt(pushEnv() as never, kv as never, NOW);
    const parsed = await readJwt(jwt);
    assert.deepEqual(parsed.header, { alg: "ES256", kid: "KEYID12345" });
    assert.deepEqual(parsed.claims, { iss: "TEAMID6789", iat: Math.floor(NOW / 1000) });
    assert.equal(parsed.sigLength, 64, "raw r||s signature, as JWT ES256 needs");
    assert.equal(parsed.verified, true);
    assert.equal((await readJwt(jwt, OTHER_KEY.publicKey)).verified, false, "and not with another key");
  });

  it("accepts the key with real newlines or with literal backslash-n", async () => {
    const p = push();
    const literal = KEY.pem.trim().replace(/\n/g, "\\n");
    assert.ok(literal.includes("\\n") && !literal.includes("\n"));
    const jwt = await p.apnsJwt(pushEnv({ APNS_KEY_P8: literal }) as never, recKv() as never, NOW);
    assert.equal((await readJwt(jwt)).verified, true);
  });

  it("is reused for 40 minutes through KV, then replaced", async () => {
    const p = push();
    const kv = recKv();
    const first = await p.apnsJwt(pushEnv() as never, kv as never, NOW);
    const stored = kv.puts.find((x) => x.key === JWT_KEY);
    assert.ok(stored, "stored under push:jwt");
    const record = JSON.parse(stored.value);
    assert.equal(record.keyId, "KEYID12345");
    assert.equal(record.jwt, first);
    assert.equal(record.iat, Math.floor(NOW / 1000));
    assert.equal(typeof stored.opts?.expirationTtl, "number", "expires on its own");
    assert.ok((stored.opts?.expirationTtl ?? 0) > 0);

    const again = await p.apnsJwt(pushEnv() as never, kv as never, NOW + 39 * MIN);
    assert.equal(again, first, "39 minutes later it is the same token (APNs rejects providers that mint too often)");
    const later = await p.apnsJwt(pushEnv() as never, kv as never, NOW + 41 * MIN);
    assert.notEqual(later, first, "41 minutes later it is new");
    assert.equal((await readJwt(later)).claims.iat, Math.floor((NOW + 41 * MIN) / 1000));
  });

  it("ignores a cached token minted for another key id", async () => {
    const p = push();
    const kv = recKv();
    const first = await p.apnsJwt(pushEnv({ APNS_KEY_ID: "OLDKEY0001" }) as never, kv as never, NOW);
    const second = await p.apnsJwt(pushEnv({ APNS_KEY_ID: "NEWKEY0002" }) as never, kv as never, NOW + MIN);
    assert.notEqual(second, first);
    assert.equal((await readJwt(second)).header.kid, "NEWKEY0002");
  });

  it("just signs a new one when KV fails", async () => {
    const p = push();
    const kv = recKv();
    kv.failGet = true;
    kv.failPut = true;
    const jwt = await p.apnsJwt(pushEnv() as never, kv as never, NOW);
    assert.equal((await readJwt(jwt)).verified, true);
  });

  it("does not trust a cached record that is not a JWT record", async () => {
    const p = push();
    const kv = recKv({ [JWT_KEY]: "garbage" });
    assert.equal((await readJwt(await p.apnsJwt(pushEnv() as never, kv as never, NOW))).verified, true);
  });
});

// ---------------------------------------------------------------------------------------------------------------
describe("push: sendApns", () => {
  const device = (environment: "production" | "development" = "production") => ({ token: TOKEN, environment });
  const message = (over: Record<string, unknown> = {}) => ({
    kind: "on",
    pushType: "alert",
    payload: { aps: { alert: { title: "T", body: "B" }, sound: "default" } },
    expiration: Math.floor(NOW / 1000) + 300,
    collapseId: "meetspike.broadcast.on.1",
    ...over,
  });
  const send = (env: unknown, _unused: unknown, f: typeof fetch, over: Record<string, unknown> = {}, dev = device()) =>
    push().sendApns(env as never, dev as never, message(over) as never, NOW, f);

  it("posts to the production host for production tokens and the sandbox host for development tokens", async () => {
    const prod = ok200();
    assert.equal(await send(pushEnv({ TOKENS: recKv() }), null, prod.impl), "sent");
    assert.equal(prod.calls[0].url, `https://api.push.apple.com/3/device/${TOKEN}`);
    assert.equal(prod.calls[0].method, "POST");
    const dev = ok200();
    assert.equal(await send(pushEnv({ TOKENS: recKv() }), null, dev.impl, {}, device("development")), "sent");
    assert.equal(dev.calls[0].url, `https://api.sandbox.push.apple.com/3/device/${TOKEN}`);
  });

  it("sets the APNs headers and sends the payload as JSON", async () => {
    const f = ok200();
    const env = pushEnv({ TOKENS: recKv() });
    await send(env, null, f.impl);
    const h = f.calls[0].headers;
    const jwt = (h.get("authorization") ?? "").replace(/^bearer /i, "");
    assert.match(h.get("authorization") ?? "", /^bearer /i);
    assert.equal((await readJwt(jwt)).verified, true);
    assert.equal(h.get("apns-topic"), "com.hersheyg.meetspike.hr", "default topic");
    assert.equal(h.get("apns-push-type"), "alert");
    assert.equal(h.get("apns-priority"), "10");
    assert.equal(h.get("apns-expiration"), String(Math.floor(NOW / 1000) + 300));
    assert.equal(h.get("apns-collapse-id"), "meetspike.broadcast.on.1");
    assert.deepEqual(f.calls[0].body, { aps: { alert: { title: "T", body: "B" }, sound: "default" } });
    assert.ok(f.calls[0].signal, "has a timeout signal (8 s)");
  });

  it("a background push has push type background and priority 5, and the topic can be set", async () => {
    const f = ok200();
    await send(pushEnv({ TOKENS: recKv(), APNS_TOPIC: "com.example.other" }), null, f.impl, {
      kind: "register", pushType: "background", payload: { aps: { "content-available": 1 } }, collapseId: undefined,
    });
    const h = f.calls[0].headers;
    assert.equal(h.get("apns-topic"), "com.example.other");
    assert.equal(h.get("apns-push-type"), "background");
    assert.equal(h.get("apns-priority"), "5");
    assert.equal(h.get("apns-collapse-id"), null, "only when given");
  });

  it("maps Apple's answers: 200 sent, 410 and bad device token gone, anything else failed", async () => {
    const cases: Array<[number, unknown, string]> = [
      [200, "", "sent"],
      [200, { ok: true }, "sent"],
      [410, { reason: "Unregistered" }, "gone"],
      [410, "", "gone"],
      [400, { reason: "BadDeviceToken" }, "gone"],
      [400, { reason: "DeviceTokenNotForTopic" }, "gone"],
      [400, { reason: "PayloadEmpty" }, "rejected"],
      [400, "", "rejected"],
      [403, { reason: "Forbidden" }, "rejected"],
      [429, { reason: "TooManyRequests" }, "failed"],
      [500, { reason: "InternalServerError" }, "failed"],
      [503, { reason: "ServiceUnavailable" }, "failed"],
    ];
    for (const [status, body, expected] of cases) {
      const f = stubFetch(() => ({ status, body }));
      const result = await send(pushEnv({ TOKENS: recKv() }), null, f.impl);
      if (expected === "rejected") {
        // Fix pass F1/F4: a permanent 4xx other than 429 may come back as "failed" or as its own result (or "gone"),
        // as long as it is never "sent". The callers' behavior is tested in push-fix.test.ts.
        assert.notEqual(result, "sent", `${status} ${JSON.stringify(body)}`);
      } else {
        assert.equal(result, expected, `${status} ${JSON.stringify(body)}`);
      }
      assert.equal(f.calls.length, 1, `${status}: no retry`);
    }
  });

  it("never throws: a network error, a bad key and an unreadable answer are all failed", async () => {
    const boom = stubFetch(() => new Error("connection reset"));
    assert.equal(await send(pushEnv({ TOKENS: recKv() }), null, boom.impl), "failed");
    const noFetch = ok200();
    assert.equal(await send(pushEnv({ TOKENS: recKv(), APNS_KEY_P8: "not a key" }), null, noFetch.impl), "failed", "a key that cannot sign");
    assert.equal(noFetch.calls.length, 0);
    assert.equal(await send(pushEnv({ TOKENS: recKv() }), null, (async () => ({ status: 200, text: async () => { throw new Error("x"); } })) as never), "sent");
  });

  it("answers not_configured without any request when the key, key id or team id is missing", async () => {
    for (const env of [{}, pushEnv({ APNS_KEY_P8: undefined }), pushEnv({ APNS_KEY_ID: "" }), pushEnv({ APNS_TEAM_ID: undefined })]) {
      const f = ok200();
      assert.equal(await send({ ...env, TOKENS: recKv() }, null, f.impl), "not_configured");
      assert.equal(f.calls.length, 0);
    }
  });

  it("retries once with a fresh JWT after 403 ExpiredProviderToken or InvalidProviderToken, and clears the cached JWT", async () => {
    for (const reason of ["ExpiredProviderToken", "InvalidProviderToken"]) {
      const kv = recKv();
      const f = stubFetch((_c, n) => (n === 1 ? { status: 403, body: { reason } } : { status: 200 }));
      assert.equal(await send(pushEnv({ TOKENS: kv }), null, f.impl), "sent", reason);
      assert.equal(f.calls.length, 2, `${reason}: exactly one retry`);
      assert.notEqual(f.calls[0].headers.get("authorization"), f.calls[1].headers.get("authorization"), "a different token the second time");
      assert.ok(kv.deletes.includes(JWT_KEY), "the cached JWT was deleted");
      assert.equal((await readJwt((f.calls[1].headers.get("authorization") ?? "").replace(/^bearer /i, ""))).verified, true);
    }
  });

  it("gives up after one retry, and other 403s are not retried", async () => {
    const twice = stubFetch(() => ({ status: 403, body: { reason: "ExpiredProviderToken" } }));
    assert.notEqual(await send(pushEnv({ TOKENS: recKv() }), null, twice.impl), "sent", "still failing after the retry (permanent, see push-fix.test.ts)");
    assert.equal(twice.calls.length, 2, "never more than two requests");
    const other = stubFetch(() => ({ status: 403, body: { reason: "BadCertificate" } }));
    assert.notEqual(await send(pushEnv({ TOKENS: recKv() }), null, other.impl), "sent");
    assert.equal(other.calls.length, 1);
  });

  it("logs one push_failed line with kind, status and a letters-only reason, and nothing secret", async () => {
    const out = logs();
    const kv = recKv();
    const env = pushEnv({ TOKENS: kv });
    await send(env, null, stubFetch(() => ({ status: 500, body: { reason: "InternalServerError" } })).impl);
    await send(env, null, stubFetch(() => ({ status: 400, body: { reason: "Weird <b>reason</b> with 123 symbols" } })).impl);
    await send(env, null, stubFetch(() => new Error(`connect failed https://api.push.apple.com/3/device/${TOKEN} bearer eyJhbGciOiJFUzI1NiJ9.x.y`)).impl);
    await send(env, null, ok200().impl);
    out.stop();
    const failed = out.lines.filter((l) => l.includes("push_failed")).map((l) => JSON.parse(l));
    assert.equal(failed.length, 3, "one line per failure, none for the success");
    assert.deepEqual(failed[0], { event: "push_failed", kind: "on", status: 500, reason: "InternalServerError" });
    for (const line of failed) {
      assert.ok(Object.keys(line).every((k) => ["event", "kind", "status", "reason"].includes(k)), JSON.stringify(line));
      assert.equal(line.event, "push_failed");
      assert.equal(line.kind, "on");
      assert.ok(line.reason === undefined || line.reason === null || line.reason === "" || /^[A-Za-z]{1,64}$/.test(line.reason), `reason: ${line.reason}`);
    }
    const everything = out.lines.join("\n");
    assert.ok(!everything.includes(TOKEN), "no device token in logs");
    assert.ok(!everything.includes(KEY.b64.slice(20, 80)), "no key material in logs");
    assert.ok(!/eyJ[A-Za-z0-9_-]+\./.test(everything), "no JWT in logs");
    assert.ok(!everything.includes("BEGIN PRIVATE KEY"));
  });
});

// ---------------------------------------------------------------------------------------------------------------
describe("push: registerDevice", () => {
  const reg = { token: TOKEN, environment: "production" as const };
  const stored = (kv: { store: Map<string, string> }) => {
    const v = kv.store.get(DEVICE_KEY);
    return v ? JSON.parse(v) : null;
  };
  const envWith = (kv: unknown, extra: Record<string, unknown> = {}) => ({ TOKENS: kv, ...pushEnv(extra) }) as never;

  it("not configured: clears any device and says false without a request", async () => {
    const p = push();
    const kv = recKv({ [DEVICE_KEY]: JSON.stringify({ token: TOKEN, environment: "production", verifiedAt: new Date(NOW).toISOString() }) });
    const f = ok200();
    assert.equal(await p.registerDevice({ TOKENS: kv } as never, reg, NOW, f.impl), false);
    assert.equal(f.calls.length, 0);
    assert.equal(kv.store.has(DEVICE_KEY), false);
  });

  it("first accept: sends one invisible background push, stores the device and says true", async () => {
    const p = push();
    const kv = recKv();
    const f = ok200();
    assert.equal(await p.registerDevice(envWith(kv), reg, NOW, f.impl), true);
    assert.equal(f.calls.length, 1);
    const call = f.calls[0];
    assert.equal(call.url, `https://api.push.apple.com/3/device/${TOKEN}`);
    assert.equal(call.headers.get("apns-push-type"), "background");
    assert.equal(call.headers.get("apns-priority"), "5");
    assert.equal(call.headers.get("apns-expiration"), String(Math.floor(NOW / 1000) + 60));
    assert.deepEqual(call.body, { aps: { "content-available": 1 } });
    assert.deepEqual(stored(kv), { token: TOKEN, environment: "production", verifiedAt: new Date(NOW).toISOString() });
  });

  it("uses the sandbox host for a development token", async () => {
    const p = push();
    const f = ok200();
    assert.equal(await p.registerDevice(envWith(recKv()), { token: TOKEN, environment: "development" }, NOW, f.impl), true);
    assert.ok(f.calls[0].url.startsWith("https://api.sandbox.push.apple.com/3/device/"));
  });

  it("the same token and environment verified within 24 h is true with no send", async () => {
    const p = push();
    const kv = recKv();
    const f = ok200();
    await p.registerDevice(envWith(kv), reg, NOW, f.impl);
    assert.equal(await p.registerDevice(envWith(kv), reg, NOW + 23 * HOUR + 59 * MIN, f.impl), true);
    assert.equal(f.calls.length, 1, "cached");
    assert.equal(await p.registerDevice(envWith(kv), reg, NOW + 24 * HOUR + MIN, f.impl), true);
    assert.equal(f.calls.length, 2, "verified again after 24 h");
    assert.equal(stored(kv).verifiedAt, new Date(NOW + 24 * HOUR + MIN).toISOString());
  });

  it("a changed token or environment is verified again at once", async () => {
    const p = push();
    const kv = recKv();
    const f = ok200();
    await p.registerDevice(envWith(kv), reg, NOW, f.impl);
    assert.equal(await p.registerDevice(envWith(kv), { token: TOKEN2, environment: "production" }, NOW + MIN, f.impl), true);
    assert.equal(f.calls.length, 2);
    assert.equal(stored(kv).token, TOKEN2);
    assert.equal(await p.registerDevice(envWith(kv), { token: TOKEN2, environment: "development" }, NOW + 2 * MIN, f.impl), true);
    assert.equal(f.calls.length, 3);
    assert.equal(stored(kv).environment, "development");
  });

  it("a blip keeps the same stored device and stays true", async () => {
    const p = push();
    const kv = recKv();
    await p.registerDevice(envWith(kv), reg, NOW, ok200().impl);
    const before = kv.store.get(DEVICE_KEY);
    for (const handler of [() => ({ status: 500, body: { reason: "InternalServerError" } }), () => new Error("offline")]) {
      const f = stubFetch(handler as never);
      assert.equal(await p.registerDevice(envWith(kv), reg, NOW + 25 * HOUR, f.impl), true, "a blip must not flip reminders back to local");
      assert.equal(f.calls.length, 1, "it did try, the cache was stale");
      assert.equal(kv.store.get(DEVICE_KEY), before, "stored device untouched");
    }
  });

  it("a blip with a different token stores nothing, clears the old device and says false", async () => {
    const p = push();
    const kv = recKv();
    await p.registerDevice(envWith(kv), reg, NOW, ok200().impl);
    const f = stubFetch(() => ({ status: 500 }));
    assert.equal(await p.registerDevice(envWith(kv), { token: TOKEN2, environment: "production" }, NOW + MIN, f.impl), false);
    assert.equal(kv.store.has(DEVICE_KEY), false);
    const empty = recKv();
    assert.equal(await p.registerDevice(envWith(empty), reg, NOW, stubFetch(() => ({ status: 500 })).impl), false);
    assert.equal(empty.store.has(DEVICE_KEY), false, "nothing stored on a first failure");
  });

  it("gone clears the device and says false, even for the stored token", async () => {
    const p = push();
    const kv = recKv();
    await p.registerDevice(envWith(kv), reg, NOW, ok200().impl);
    assert.equal(await p.registerDevice(envWith(kv), reg, NOW + 25 * HOUR, stubFetch(() => ({ status: 410, body: { reason: "Unregistered" } })).impl), false);
    assert.equal(kv.store.has(DEVICE_KEY), false);
    assert.equal(await p.registerDevice(envWith(kv), reg, NOW + 26 * HOUR, stubFetch(() => ({ status: 400, body: { reason: "BadDeviceToken" } })).impl), false);
  });
});

// ---------------------------------------------------------------------------------------------------------------
describe("push: duePushes (pure timing)", () => {
  const row = (id: string, startMs: number, endMs: number, extra: Record<string, unknown> = {}) => ({
    id, start_utc: new Date(startMs).toISOString(), end_utc: new Date(endMs).toISOString(), duration_s: (endMs - startMs) / 1000, deleted_at: null, ...extra,
  });
  const due = (covered: number[], rows: unknown[], now: number) =>
    push().duePushes({ covered, rows: rows as never, now }).map((d: any) => `${d.kind}:${d.anchorMs}`).sort();

  it("on is due when the start is 1 ms to 120 s away, never at or after the start", () => {
    const rows = [row("m", S, E)];
    assert.deepEqual(due([S], rows, S - 120_001), []);
    assert.deepEqual(due([S], rows, S - 120_000), [`on:${S}`]);
    assert.deepEqual(due([S], rows, S - 1), [`on:${S}`]);
    assert.deepEqual(due([S], rows, S), []);
  });

  it("followUp is due from 60 s up to (not including) 180 s after the start", () => {
    const rows = [row("m", S, E)];
    assert.deepEqual(due([S], rows, S + 59_999), []);
    assert.deepEqual(due([S], rows, S + 60_000), [`followUp:${S}`]);
    assert.deepEqual(due([S], rows, S + 179_999), [`followUp:${S}`]);
    assert.deepEqual(due([S], rows, S + 180_000), []);
  });

  it("off is due 540 s up to (not including) 600 s after the end, anchored on the end", () => {
    const rows = [row("m", S, E)];
    assert.deepEqual(due([S], rows, E + 539_999), []);
    assert.deepEqual(due([S], rows, E + 540_000), [`off:${E}`]);
    assert.deepEqual(due([S], rows, E + 599_999), [`off:${E}`]);
    assert.deepEqual(due([S], rows, E + 600_000), []);
  });

  it("off waits while another covered meeting is running or starts within 15 minutes", () => {
    const now = E + 570_000;
    const first = row("a", S, E);
    const next = (start: number, end = start + 30 * MIN) => row("b", start, end);
    assert.deepEqual(due([S, now + 10 * MIN], [first, next(now + 10 * MIN)], now), [], "starts in 10 minutes");
    assert.deepEqual(due([S, now + 14 * MIN], [first, next(now + 14 * MIN)], now), [], "starts in 14 minutes");
    assert.deepEqual(due([S, now + 16 * MIN], [first, next(now + 16 * MIN)], now), [`off:${E}`], "16 minutes away is far enough");
    assert.deepEqual(due([S, S + 10 * MIN], [first, next(S + 10 * MIN, E + 40 * MIN)], now), [], "another meeting is running");
    assert.deepEqual(due([S, S - 3 * HOUR], [first, next(S - 3 * HOUR, S - 2 * HOUR)], now), [`off:${E}`], "an earlier meeting that is over does not block");
  });

  it("two meetings at one start give one on and one followUp, and the off uses the latest end", () => {
    const rows = [row("a", S, E), row("b", S, E + 20 * MIN)];
    assert.deepEqual(due([S], rows, S - 90_000), [`on:${S}`]);
    assert.deepEqual(due([S], rows, S + 90_000), [`followUp:${S}`]);
    assert.deepEqual(due([S], rows, E + 570_000), [], "the first one's end is not the end");
    assert.deepEqual(due([S], rows, E + 20 * MIN + 570_000), [`off:${E + 20 * MIN}`]);
  });

  it("a covered start with no calendar row is its own meeting: on and followUp, never off", () => {
    assert.deepEqual(due([S], [], S - 60_000), [`on:${S}`]);
    assert.deepEqual(due([S], [], S + 60_000), [`followUp:${S}`]);
    assert.deepEqual(due([S], [], S + 30 * MIN + 570_000), [], "no end, so no off");
    assert.deepEqual(due([S], [row("far", S + 91_000, E)], S - 60_000), [`on:${S}`], "91 s apart is another meeting");
  });

  it("a row within 90 s of the covered start is the same meeting and its own times win", () => {
    const rows = [row("a", S + 45_000, E + 45_000)];
    assert.deepEqual(due([S], rows, S + 45_000 - 60_000), [`on:${S + 45_000}`]);
    assert.deepEqual(due([S], rows, S + 45_000 - 60_000).length, 1, "and not also a second one for the covered start");
  });

  it("uses the owner's times: the covered start is the calendar's, the push follows the effective start", () => {
    const moved = row("a", S + 10 * MIN, E + 10 * MIN, {
      override: { state: null, scope: null, excluded: false, timesChanged: true, calendarStartUtc: new Date(S).toISOString(), calendarEndUtc: new Date(E).toISOString() },
    });
    assert.deepEqual(due([S], [moved], S - 60_000), [], "the calendar start is no longer the start");
    assert.deepEqual(due([S], [moved], S + 10 * MIN - 60_000), [`on:${S + 10 * MIN}`]);
    assert.deepEqual(due([S], [moved], E + 10 * MIN + 570_000), [`off:${E + 10 * MIN}`]);
  });

  it("a meeting the owner left out gets no push of any kind, and is not treated as unmatched", () => {
    const out = row("a", S, E, {
      override: { state: "not_joined", scope: "event", excluded: true, timesChanged: false, calendarStartUtc: new Date(S).toISOString(), calendarEndUtc: new Date(E).toISOString() },
    });
    assert.deepEqual(due([S], [out], S - 60_000), []);
    assert.deepEqual(due([S], [out], S + 90_000), []);
    assert.deepEqual(due([S], [out], E + 570_000), []);
    const keep = row("b", S, E);
    assert.deepEqual(due([S], [out, keep], S - 60_000), [`on:${S}`], "only dropped when all of them are left out");
  });

  it("a meeting that was deleted from the calendar gets no push", () => {
    const gone = row("a", S, E, { deleted_at: "2026-11-20T10:00:00.000Z" });
    assert.deepEqual(due([S], [gone], S - 60_000), []);
    assert.deepEqual(due([S], [gone], E + 570_000), []);
  });

  it("follows the duration rules: more than 0 and at most 8 h (12 h when the times were changed)", () => {
    assert.deepEqual(due([S], [row("zero", S, S)], S - 60_000), []);
    assert.deepEqual(due([S], [row("long", S, S + 9 * HOUR)], S - 60_000), []);
    assert.deepEqual(due([S], [row("edge", S, S + 8 * HOUR)], S - 60_000), [`on:${S}`]);
    const moved = row("moved", S, S + 11 * HOUR, {
      override: { state: null, scope: null, excluded: false, timesChanged: true, calendarStartUtc: new Date(S).toISOString(), calendarEndUtc: new Date(S + HOUR).toISOString() },
    });
    assert.deepEqual(due([S], [moved], S - 60_000), [`on:${S}`]);
  });

  it("returns nothing for no covered starts", () => {
    assert.deepEqual(due([], [row("a", S, E)], S - 60_000), []);
  });
});

// ---------------------------------------------------------------------------------------------------------------
describe("push: runPushTick", () => {
  it("heart rate live: nothing is sent, and the decision is final", async () => {
    const p = push();
    const w = await world();
    seedHr(w.raw, S - 120_000 - 30_000);
    const f = ok200();
    const r = await p.runPushTick(w.env, S - 120_000, f.impl);
    assert.deepEqual(r.sent, []);
    assert.equal(f.calls.length, 0);
    assert.equal(w.kv.store.get(`push:done:on:${S}`), "live");
    const put = w.kv.puts.find((x) => x.key === `push:done:on:${S}`);
    assert.equal(put?.opts?.expirationTtl, 86_400, "kept for a day");
    // The strap drops a moment later: still final, nothing is sent for this meeting's on reminder.
    w.raw.prepare(`DELETE FROM whoop_web_hr_raw`).run();
    await p.runPushTick(w.env, S - 90_000, f.impl);
    await p.runPushTick(w.env, S - 10_000, f.impl);
    assert.equal(f.calls.length, 0);
  });

  it("not live: sends the on push once, even when ticked twice, and records it", async () => {
    const p = push();
    const w = await world();
    const f = ok200();
    const r = await p.runPushTick(w.env, S - 120_000, f.impl);
    assert.equal(r.sent.length, 1);
    assert.equal(f.calls.length, 1);
    const call = f.calls[0];
    assert.equal(call.url, `https://api.push.apple.com/3/device/${TOKEN}`);
    assert.equal(call.headers.get("apns-push-type"), "alert");
    assert.equal(call.headers.get("apns-priority"), "10");
    assert.equal(call.headers.get("apns-collapse-id"), `meetspike.broadcast.on.${S}`);
    assert.equal(call.headers.get("apns-expiration"), String((S + 5 * MIN) / 1000), "start + 5 minutes");
    assert.equal(call.headers.get("apns-topic"), "com.hersheyg.meetspike.hr");
    assert.equal(w.kv.store.get(`push:done:on:${S}`), "sent");
    assert.equal(w.kv.puts.find((x) => x.key === `push:done:on:${S}`)?.opts?.expirationTtl, 86_400);
    const again = await p.runPushTick(w.env, S - 120_000 + 30_000, f.impl);
    assert.deepEqual(again.sent, []);
    await p.runPushTick(w.env, S - 1_000, f.impl);
    assert.equal(f.calls.length, 1, "once");
  });

  it("the on copy: title, body with the start time in the owner's zone, payload fields", async () => {
    const p = push();
    const w = await world();
    const f = ok200();
    await p.runPushTick(w.env, S - 120_000, f.impl);
    const aps = f.calls[0].body.aps;
    assert.equal(aps.alert.title, "Turn on HR Broadcast in the WHOOP app");
    assert.equal(
      normalizeSpaces(aps.alert.body),
      "Your 2:30 PM meeting starts in 2 minutes and no heart rate is coming in. In WHOOP, open Device Settings and turn on HR Broadcast.",
    );
    assert.equal(aps.sound, "default");
    assert.equal(aps["thread-id"], "meetspike.broadcast");
    assert.equal(aps["interruption-level"], "time-sensitive");
    assert.deepEqual(Object.keys(f.calls[0].body), ["aps"]);
  });

  it("says 1 minute in the singular and counts minutes up", async () => {
    const p = push();
    for (const [secondsBefore, text] of [[120, "2 minutes"], [90, "2 minutes"], [61, "2 minutes"], [60, "1 minute"], [59, "1 minute"], [1, "1 minute"]] as const) {
      const w = await world();
      const f = ok200();
      await p.runPushTick(w.env, S - secondsBefore * 1000, f.impl);
      assert.match(normalizeSpaces(f.calls[0].body.aps.alert.body), new RegExp(`starts in ${text} and no heart rate`), `${secondsBefore} s before`);
    }
  });

  it("the start time follows the owner's time zone", async () => {
    const p = push();
    const w = await world();
    w.raw.prepare(`INSERT OR REPLACE INTO user_profile (id, time_zone, updated_at) VALUES ('self', 'Asia/Tokyo', 't')`).run();
    const f = ok200();
    await p.runPushTick(w.env, S - 120_000, f.impl);
    assert.match(normalizeSpaces(f.calls[0].body.aps.alert.body), /^Your 4:30 AM meeting starts in 2 minutes/);
  });

  it("followUp goes out one minute in when there is still no heart rate, and is decided separately from on", async () => {
    const p = push();
    const w = await world();
    seedHr(w.raw, S - 120_000 - 20_000); // live at the on check
    const f = ok200();
    await p.runPushTick(w.env, S - 120_000, f.impl);
    assert.equal(f.calls.length, 0);
    assert.equal(w.kv.store.get(`push:done:on:${S}`), "live");
    const r = await p.runPushTick(w.env, S + 60_000, f.impl);
    assert.equal(r.sent.length, 1, "the strap dropped, so the follow-up still goes");
    const call = f.calls[0];
    assert.equal(call.body.aps.alert.title, "Still no heart rate");
    assert.equal(
      normalizeSpaces(call.body.aps.alert.body),
      "Your 2:30 PM meeting has started and no heart rate is coming in. Turn on HR Broadcast in the WHOOP app.",
    );
    assert.equal(call.body.aps["interruption-level"], "time-sensitive");
    assert.equal(call.headers.get("apns-collapse-id"), `meetspike.broadcast.followUp.${S}`);
    assert.equal(call.headers.get("apns-expiration"), String((S + 10 * MIN) / 1000), "start + 10 minutes");
    assert.equal(w.kv.store.get(`push:done:followUp:${S}`), "sent");
    await p.runPushTick(w.env, S + 90_000, f.impl);
    assert.equal(f.calls.length, 1);
  });

  it("followUp is skipped, and final, when heart rate arrived", async () => {
    const p = push();
    const w = await world();
    seedHr(w.raw, S + 50_000);
    const f = ok200();
    await p.runPushTick(w.env, S + 60_000, f.impl);
    assert.equal(f.calls.length, 0);
    assert.equal(w.kv.store.get(`push:done:followUp:${S}`), "live");
  });

  it("a failed send is not recorded, so the next tick in the window retries", async () => {
    const p = push();
    const w = await world();
    const f = stubFetch((_c, n) => (n === 1 ? { status: 500, body: { reason: "InternalServerError" } } : { status: 200 }));
    const first = await p.runPushTick(w.env, S - 120_000, f.impl);
    assert.deepEqual(first.sent, []);
    assert.deepEqual(doneKeys(w.kv), [], "failed is not a decision");
    const second = await p.runPushTick(w.env, S - 60_000, f.impl);
    assert.equal(second.sent.length, 1);
    assert.equal(f.calls.length, 2);
    assert.equal(w.kv.store.get(`push:done:on:${S}`), "sent");
  });

  it("a network error also retries next tick and nothing throws", async () => {
    const p = push();
    const w = await world();
    const f = stubFetch((_c, n) => (n === 1 ? new Error("offline") : { status: 200 }));
    await assert.doesNotReject(() => p.runPushTick(w.env, S - 120_000, f.impl));
    assert.deepEqual(doneKeys(w.kv), []);
    assert.equal((await p.runPushTick(w.env, S - 100_000, f.impl)).sent.length, 1);
  });

  it("a heartRateLive error sends nothing and decides nothing", async () => {
    const p = push();
    const w = await world();
    w.spy.state.failHr = true;
    const f = ok200();
    const r = await p.runPushTick(w.env, S - 120_000, f.impl);
    assert.deepEqual(r.sent, []);
    assert.equal(f.calls.length, 0, "never push without knowing");
    assert.deepEqual(doneKeys(w.kv), []);
    w.spy.state.failHr = false;
    assert.equal((await p.runPushTick(w.env, S - 90_000, f.impl)).sent.length, 1, "and the next tick decides");
  });

  it("a gone device is cleared and the tick stops", async () => {
    const p = push();
    // At S: "a" starts in 90 s (on is due) and "b" started 90 s ago (followUp is due).
    const w = await world({ meetings: [{ id: "a", start: S + 90_000, end: E }, { id: "b", start: S - 90_000, end: E }] });
    const f = stubFetch(() => ({ status: 410, body: { reason: "Unregistered" } }));
    const r = await p.runPushTick(w.env, S, f.impl);
    assert.deepEqual(r.sent, []);
    assert.equal(f.calls.length, 1, "no more sends once Apple says the token is gone");
    assert.equal(w.kv.store.has(DEVICE_KEY), false, "device cleared");
    assert.equal(doneKeys(w.kv).some((k) => w.kv.store.get(k) === "sent"), false);
  });

  it("two due pushes in one tick read heartRateLive once", async () => {
    const p = push();
    const w = await world({ meetings: [{ id: "a", start: S + 90_000, end: E }, { id: "b", start: S - 90_000, end: E }] });
    const f = ok200();
    const r = await p.runPushTick(w.env, S, f.impl);
    assert.equal(r.sent.length, 2, "on for a, followUp for b");
    assert.equal(w.spy.hrQueries(), 1, "one query for the 60 s window");
    const titles = f.calls.map((c) => c.body.aps.alert.title).sort();
    assert.deepEqual(titles, ["Still no heart rate", "Turn on HR Broadcast in the WHOOP app"]);
  });

  describe("off", () => {
    const meeting = [{ id: "m1", start: S, end: E }];
    it("sends only when heart rate is still coming in, and says so", async () => {
      const p = push();
      const w = await world({ meetings: meeting });
      const now = E + 570_000;
      seedHr(w.raw, now - 30_000);
      const f = ok200();
      const r = await p.runPushTick(w.env, now, f.impl);
      assert.equal(r.sent.length, 1);
      const call = f.calls[0];
      assert.equal(call.body.aps.alert.title, "You can turn off HR Broadcast");
      assert.equal(normalizeSpaces(call.body.aps.alert.body), "Your 2:30 PM meeting is over and heart rate is still coming in.");
      assert.equal(call.body.aps.sound, "default");
      assert.equal(call.body.aps["thread-id"], "meetspike.broadcast");
      assert.equal(call.body.aps["interruption-level"], undefined, "not time-sensitive");
      assert.equal(call.headers.get("apns-collapse-id"), `meetspike.broadcast.off.${E}`);
      assert.equal(call.headers.get("apns-expiration"), String((now + 30 * MIN) / 1000), "now + 30 minutes");
      assert.equal(w.kv.store.get(`push:done:off:${E}`), "sent");
      await p.runPushTick(w.env, now + 20_000, f.impl);
      assert.equal(f.calls.length, 1, "once");
    });

    it("heart rate gone: nothing is sent and the decision is final (quiet)", async () => {
      const p = push();
      const w = await world({ meetings: meeting });
      const now = E + 570_000;
      const f = ok200();
      const r = await p.runPushTick(w.env, now, f.impl);
      assert.deepEqual(r.sent, []);
      assert.equal(f.calls.length, 0);
      assert.equal(w.kv.store.get(`push:done:off:${E}`), "quiet");
      seedHr(w.raw, now + 5_000);
      await p.runPushTick(w.env, now + 10_000, f.impl);
      assert.equal(f.calls.length, 0, "final");
    });

    it("uses a 90 s window for off, and ignores codebox rows", async () => {
      const p = push();
      const now = E + 570_000;
      const live = await world({ meetings: meeting });
      seedHr(live.raw, now - 89_000);
      const f1 = ok200();
      assert.equal((await p.runPushTick(live.env, now, f1.impl)).sent.length, 1, "89 s old counts for off");
      const stale = await world({ meetings: meeting });
      seedHr(stale.raw, now - 91_000);
      const f2 = ok200();
      assert.equal((await p.runPushTick(stale.env, now, f2.impl)).sent.length, 0, "91 s old does not");
      const codebox = await world({ meetings: meeting });
      seedHr(codebox.raw, now - 5_000, "codebox");
      const f3 = ok200();
      assert.equal((await p.runPushTick(codebox.env, now, f3.impl)).sent.length, 0);
    });

    it("only runs in its window: 540 s to 600 s after the end", async () => {
      const p = push();
      const w = await world({ meetings: meeting });
      seedHr(w.raw, E + 540_000 - 1_000);
      const f = ok200();
      await p.runPushTick(w.env, E + 539_000, f.impl);
      assert.equal(f.calls.length, 0);
      assert.equal(doneKeys(w.kv).length, 0, "too early, nothing decided");
      await p.runPushTick(w.env, E + 600_000, f.impl);
      assert.equal(f.calls.length, 0);
      assert.equal(doneKeys(w.kv).length, 0, "too late, nothing decided");
    });

    it("waits when the next covered meeting is close, and for a meeting the phone has no end for", async () => {
      const p = push();
      const now = E + 570_000;
      const close = await world({ meetings: [...meeting, { id: "m2", start: now + 10 * MIN, end: now + 40 * MIN }] });
      seedHr(close.raw, now - 5_000);
      const f = ok200();
      await p.runPushTick(close.env, now, f.impl);
      assert.equal(f.calls.length, 0, "the next meeting's listening would overlap");
      const far = await world({ meetings: [...meeting, { id: "m2", start: now + 20 * MIN, end: now + 50 * MIN }] });
      seedHr(far.raw, now - 5_000);
      const f2 = ok200();
      assert.equal((await p.runPushTick(far.env, now, f2.impl)).sent.length, 1);
      const unmatched = await world({ meetings: meeting, covered: [S] });
      const f3 = ok200();
      seedHr(unmatched.raw, now - 5_000);
      unmatched.raw.prepare(`DELETE FROM calendar_event`).run();
      await p.runPushTick(unmatched.env, now, f3.impl);
      assert.equal(f3.calls.length, 0, "an unmatched covered meeting has no end, so no off push");
    });
  });

  describe("which meetings get a push", () => {
    it("a meeting the owner left out gets nothing, and is not treated as unmatched", async () => {
      const p = push();
      const w = await world();
      w.raw.prepare(`INSERT INTO meeting_override (key, state, updated_at) VALUES ('event:m1', 'not_joined', 't')`).run();
      const f = ok200();
      for (const t of [S - 120_000, S - 60_000, S + 60_000, S + 120_000, E + 570_000]) await p.runPushTick(w.env, t, f.impl);
      assert.equal(f.calls.length, 0);
      assert.deepEqual(doneKeys(w.kv), []);
    });

    it("the same for a meeting marked not linked", async () => {
      const p = push();
      const w = await world();
      w.raw.prepare(`INSERT INTO meeting_override (key, state, updated_at) VALUES ('event:m1', 'unlinked', 't')`).run();
      const f = ok200();
      await p.runPushTick(w.env, S - 60_000, f.impl);
      assert.equal(f.calls.length, 0);
    });

    it("a left-out series leaves out its meetings", async () => {
      const p = push();
      const w = await world({ meetings: [{ id: "series1_20261120T193000Z", start: S, end: E }] });
      w.raw.prepare(`INSERT INTO meeting_override (key, state, updated_at) VALUES ('series:series1', 'not_joined', 't')`).run();
      const f = ok200();
      await p.runPushTick(w.env, S - 60_000, f.impl);
      assert.equal(f.calls.length, 0);
    });

    it("a deleted calendar meeting gets nothing", async () => {
      const p = push();
      const w = await world();
      w.raw.prepare(`UPDATE calendar_event SET deleted_at = '2026-11-20T10:00:00.000Z' WHERE id = 'm1'`).run();
      const f = ok200();
      await p.runPushTick(w.env, S - 60_000, f.impl);
      await p.runPushTick(w.env, S + 90_000, f.impl);
      assert.equal(f.calls.length, 0, "not treated as unmatched either");
    });

    it("a covered meeting the Worker has no calendar row for still gets on and followUp", async () => {
      const p = push();
      const w = await world({ meetings: [], covered: [S] });
      const f = ok200();
      assert.equal((await p.runPushTick(w.env, S - 60_000, f.impl)).sent.length, 1);
      assert.equal(f.calls[0].headers.get("apns-collapse-id"), `meetspike.broadcast.on.${S}`);
      assert.equal(normalizeSpaces(f.calls[0].body.aps.alert.body).startsWith("Your 2:30 PM meeting starts in 1 minute"), true);
      assert.equal((await p.runPushTick(w.env, S + 60_000, f.impl)).sent.length, 1);
      assert.equal(f.calls[1].body.aps.alert.title, "Still no heart rate");
    });

    it("a calendar row the phone did not cover is not reminded about", async () => {
      const p = push();
      const w = await world({ meetings: [{ id: "m1", start: S, end: E }, { id: "other", start: S + 5 * MIN, end: E }], covered: [S] });
      const f = ok200();
      await p.runPushTick(w.env, S + 5 * MIN - 60_000, f.impl);
      assert.equal(f.calls.length, 0, "only the phone's covered starts are candidates");
    });

    it("two calendar meetings at one start give one push", async () => {
      const p = push();
      const w = await world({ meetings: [{ id: "a", start: S, end: E }, { id: "b", start: S, end: E + 15 * MIN }] });
      const f = ok200();
      await p.runPushTick(w.env, S - 90_000, f.impl);
      await p.runPushTick(w.env, S - 60_000, f.impl);
      assert.equal(f.calls.length, 1);
    });

    it("uses the owner's changed times, not the calendar's", async () => {
      const p = push();
      const w = await world();
      w.raw
        .prepare(`INSERT INTO meeting_override (key, state, start_utc, end_utc, updated_at) VALUES ('event:m1', NULL, ?, ?, 't')`)
        .run(new Date(S + 10 * MIN).toISOString(), new Date(E + 10 * MIN).toISOString());
      const f = ok200();
      await p.runPushTick(w.env, S - 60_000, f.impl);
      assert.equal(f.calls.length, 0, "the calendar start is not the start any more");
      const r = await p.runPushTick(w.env, S + 10 * MIN - 90_000, f.impl);
      assert.equal(r.sent.length, 1);
      assert.equal(f.calls[0].headers.get("apns-collapse-id"), `meetspike.broadcast.on.${S + 10 * MIN}`);
      assert.match(normalizeSpaces(f.calls[0].body.aps.alert.body), /^Your 2:40 PM meeting starts in 2 minutes/);
    });

    it("matches the phone's covered start within 90 s", async () => {
      const p = push();
      const w = await world({ meetings: [{ id: "m1", start: S + 45_000, end: E }], covered: [S] });
      const f = ok200();
      await p.runPushTick(w.env, S + 45_000 - 60_000, f.impl);
      assert.equal(f.calls.length, 1);
      assert.equal(f.calls[0].headers.get("apns-collapse-id"), `meetspike.broadcast.on.${S + 45_000}`);
    });
  });

  describe("quiet when there is nothing to do", () => {
    it("idle ticks make no D1 query: no APNs configuration, no device, nothing within range", async () => {
      const p = push();
      const f = ok200();
      const noConfig = await world({ env: { APNS_KEY_P8: undefined } });
      assert.deepEqual((await p.runPushTick(noConfig.env, S - 120_000, f.impl)).sent, []);
      assert.equal(noConfig.spy.queries.length, 0, "no config");
      const noDevice = await world({ device: false });
      await p.runPushTick(noDevice.env, S - 120_000, f.impl);
      assert.equal(noDevice.spy.queries.length, 0, "no device");
      const far = await world({ meetings: [{ id: "m1", start: S + 5 * HOUR, end: S + 6 * HOUR }] });
      await p.runPushTick(far.env, S, f.impl);
      assert.equal(far.spy.queries.length, 0, "next covered start is more than 3 h away");
      const old = await world({ meetings: [{ id: "m1", start: S - 20 * HOUR, end: S - 19 * HOUR }] });
      await p.runPushTick(old.env, S, f.impl);
      assert.equal(old.spy.queries.length, 0, "the last covered start is more than 16 h ago");
      assert.equal(f.calls.length, 0);
    });

    it("no heart rate query when nothing is due", async () => {
      const p = push();
      const w = await world();
      const f = ok200();
      await p.runPushTick(w.env, S - 10 * MIN, f.impl);
      assert.equal(w.spy.hrQueries(), 0);
      assert.equal(f.calls.length, 0);
    });

    it("works with an old check-in format (a bare ISO time covers nothing)", async () => {
      const p = push();
      const w = await world();
      w.kv.store.set(OWNER_KEY, new Date(S - HOUR).toISOString());
      const f = ok200();
      const r = await p.runPushTick(w.env, S - 60_000, f.impl);
      assert.deepEqual(r.sent, []);
      assert.equal(f.calls.length, 0);
      assert.equal(w.spy.queries.length, 0);
    });

    it("no check-in, or a lapsed one, sends nothing", async () => {
      const p = push();
      const none = await world();
      none.kv.store.delete(OWNER_KEY);
      const f = ok200();
      await p.runPushTick(none.env, S - 60_000, f.impl);
      const lapsed = await world({ checkInAt: S - 8 * 24 * HOUR });
      await p.runPushTick(lapsed.env, S - 60_000, f.impl);
      assert.equal(f.calls.length, 0, "the Mac reminds when the phone's check-in lapses");
    });

    it("WHOOP web heart rate off: skipped", async () => {
      const p = push();
      const w = await world({ env: { WHOOP_WEB_HR: "off" } });
      const f = ok200();
      const r = await p.runPushTick(w.env, S - 60_000, f.impl);
      assert.deepEqual(r.sent, []);
      assert.equal(typeof r.skipped, "string");
      assert.equal(f.calls.length, 0);
    });

    it("never throws, whatever breaks", async () => {
      const p = push();
      const w = await world();
      const throwingKv = new Proxy({}, { get: () => async () => { throw new Error("kv down"); } });
      const brokenDb = { prepare: () => { throw new Error("db down"); } };
      const f = ok200();
      await assert.doesNotReject(() => p.runPushTick({ ...(w.env as object), TOKENS: throwingKv } as never, S - 60_000, f.impl));
      await assert.doesNotReject(() => p.runPushTick({ ...(w.env as object), DB: brokenDb } as never, S - 60_000, f.impl));
      await assert.doesNotReject(() => p.runPushTick({} as never, S - 60_000, f.impl));
      assert.equal(f.calls.length, 0);
    });
  });

  describe("privacy", () => {
    it("no meeting title and no heart rate is in any payload, and the log lines carry no meeting data", async () => {
      const p = push();
      const out = logs();
      const w = await world();
      const f = ok200();
      seedHr(w.raw, E + 570_000 - 5_000, "ble", "owner", 173);
      await p.runPushTick(w.env, S - 120_000 + 0, f.impl);
      await p.runPushTick(w.env, S + 60_000, f.impl);
      await p.runPushTick(w.env, E + 570_000, f.impl);
      out.stop();
      assert.equal(f.calls.length, 3, "on, followUp and off");
      for (const call of f.calls) {
        const text = JSON.stringify(call.body);
        assert.ok(!text.includes("Secret"), text);
        assert.ok(!text.includes(TITLE), text);
        assert.ok(!/173|bpm/i.test(text), text);
        assert.ok(!text.includes("m1"), "no meeting id");
      }
      const decisions = out.lines.filter((l) => l.includes("push_reminder")).map((l) => JSON.parse(l));
      assert.equal(decisions.length, 3, "one line per decision");
      for (const d of decisions) {
        assert.deepEqual(Object.keys(d).sort(), ["event", "kind", "result"], JSON.stringify(d));
        assert.equal(d.event, "push_reminder");
        assert.ok(["on", "followUp", "off"].includes(d.kind));
        assert.equal(typeof d.result, "string");
      }
      assert.deepEqual(decisions.map((d) => d.kind), ["on", "followUp", "off"]);
      const everything = out.lines.join("\n");
      for (const secret of [TOKEN, TITLE, "m1", KEY.b64.slice(20, 80), "BEGIN PRIVATE KEY", SECRET]) assert.ok(!everything.includes(secret), `log has ${secret.slice(0, 12)}`);
      assert.ok(!/eyJ[A-Za-z0-9_-]+\./.test(everything), "no JWT in logs");
    });
  });
});

// ---------------------------------------------------------------------------------------------------------------
describe("push: routes", () => {
  const auth = { authorization: `Bearer ${SECRET}`, "content-type": "application/json" };
  function routeEnv(extra: Record<string, unknown> = {}) {
    const { db, raw } = sqliteD1();
    const spy = spyDb(db);
    const kv = recKv();
    return { raw, kv, spy, env: { DB: spy.db, TOKENS: kv, INGEST_ADMIN_SECRET: SECRET, ...pushEnv(), ...extra } as never };
  }
  const post = (env: never, body: unknown) =>
    api.request("https://app.example/whoop-web/reminder/owner", { method: "POST", body: JSON.stringify(body), headers: auth }, env);
  const get = (env: never) => api.request("https://app.example/whoop-web/reminder", { headers: auth }, env);
  const startIso = new Date(Math.floor((Date.now() + 3 * HOUR) / 1000) * 1000).toISOString();
  const storedDevice = (kv: { store: Map<string, string> }) => {
    const v = kv.store.get(DEVICE_KEY);
    return v ? JSON.parse(v) : null;
  };
  const withApns = (status = 200) => {
    const f = stubFetch(() => ({ status, body: status === 200 ? undefined : { reason: status === 410 ? "Unregistered" : "InternalServerError" } }));
    globalThis.fetch = f.impl;
    return f;
  };

  it("owner check-in with a valid push registers the device and answers push true", async () => {
    const w = routeEnv();
    const f = withApns();
    const out = logs();
    const res = await post(w.env, { active: true, covered: [startIso], push: { token: TOKEN.toUpperCase(), environment: "development" } });
    out.stop();
    assert.equal(res.status, 200);
    const body = (await res.json()) as Record<string, any>;
    assert.equal(body.ok, true);
    assert.equal(body.owner, "phone");
    assert.equal(body.covered, 1);
    assert.equal(body.push, true);
    assert.equal(f.calls.length, 1);
    assert.ok(f.calls[0].url.startsWith(`https://api.sandbox.push.apple.com/3/device/${TOKEN}`), "lowercased, sandbox for development");
    const device = storedDevice(w.kv);
    assert.equal(device.token, TOKEN);
    assert.equal(device.environment, "development");
    const audit = out.lines.filter((l) => l.includes("reminder_owner")).map((l) => JSON.parse(l));
    assert.deepEqual(audit, [{ event: "reminder_owner", owner: "phone", covered: 1, push: true }], "the push boolean only");
    assert.ok(!out.lines.join("\n").includes(TOKEN), "no device token in logs");
  });

  it("a second check-in with the same token inside 24 h does not send again", async () => {
    const w = routeEnv();
    const f = withApns();
    const push1 = { token: TOKEN, environment: "production" };
    await post(w.env, { active: true, covered: [startIso], push: push1 });
    const again = (await (await post(w.env, { active: true, covered: [startIso], push: push1 })).json()) as Record<string, any>;
    assert.equal(again.push, true);
    assert.equal(f.calls.length, 1);
  });

  it("without push the device is cleared and the reply says push false", async () => {
    const w = routeEnv();
    withApns();
    await post(w.env, { active: true, covered: [startIso], push: { token: TOKEN, environment: "production" } });
    assert.ok(storedDevice(w.kv));
    const f = withApns();
    const res = await post(w.env, { active: true, covered: [startIso] });
    assert.equal(res.status, 200);
    const body = (await res.json()) as Record<string, any>;
    assert.equal(body.push, false, "an old build posts no push key");
    assert.equal(body.owner, "phone", "and still owns local reminders");
    assert.equal(storedDevice(w.kv), null);
    assert.equal(f.calls.length, 0);
  });

  it("active false clears the device even when push is sent", async () => {
    const w = routeEnv();
    withApns();
    await post(w.env, { active: true, covered: [startIso], push: { token: TOKEN, environment: "production" } });
    const f = withApns();
    const res = await post(w.env, { active: false, push: { token: TOKEN, environment: "production" } });
    assert.equal(res.status, 200);
    const body = (await res.json()) as Record<string, any>;
    assert.equal(body.push, false);
    assert.equal(body.owner, "mac");
    assert.equal(storedDevice(w.kv), null);
    assert.equal(f.calls.length, 0, "stepping down sends nothing to Apple");
  });

  it("an invalid push is 400 before anything is stored", async () => {
    const w = routeEnv();
    withApns();
    await post(w.env, { active: true, covered: [startIso], push: { token: TOKEN, environment: "production" } });
    const checkIn = w.kv.store.get(OWNER_KEY);
    const device = w.kv.store.get(DEVICE_KEY);
    const putsBefore = w.kv.puts.length;
    const f = withApns();
    for (const bad of [
      { token: "xyz", environment: "production" },
      { token: TOKEN, environment: "staging" },
      { token: "a".repeat(201), environment: "production" },
      "token",
      null,
      [],
      { environment: "production" },
    ]) {
      const res = await post(w.env, { active: true, covered: [new Date(Date.parse(startIso) + HOUR).toISOString()], push: bad });
      assert.equal(res.status, 400, JSON.stringify(bad));
      assert.deepEqual(await res.json(), { error: "Send push as a device token and environment." });
    }
    assert.equal(w.kv.store.get(OWNER_KEY), checkIn, "the check-in is untouched");
    assert.equal(w.kv.store.get(DEVICE_KEY), device, "the device is untouched");
    assert.equal(w.kv.puts.length, putsBefore, "nothing written");
    assert.equal(f.calls.length, 0);
  });

  it("APNs not configured, rejecting or unreachable: push false, check-in still stored", async () => {
    const notConfigured = routeEnv({ APNS_KEY_P8: undefined });
    const f0 = withApns();
    const res0 = await post(notConfigured.env, { active: true, covered: [startIso], push: { token: TOKEN, environment: "production" } });
    assert.equal(res0.status, 200);
    const body0 = (await res0.json()) as Record<string, any>;
    assert.equal(body0.push, false);
    assert.equal(body0.owner, "phone");
    assert.equal(f0.calls.length, 0);
    assert.equal(storedDevice(notConfigured.kv), null);

    const rejected = routeEnv();
    withApns(410);
    const body1 = (await (await post(rejected.env, { active: true, covered: [startIso], push: { token: TOKEN, environment: "production" } })).json()) as Record<string, any>;
    assert.equal(body1.push, false);
    assert.equal(body1.owner, "phone");
    assert.equal(storedDevice(rejected.kv), null);

    const down = routeEnv();
    globalThis.fetch = (async () => { throw new Error("offline"); }) as typeof fetch;
    const body2 = (await (await post(down.env, { active: true, covered: [startIso], push: { token: TOKEN, environment: "production" } })).json()) as Record<string, any>;
    assert.equal(body2.push, false);
  });

  it("60 covered starts and a 200 character token fit in one request", async () => {
    const w = routeEnv();
    withApns();
    const covered = Array.from({ length: 60 }, (_, i) => new Date(Date.parse(startIso) + i * HOUR).toISOString());
    const res = await post(w.env, { active: true, covered, push: { token: "a".repeat(200), environment: "production" } });
    assert.equal(res.status, 200);
    const body = (await res.json()) as Record<string, any>;
    assert.equal(body.covered, 60);
    assert.equal(body.push, true);
  });

  it("the owner route still needs the ingest secret and an active boolean", async () => {
    const w = routeEnv();
    const noAuth = await api.request("https://app.example/whoop-web/reminder/owner", { method: "POST", body: JSON.stringify({ active: true }), headers: { "content-type": "application/json" } }, w.env);
    assert.equal(noAuth.status, 401);
    assert.equal((await post(w.env, { push: { token: TOKEN, environment: "production" } })).status, 400);
  });

  it("GET reminder says live true or false from the owner's recent heart rate, other fields unchanged", async () => {
    const w = routeEnv();
    const start = Math.floor((Date.now() + 60_000) / 1000) * 1000;
    insertMeeting(w.raw, "soon", start, start + 30 * MIN);
    let body = (await (await get(w.env)).json()) as Record<string, any>;
    assert.equal(body.live, false);
    assert.equal(body.meeting.id, "soon");
    assert.equal(body.pushover, false);
    assert.equal(body.owner, "mac");
    assert.ok("ownerUntil" in body);
    seedHr(w.raw, Date.now() - 5_000);
    body = (await (await get(w.env)).json()) as Record<string, any>;
    assert.equal(body.live, true);
    assert.equal(body.meeting.id, "soon");
  });

  it("GET reminder says live null when the check failed, and still answers", async () => {
    const w = routeEnv();
    const start = Math.floor((Date.now() + 60_000) / 1000) * 1000;
    insertMeeting(w.raw, "soon", start, start + 30 * MIN);
    w.spy.state.failHr = true;
    const res = await get(w.env);
    assert.equal(res.status, 200);
    const body = (await res.json()) as Record<string, any>;
    assert.equal(body.live, null);
    assert.equal(body.meeting.id, "soon");
    assert.equal(body.ok, true);
  });

  it("codebox rows do not make GET live", async () => {
    const w = routeEnv();
    seedHr(w.raw, Date.now() - 5_000, "codebox");
    assert.equal(((await (await get(w.env)).json()) as Record<string, any>).live, false);
  });

  describe("POST reminder (Pushover)", () => {
    const pushoverEnv = { PUSHOVER_TOKEN: "tok", PUSHOVER_USER: "usr" };
    const postPushover = (env: never) =>
      api.request("https://app.example/whoop-web/reminder", { method: "POST", body: JSON.stringify({ title: "Weekly sync" }), headers: auth }, env);

    it("answers live and sends nothing while heart rate is coming in", async () => {
      const w = routeEnv(pushoverEnv);
      seedHr(w.raw, Date.now() - 5_000);
      const f = stubFetch(() => ({ status: 200 }));
      globalThis.fetch = f.impl;
      const res = await postPushover(w.env);
      assert.equal(res.status, 200);
      assert.deepEqual(await res.json(), { ok: true, pushover: "live" });
      assert.equal(f.calls.length, 0, "no Pushover request");
    });

    it("sends as today when heart rate is not coming in", async () => {
      const w = routeEnv(pushoverEnv);
      const f = stubFetch(() => ({ status: 200 }));
      globalThis.fetch = f.impl;
      const res = await postPushover(w.env);
      assert.equal(res.status, 200);
      assert.deepEqual(await res.json(), { ok: true, pushover: "sent" });
      assert.equal(f.calls.length, 1);
      assert.equal(f.calls[0].url, "https://api.pushover.net/1/messages.json");
    });

    it("sends as today when the heart rate check fails", async () => {
      const w = routeEnv(pushoverEnv);
      w.spy.state.failHr = true;
      const f = stubFetch(() => ({ status: 200 }));
      globalThis.fetch = f.impl;
      const res = await postPushover(w.env);
      assert.equal(res.status, 200);
      assert.deepEqual(await res.json(), { ok: true, pushover: "sent" });
      assert.equal(f.calls.length, 1);
    });

    it("still answers not_configured without Pushover secrets when not live", async () => {
      const w = routeEnv();
      const res = await postPushover(w.env);
      assert.deepEqual(await res.json(), { ok: true, pushover: "not_configured" });
    });
  });
});

// ---------------------------------------------------------------------------------------------------------------
describe("push: scheduled() routes by cron", () => {
  type Worker = { scheduled: (c: unknown, env: unknown, ctx: unknown) => unknown };
  let worker: Worker | null = null;
  async function loadWorker(): Promise<Worker> {
    if (worker) return worker;
    // src/index.ts imports the Workflows runtime module, which only exists in workerd. Stub that one specifier.
    register(
      "data:text/javascript," +
        encodeURIComponent(
          `export async function resolve(s, c, n) { if (s === "cloudflare:workers") return { url: "data:text/javascript,export class WorkflowEntrypoint {}", shortCircuit: true }; return n(s, c); }`,
        ),
      import.meta.url,
    );
    worker = (await import("../src/index.ts")).default as never;
    return worker;
  }

  async function run(cron: string | undefined, w: Awaited<ReturnType<typeof world>>, now: number) {
    const f = stubFetch(() => ({ status: 200 }));
    globalThis.fetch = f.impl;
    const pending: Array<Promise<unknown>> = [];
    const ctx = { waitUntil: (p: Promise<unknown>) => void pending.push(Promise.resolve(p)), passThroughOnException: () => {} };
    const out = logs();
    const returned = (await loadWorker()).scheduled({ cron, scheduledTime: now, type: "scheduled" }, w.env, ctx);
    await Promise.allSettled([...pending, Promise.resolve(returned)]);
    out.stop();
    return { calls: f.calls, waitUntils: pending.length };
  }

  it("the every-minute cron runs only the push tick, with the cron's scheduled time", async () => {
    const w = await world();
    const r = await run("* * * * *", w, S - 120_000);
    const apns = r.calls.filter((c) => c.url.startsWith("https://api.push.apple.com/"));
    assert.equal(apns.length, 1, "the push tick ran at the controller's scheduledTime");
    assert.equal(r.calls.length, apns.length, "no other job made a request");
    assert.ok(r.waitUntils <= 1, `only one job was started, got ${r.waitUntils}`);
    assert.equal(w.kv.store.get(`push:done:on:${S}`), "sent");
  });

  it("the 15-minute cron runs the existing four jobs and no push tick", async () => {
    const w = await world();
    const r = await run("*/15 * * * *", w, S - 120_000);
    assert.equal(r.waitUntils, 4, "calendar sync, WHOOP recent, WHOOP web fill, Oura recent");
    assert.equal(r.calls.filter((c) => c.url.includes("apple.com")).length, 0, "no push from the 15-minute tick");
    assert.deepEqual(doneKeys(w.kv), []);
  });

  it("any other cron string runs the existing four jobs", async () => {
    const w = await world();
    const r = await run("0 6 * * *", w, S - 120_000);
    assert.equal(r.waitUntils, 4);
    assert.equal(r.calls.filter((c) => c.url.includes("apple.com")).length, 0);
  });
});
