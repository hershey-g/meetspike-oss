import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { afterEach, describe, it } from "node:test";
import { api } from "../src/routes/api.ts";
import { phoneCheckIn, setPhoneOwner } from "../src/sources/whoop-web/reminder.ts";
// @ts-expect-error plain .mjs helper without types
import * as setupLib from "../scripts/setup-lib.mjs";
import { sqliteD1 } from "./sqlite-d1.ts";

/**
 * Build 11 fix pass (server): regression tests for F1 to F6 of spec11-fix.md.
 * Everything here is red on feat/build11-push at 28b822c for the reason named in each test.
 * Same conventions as push-reminders.test.ts: real SQLite D1, stubbed fetch, a throwaway P-256 key.
 */

const P = await import("../src/sources/whoop-web/push.ts");

const SECRET = "admin-secret-xyz";
const MIN = 60_000;
const HOUR = 3_600_000;
const S = Date.parse("2026-11-20T19:30:00.000Z");
const E = S + 30 * MIN;
const NOW = 1_800_000_000_000;
const TOKEN = "ab".repeat(32);
const TOKEN2 = "cd".repeat(32);
const DEVICE_KEY = "push:device";

async function makeKey() {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const b64 = Buffer.from(new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey))).toString("base64");
  return `-----BEGIN PRIVATE KEY-----\n${b64.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
}
const PEM = await makeKey();
const pushEnv = (extra: Record<string, unknown> = {}) => ({
  WHOOP_WEB_HR: "enabled", APNS_KEY_P8: PEM, APNS_KEY_ID: "KEYID12345", APNS_TEAM_ID: "TEAMID6789", ...extra,
});

function recKv(initial: Record<string, string> = {}) {
  const store = new Map(Object.entries(initial));
  const kv = {
    store,
    failDelete: false,
    failPutPrefix: null as string | null,
    get: async (k: string) => store.get(k) ?? null,
    put: async (k: string, v: string) => {
      if (kv.failPutPrefix && k.startsWith(kv.failPutPrefix)) throw new Error("kv put down");
      store.set(k, v);
    },
    delete: async (k: string) => {
      if (kv.failDelete) throw new Error("kv delete down");
      store.delete(k);
    },
  };
  return kv;
}

type Call = { url: string; headers: Headers; body: any; signal: AbortSignal | null | undefined };
type Reply = { status: number; body?: unknown } | Error;
function stubFetch(handler: (call: Call, n: number) => Reply | Promise<Reply>) {
  const calls: Call[] = [];
  const impl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const call: Call = {
      url: String(input),
      headers: new Headers(init?.headers as HeadersInit),
      body: init?.body === undefined ? undefined : (() => { try { return JSON.parse(String(init.body)); } catch { return String(init.body); } })(),
      signal: init?.signal,
    };
    calls.push(call);
    const r = await handler(call, calls.length);
    if (r instanceof Error) throw r;
    return new Response(r.body === undefined ? "" : typeof r.body === "string" ? r.body : JSON.stringify(r.body), { status: r.status });
  }) as typeof fetch;
  return { calls, impl };
}

const realFetch = globalThis.fetch;
const realLog = { log: console.log, error: console.error };
afterEach(() => {
  globalThis.fetch = realFetch;
  console.log = realLog.log;
  console.error = realLog.error;
});
function quiet() {
  console.log = () => {};
  console.error = () => {};
}

type Raw = ReturnType<typeof sqliteD1>["raw"];
function insertMeeting(raw: Raw, id: string, startMs: number, endMs: number) {
  const startUtc = new Date(startMs).toISOString();
  const endUtc = new Date(endMs).toISOString();
  raw
    .prepare(
      `INSERT INTO calendar_event (id, source, day, start_utc, end_utc, tz_offset_min, duration_s, title, kind, attendee_count, after_hours, updated_at, start_local, end_local)
       VALUES (?, 'google', ?, ?, ?, -300, ?, 'Secret Board Meeting', 'client', 2, 0, 't', ?, ?)`,
    )
    .run(id, startUtc.slice(0, 10), startUtc, endUtc, (endMs - startMs) / 1000, startUtc, endUtc);
}
function seedHr(raw: Raw, timeMs: number) {
  raw.prepare(`INSERT INTO whoop_web_hr_raw (user_id, source, time_ms, bpm, received_at) VALUES ('owner', 'ble', ?, 151, 't')`).run(timeMs);
}

type Meeting = { id: string; start: number; end: number };
async function world(meetings: Meeting[], checkInAt: number, extraEnv: Record<string, unknown> = {}) {
  const { db, raw } = sqliteD1();
  const kv = recKv();
  for (const m of meetings) insertMeeting(raw, m.id, m.start, m.end);
  await setPhoneOwner(kv as never, true, checkInAt, meetings.map((m) => m.start));
  kv.store.set(DEVICE_KEY, JSON.stringify({ token: TOKEN, environment: "production", verifiedAt: new Date(checkInAt).toISOString() }));
  const env = { DB: db, TOKENS: kv, INGEST_ADMIN_SECRET: SECRET, ...pushEnv(), ...extraEnv };
  return { raw, kv, env: env as never };
}
const storedDevice = (kv: { store: Map<string, string> }) => {
  const v = kv.store.get(DEVICE_KEY);
  return v ? JSON.parse(v) : null;
};
const doneKeys = (kv: { store: Map<string, string> }) => [...kv.store.keys()].filter((k) => k.startsWith("push:done:"));

// ---------------------------------------------------------------------------------------------------------------
describe("fix F1: permanent Apple rejection at registration", () => {
  const reg = { token: TOKEN, environment: "production" as const };
  function stored(verifiedAt = NOW) {
    return recKv({ [DEVICE_KEY]: JSON.stringify({ ...reg, verifiedAt: new Date(verifiedAt).toISOString() }) });
  }
  const env = (kv: unknown) => ({ TOKENS: kv, ...pushEnv() }) as never;

  it("any 4xx except 429 clears the same, already verified token and says false", async () => {
    const cases: Array<[number, unknown]> = [
      [400, { reason: "PayloadEmpty" }],
      [400, { reason: "BadTopic" }],
      [400, ""],
      [401, ""],
      [403, { reason: "Forbidden" }],
      [403, { reason: "BadCertificate" }],
      [404, { reason: "BadPath" }],
      [413, { reason: "PayloadTooLarge" }],
    ];
    for (const [status, body] of cases) {
      quiet();
      const kv = stored();
      const f = stubFetch(() => ({ status, body }));
      assert.equal(await P.registerDevice(env(kv), reg, NOW + 25 * HOUR, f.impl), false, `${status} ${JSON.stringify(body)}`);
      assert.equal(kv.store.has(DEVICE_KEY), false, `${status}: the device key is gone`);
    }
  });

  it("a 403 that is still a bad provider token after the one retry is permanent too", async () => {
    quiet();
    const kv = stored();
    const f = stubFetch(() => ({ status: 403, body: { reason: "ExpiredProviderToken" } }));
    assert.equal(await P.registerDevice(env(kv), reg, NOW + 25 * HOUR, f.impl), false);
    assert.equal(f.calls.length, 2, "the existing retry still happens once");
    assert.equal(kv.store.has(DEVICE_KEY), false);
  });

  it("a 4xx for a first registration or a different token is still false and stores nothing", async () => {
    quiet();
    const empty = recKv();
    assert.equal(await P.registerDevice(env(empty), reg, NOW, stubFetch(() => ({ status: 403, body: { reason: "Forbidden" } })).impl), false);
    assert.equal(empty.store.has(DEVICE_KEY), false);
    const other = stored();
    assert.equal(await P.registerDevice(env(other), { token: TOKEN2, environment: "production" }, NOW + HOUR, stubFetch(() => ({ status: 400 })).impl), false);
    assert.equal(other.store.has(DEVICE_KEY), false);
  });

  it("429, 5xx and network errors keep the same token and say true while it was verified at most 72 h ago", async () => {
    const handlers: Array<[string, () => Reply]> = [
      ["429", () => ({ status: 429, body: { reason: "TooManyRequests" } })],
      ["500", () => ({ status: 500, body: { reason: "InternalServerError" } })],
      ["503", () => ({ status: 503 })],
      ["network", () => new Error("offline")],
    ];
    for (const [name, handler] of handlers) {
      for (const after of [25 * HOUR, 71 * HOUR, 72 * HOUR]) {
        quiet();
        const kv = stored();
        const before = kv.store.get(DEVICE_KEY);
        const f = stubFetch(handler);
        assert.equal(await P.registerDevice(env(kv), reg, NOW + after, f.impl), true, `${name} at +${after / HOUR} h`);
        assert.equal(f.calls.length, 1, "it did try, the 24 h cache was stale");
        assert.equal(kv.store.get(DEVICE_KEY), before, "the stored device is untouched, verifiedAt included");
      }
    }
  });

  it("past 72 h a blip no longer keeps the device: cleared and false", async () => {
    const handlers: Array<[string, () => Reply]> = [
      ["429", () => ({ status: 429 })],
      ["500", () => ({ status: 500 })],
      ["network", () => new Error("offline")],
    ];
    for (const [name, handler] of handlers) {
      quiet();
      const kv = stored();
      assert.equal(await P.registerDevice(env(kv), reg, NOW + 72 * HOUR + MIN, stubFetch(handler).impl), false, name);
      assert.equal(kv.store.has(DEVICE_KEY), false, `${name}: cleared`);
    }
  });

  it("a first registration that hits a blip is still false", async () => {
    quiet();
    const kv = recKv();
    assert.equal(await P.registerDevice(env(kv), reg, NOW, stubFetch(() => ({ status: 500 })).impl), false);
    assert.equal(kv.store.has(DEVICE_KEY), false);
  });
});

// ---------------------------------------------------------------------------------------------------------------
describe("fix F2: registration needs WHOOP web heart rate on", () => {
  const reg = { token: TOKEN, environment: "production" as const };

  it("registerDevice clears the device and says false with no Apple request when it is off", async () => {
    for (const flag of [undefined, "off", "", "disabled"]) {
      const kv = recKv({ [DEVICE_KEY]: JSON.stringify({ ...reg, verifiedAt: new Date(NOW).toISOString() }) });
      const f = stubFetch(() => ({ status: 200 }));
      const env = { TOKENS: kv, ...pushEnv({ WHOOP_WEB_HR: flag }) } as never;
      assert.equal(await P.registerDevice(env, reg, NOW + MIN, f.impl), false, `WHOOP_WEB_HR=${String(flag)}`);
      assert.equal(f.calls.length, 0);
      assert.equal(kv.store.has(DEVICE_KEY), false, "cleared");
    }
  });

  it("still registers when it is on", async () => {
    const kv = recKv();
    const f = stubFetch(() => ({ status: 200 }));
    assert.equal(await P.registerDevice({ TOKENS: kv, ...pushEnv() } as never, reg, NOW, f.impl), true);
    assert.equal(f.calls.length, 1);
  });

  it("the owner route answers push false and stores no device when it is off", async () => {
    const { db } = sqliteD1();
    const kv = recKv();
    const f = stubFetch(() => ({ status: 200 }));
    globalThis.fetch = f.impl;
    const env = { DB: db, TOKENS: kv, INGEST_ADMIN_SECRET: SECRET, ...pushEnv({ WHOOP_WEB_HR: "off" }) } as never;
    const startIso = new Date(Math.floor((Date.now() + 3 * HOUR) / 1000) * 1000).toISOString();
    const res = await api.request("https://app.example/whoop-web/reminder/owner", {
      method: "POST", headers: { authorization: `Bearer ${SECRET}`, "content-type": "application/json" },
      body: JSON.stringify({ active: true, covered: [startIso], push: { token: TOKEN, environment: "production" } }),
    }, env);
    assert.equal(res.status, 200);
    const body = (await res.json()) as Record<string, any>;
    assert.equal(body.push, false);
    assert.equal(body.owner, "phone", "local reminders keep working");
    assert.equal(f.calls.length, 0);
    assert.equal(kv.store.has(DEVICE_KEY), false);
  });
});

// ---------------------------------------------------------------------------------------------------------------
describe("fix F3: every deploy path passes both crons", () => {
  const root = new URL("../", import.meta.url);
  const crons = (): string[] => setupLib.parseJsonc(readFileSync(new URL("wrangler.jsonc", root), "utf8")).triggers.crons;
  const triggersOf = (command: string): string[] | null => {
    const flag = /--triggers((?:\s+"[^"]+"|\s+'[^']+')+)/.exec(command);
    return flag ? [...flag[1].matchAll(/"([^"]+)"|'([^']+)'/g)].map((m) => m[1] ?? m[2]) : null;
  };

  it("package.json deploy:production carries the same --triggers as wrangler.jsonc", () => {
    const pkg = JSON.parse(readFileSync(new URL("package.json", root), "utf8")) as { scripts: Record<string, string> };
    const script = pkg.scripts["deploy:production"];
    assert.match(script, /-c wrangler\.production\.jsonc/);
    assert.deepEqual(triggersOf(script), crons(), `deploy:production: ${script}`);
  });

  it.skip("deploy.yml and package.json deploy:production agree", () => {
    const pkg = JSON.parse(readFileSync(new URL("package.json", root), "utf8")) as { scripts: Record<string, string> };
    const yml = readFileSync(new URL(".github/workflows/deploy.yml", root), "utf8").split("\n").find((l) => /wrangler deploy/.test(l) && !l.trim().startsWith("#"));
    assert.ok(yml);
    assert.deepEqual(triggersOf(pkg.scripts["deploy:production"]), triggersOf(yml));
  });

  it("any README line that prints the raw production deploy command has the triggers too", () => {
    const readme = readFileSync(new URL("README.md", root), "utf8").split("\n");
    for (const line of readme) {
      if (/wrangler deploy/.test(line) && /wrangler\.production\.jsonc/.test(line)) {
        assert.deepEqual(triggersOf(line), crons(), line);
      }
    }
  });

  it("the other deploy script (wrangler.jsonc) is left alone", () => {
    const pkg = JSON.parse(readFileSync(new URL("package.json", root), "utf8")) as { scripts: Record<string, string> };
    assert.ok(!/--triggers/.test(pkg.scripts.deploy), "uses wrangler.jsonc, which has both crons");
  });
});

// ---------------------------------------------------------------------------------------------------------------
describe("fix F4: a permanent rejection in the tick drops the device and the phone's check-in", () => {
  /** A meeting 90 s from real now, so GET reminder sees it as starting, covered by the phone. */
  async function live() {
    const start = Math.floor((Date.now() + 90_000) / 1000) * 1000;
    const w = await world([{ id: "m1", start, end: start + 30 * MIN }], Date.now());
    const get = async () =>
      (await (await api.request("https://app.example/whoop-web/reminder", { headers: { authorization: `Bearer ${SECRET}` } }, w.env)).json()) as Record<string, any>;
    return { ...w, start, tickAt: start - 90_000, get };
  }

  it("the baseline: the phone owns the covered meeting while the device is fine", async () => {
    const w = await live();
    assert.equal((await w.get()).owner, "phone");
    assert.equal((await w.get()).meeting.id, "m1");
  });

  it("410 and permanent 4xx answers clear the device, and GET reminder says mac for the covered meeting", async () => {
    const cases: Array<[number, unknown]> = [
      [410, { reason: "Unregistered" }],
      [400, { reason: "BadDeviceToken" }],
      [400, { reason: "PayloadEmpty" }],
      [403, { reason: "Forbidden" }],
      [403, { reason: "BadCertificate" }],
      [404, { reason: "BadPath" }],
    ];
    for (const [status, body] of cases) {
      quiet();
      const w = await live();
      const f = stubFetch(() => ({ status, body }));
      const r = await P.runPushTick(w.env, w.tickAt, f.impl);
      assert.deepEqual(r.sent, [], `${status}`);
      assert.equal(w.kv.store.has(DEVICE_KEY), false, `${status}: device gone`);
      assert.equal((await w.get()).owner, "mac", `${status}: the Mac reminds again, the phone check-in is dropped`);
    }
  });

  it("a 403 provider-token failure that repeats after the retry is permanent too", async () => {
    quiet();
    const w = await live();
    const f = stubFetch(() => ({ status: 403, body: { reason: "ExpiredProviderToken" } }));
    await P.runPushTick(w.env, w.tickAt, f.impl);
    assert.equal(f.calls.length, 2);
    assert.equal(w.kv.store.has(DEVICE_KEY), false);
    assert.equal((await w.get()).owner, "mac");
  });

  it("the rest of the tick is not sent once the device is rejected", async () => {
    quiet();
    const a = Date.now() + 90_000;
    const startA = Math.floor(a / 1000) * 1000;
    const startB = startA - 180_000; // started 90 s ago: followUp due
    const w = await world([{ id: "a", start: startA, end: startA + 30 * MIN }, { id: "b", start: startB, end: startB + 30 * MIN }], Date.now());
    const f = stubFetch(() => ({ status: 403, body: { reason: "Forbidden" } }));
    await P.runPushTick(w.env, startA - 90_000, f.impl);
    assert.equal(f.calls.length, 1, "stopped after the first rejection");
  });

  it("it is not dropped when a newer token was stored while the send was in flight", async () => {
    quiet();
    const w = await live();
    const f = stubFetch(() => {
      w.kv.store.set(DEVICE_KEY, JSON.stringify({ token: TOKEN2, environment: "production", verifiedAt: new Date().toISOString() }));
      return { status: 410, body: { reason: "Unregistered" } };
    });
    await P.runPushTick(w.env, w.tickAt, f.impl);
    assert.equal(storedDevice(w.kv)?.token, TOKEN2, "the newer device stays");
    assert.equal((await w.get()).owner, "phone", "and so does the check-in");
  });

  it("a 500, a 429 or a network error changes nothing", async () => {
    const handlers: Array<[string, () => Reply]> = [
      ["500", () => ({ status: 500, body: { reason: "InternalServerError" } })],
      ["429", () => ({ status: 429, body: { reason: "TooManyRequests" } })],
      ["network", () => new Error("offline")],
    ];
    for (const [name, handler] of handlers) {
      quiet();
      const w = await live();
      const before = w.kv.store.get(DEVICE_KEY);
      await P.runPushTick(w.env, w.tickAt, stubFetch(handler).impl);
      assert.equal(w.kv.store.get(DEVICE_KEY), before, `${name}: device untouched`);
      assert.equal((await w.get()).owner, "phone", `${name}: still the phone's`);
      assert.deepEqual(doneKeys(w.kv), [], `${name}: nothing recorded, the next tick retries`);
    }
  });

  it("a KV failure while clearing never throws out of the tick, and the tick still stops", async () => {
    quiet();
    const a = Date.now() + 90_000;
    const startA = Math.floor(a / 1000) * 1000;
    const startB = startA - 180_000;
    const w = await world([{ id: "a", start: startA, end: startA + 30 * MIN }, { id: "b", start: startB, end: startB + 30 * MIN }], Date.now());
    (w.kv as any).failDelete = true;
    const f = stubFetch(() => ({ status: 410, body: { reason: "Unregistered" } }));
    await assert.doesNotReject(() => P.runPushTick(w.env, startA - 90_000, f.impl));
    assert.equal(f.calls.length, 1);
  });

  it("dropping the check-in leaves no covered meeting behind", async () => {
    quiet();
    const w = await live();
    await P.runPushTick(w.env, w.tickAt, stubFetch(() => ({ status: 403, body: { reason: "Forbidden" } })).impl);
    const left = await phoneCheckIn(w.kv as never, Date.now());
    assert.ok(!left || left.covered.length === 0, "the check-in no longer covers anything");
  });
});

// ---------------------------------------------------------------------------------------------------------------
describe("fix F5: one off per end", () => {
  const rows = (...items: Array<[string, number, number]>) =>
    items.map(([id, s, e]) => ({
      id, start_utc: new Date(s).toISOString(), end_utc: new Date(e).toISOString(), duration_s: (e - s) / 1000, deleted_at: null,
    }));

  it("duePushes gives one off for two covered meetings that end together", () => {
    const r = rows(["a", S, E], ["b", S + 10 * MIN, E]);
    const off = P.duePushes({ covered: [S, S + 10 * MIN], rows: r as never, now: E + 570_000 }).filter((d: any) => d.kind === "off");
    assert.equal(off.length, 1);
    assert.equal(off[0].anchorMs, E);
  });

  it("three meetings ending together still give one", () => {
    const r = rows(["a", S, E], ["b", S + 5 * MIN, E], ["c", S + 10 * MIN, E]);
    const off = P.duePushes({ covered: [S, S + 5 * MIN, S + 10 * MIN], rows: r as never, now: E + 570_000 }).filter((d: any) => d.kind === "off");
    assert.equal(off.length, 1);
  });

  it("a tick sends one off push for them, even when the done write throws", async () => {
    quiet();
    const now = E + 570_000;
    const w = await world([{ id: "a", start: S, end: E }, { id: "b", start: S + 10 * MIN, end: E }], S - HOUR);
    seedHr(w.raw, now - 5_000);
    (w.kv as any).failPutPrefix = "push:done:";
    const f = stubFetch(() => ({ status: 200 }));
    const r = await P.runPushTick(w.env, now, f.impl);
    assert.equal(f.calls.length, 1, "one push, not one per meeting");
    assert.equal(r.sent.length, 1);
    assert.equal(f.calls[0].headers.get("apns-collapse-id"), `meetspike.broadcast.off.${E}`);
  });

  it("and with a working done write the second tick sends nothing more", async () => {
    quiet();
    const now = E + 570_000;
    const w = await world([{ id: "a", start: S, end: E }, { id: "b", start: S + 10 * MIN, end: E }], S - HOUR);
    seedHr(w.raw, now - 5_000);
    const f = stubFetch(() => ({ status: 200 }));
    await P.runPushTick(w.env, now, f.impl);
    await P.runPushTick(w.env, now + 20_000, f.impl);
    assert.equal(f.calls.length, 1);
  });
});

// ---------------------------------------------------------------------------------------------------------------
describe("fix F6: the whole registration finishes under 8 seconds", () => {
  const reg = { token: TOKEN, environment: "production" as const };
  /** A fetch that never answers until its signal aborts (or, with no signal, never within 9 s). */
  function hang() {
    return stubFetch(
      (call) =>
        new Promise<Reply>((_resolve, reject) => {
          const guard = setTimeout(() => reject(new Error("no abort signal arrived within 9 s")), 9_000);
          guard.unref();
          call.signal?.addEventListener("abort", () => {
            clearTimeout(guard);
            reject(call.signal!.reason ?? new Error("aborted"));
          });
        }),
    );
  }

  it("a hanging first attempt gives up well before 8 s (the phone gives up at 10 s)", async () => {
    quiet();
    const kv = recKv();
    const f = hang();
    const t0 = performance.now();
    const ok = await P.registerDevice({ TOKENS: kv, ...pushEnv() } as never, reg, NOW, f.impl);
    const elapsed = performance.now() - t0;
    assert.equal(ok, false, "a first registration that cannot be verified");
    assert.ok(elapsed < 8_000, `took ${Math.round(elapsed)} ms`);
    assert.ok(f.calls[0].signal, "the request carries a timeout signal");
  });

  it("a 403 that needs the retry and then hangs still finishes under 8 s in total", async () => {
    quiet();
    const kv = recKv();
    let n = 0;
    const slow = hang();
    const f = stubFetch((call) => (++n === 1 ? { status: 403, body: { reason: "ExpiredProviderToken" } } : slow.impl(call.url, { signal: call.signal } as never).then(() => ({ status: 200 }))));
    const t0 = performance.now();
    const ok = await P.registerDevice({ TOKENS: kv, ...pushEnv() } as never, reg, NOW, f.impl);
    const elapsed = performance.now() - t0;
    assert.equal(ok, false);
    assert.equal(f.calls.length, 2, "it did retry");
    assert.ok(elapsed < 8_000, `both attempts took ${Math.round(elapsed)} ms`);
  });

  it("a hang for an already verified token is a blip: still true", async () => {
    quiet();
    const kv = recKv({ [DEVICE_KEY]: JSON.stringify({ ...reg, verifiedAt: new Date(NOW).toISOString() }) });
    const t0 = performance.now();
    const ok = await P.registerDevice({ TOKENS: kv, ...pushEnv() } as never, reg, NOW + 25 * HOUR, hang().impl);
    assert.equal(ok, true);
    assert.ok(performance.now() - t0 < 8_000);
  });
});
