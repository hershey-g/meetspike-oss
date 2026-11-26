import assert from "node:assert/strict";
import { register } from "node:module";
import { afterEach, describe, it, mock } from "node:test";
import { api } from "../src/routes/api.ts";
import { fakeKv, sqliteD1 } from "./sqlite-d1.ts";

/**
 * Build 8, server track: iPhone crash and diagnostic reports.
 * POST/GET /api/whoop-web/app/diagnostics[/:id] stored in R2 `RAW`, and the
 * global app.onError in src/index.ts.
 *
 * The list response container name is not fixed by the spec, so list tests
 * accept a top-level array or the first array-valued property.
 */

const SECRET = "admin-secret-xyz";
const BASE = "https://app.example/whoop-web/app/diagnostics";
const DAY = 86_400_000;
const AUTH = { authorization: `Bearer ${SECRET}` };
const JSON_AUTH = { ...AUTH, "content-type": "application/json" };

// ---------------------------------------------------------------- R2 fake

interface FakeObject {
  key: string;
  bytes: Uint8Array;
  customMetadata: Record<string, string>;
  uploaded: Date;
}

/**
 * Bucket fake: put/get/list/delete, customMetadata only returned from list
 * when `include: ["customMetadata"]` is asked for (as real R2), lexicographic
 * order, cursor paging capped by `maxPage`, and switches to make calls fail.
 */
function fakeR2(opts: { maxPage?: number } = {}) {
  const objects = new Map<string, FakeObject>();
  const calls = {
    put: [] as string[],
    get: [] as string[],
    list: [] as Array<Record<string, unknown>>,
    delete: [] as string[],
  };
  const fail = { put: false, putSync: false, get: false, list: false, delete: false };
  const maxPage = opts.maxPage ?? 1000;
  const enc = new TextEncoder();
  const toBytes = async (v: unknown): Promise<Uint8Array> => {
    if (typeof v === "string") return enc.encode(v);
    if (v instanceof Uint8Array) return v;
    if (v instanceof ArrayBuffer) return new Uint8Array(v);
    if (v && typeof (v as ReadableStream).getReader === "function") {
      return new Uint8Array(await new Response(v as ReadableStream).arrayBuffer());
    }
    throw new Error("fake R2: unsupported value");
  };
  const view = (o: FakeObject) => ({
    key: o.key,
    size: o.bytes.byteLength,
    uploaded: o.uploaded,
    customMetadata: o.customMetadata,
    httpMetadata: {},
    text: async () => new TextDecoder().decode(o.bytes),
    json: async () => JSON.parse(new TextDecoder().decode(o.bytes)),
    arrayBuffer: async () => o.bytes.buffer.slice(o.bytes.byteOffset, o.bytes.byteOffset + o.bytes.byteLength),
    get body() {
      return new Response(o.bytes).body;
    },
  });
  const bucket = {
    put(key: string, value: unknown, options?: { customMetadata?: Record<string, string> }) {
      if (fail.putSync) throw new Error("R2 exploded (sync)");
      return (async () => {
        calls.put.push(key);
        if (fail.put) throw new Error("R2 exploded");
        const meta = options?.customMetadata ?? {};
        for (const [k, v] of Object.entries(meta)) {
          assert.equal(typeof v, "string", `customMetadata.${k} must be a string`);
        }
        objects.set(key, { key, bytes: await toBytes(value), customMetadata: { ...meta }, uploaded: new Date() });
        return null;
      })();
    },
    async get(key: string) {
      calls.get.push(key);
      if (fail.get) throw new Error("R2 get exploded");
      const o = objects.get(key);
      return o ? view(o) : null;
    },
    async list(options: { prefix?: string; limit?: number; cursor?: string; include?: string[] } = {}) {
      calls.list.push({ ...options });
      if (fail.list) throw new Error("R2 list exploded");
      const prefix = options.prefix ?? "";
      const keys = [...objects.keys()].filter((k) => k.startsWith(prefix)).sort();
      const after = options.cursor ? options.cursor.replace(/^c:/, "") : null;
      const rest = after === null ? keys : keys.filter((k) => k > after);
      const size = Math.max(1, Math.min(options.limit ?? 1000, maxPage, 1000));
      const page = rest.slice(0, size);
      const truncated = rest.length > page.length;
      const withMeta = options.include?.includes("customMetadata") === true;
      return {
        objects: page.map((k) => {
          const o = objects.get(k)!;
          const v = view(o) as Record<string, unknown>;
          if (!withMeta) delete v.customMetadata;
          return v;
        }),
        truncated,
        ...(truncated ? { cursor: `c:${page[page.length - 1]}` } : {}),
        delimitedPrefixes: [],
      };
    },
    async delete(keys: string | string[]) {
      const list = Array.isArray(keys) ? keys : [keys];
      if (list.length > 1000) throw new Error("R2 delete: max 1000 keys");
      if (fail.delete) throw new Error("R2 delete exploded");
      for (const k of list) {
        calls.delete.push(k);
        objects.delete(k);
      }
    },
  };
  const seed = (key: string, body: unknown, customMetadata: Record<string, string> = {}) => {
    objects.set(key, {
      key,
      bytes: enc.encode(typeof body === "string" ? body : JSON.stringify(body)),
      customMetadata,
      uploaded: new Date(),
    });
  };
  return { bucket, objects, calls, fail, seed };
}

function makeCtx() {
  const pending: Promise<unknown>[] = [];
  return {
    ctx: { waitUntil: (p: Promise<unknown>) => void pending.push(Promise.resolve(p)), passThroughOnException() {} },
    settle: async () => {
      // waitUntil work may schedule more waitUntil work; drain until stable.
      let n = -1;
      while (n !== pending.length) {
        n = pending.length;
        await Promise.allSettled(pending);
      }
    },
  };
}

function setup(opts: { secret?: string | null; maxPage?: number } = {}) {
  const r2 = fakeR2({ maxPage: opts.maxPage });
  const { db } = sqliteD1();
  const secret = opts.secret === undefined ? SECRET : opts.secret;
  const env = { DB: db, TOKENS: fakeKv(), RAW: r2.bucket, INGEST_ADMIN_SECRET: secret ?? undefined };
  const c = makeCtx();
  const post = (body: unknown, headers: Record<string, string> = JSON_AUTH) =>
    api.request(BASE, { method: "POST", body: typeof body === "string" ? body : JSON.stringify(body), headers }, env as never, c.ctx as never);
  const get = (path = "", headers: Record<string, string> = AUTH) =>
    api.request(`${BASE}${path}`, { headers }, env as never, c.ctx as never);
  return { r2, env, post, get, settle: c.settle };
}

// ---------------------------------------------------------------- fixtures

const iso = (offsetMs: number) => new Date(Date.now() + offsetMs).toISOString();
const dayOf = (offsetDays: number) => iso(offsetDays * DAY).slice(0, 10);
const uuid = () => crypto.randomUUID();

function validBody(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: uuid(),
    kind: "crash",
    at: iso(-3_600_000),
    app: "ios",
    build: 8,
    version: "1.1",
    os: "iOS 26.1",
    device: "iPhone17,1",
    signature: "EXC_BAD_ACCESS < MeetspikeHR+4120 < UIKit+88",
    report: { diagnosticMetaData: { appBuildVersion: "8" } },
    crumbs: ["2026-11-25T05:00:00.000Z launch 8"],
    ...over,
  };
}

const keyFor = (b: Record<string, unknown>) => `diagnostics/${String(b.at).slice(0, 10)}/${b.id}.json`;

async function stored(r2: ReturnType<typeof fakeR2>, key: string): Promise<Record<string, any>> {
  const o = r2.objects.get(key);
  assert.ok(o, `expected R2 object at ${key}; have ${[...r2.objects.keys()].join(", ") || "(none)"}`);
  return JSON.parse(new TextDecoder().decode(o.bytes));
}

function rowsOf(json: any): any[] {
  if (Array.isArray(json)) return json;
  for (const v of Object.values(json ?? {})) if (Array.isArray(v)) return v;
  assert.fail(`no array in list response: ${JSON.stringify(json).slice(0, 200)}`);
}

/** Nesting depth counting objects and arrays both; the report root is level 1. */
function containerDepth(v: unknown): number {
  if (Array.isArray(v)) return 1 + Math.max(0, ...v.map(containerDepth));
  if (v && typeof v === "object") return 1 + Math.max(0, ...Object.values(v).map(containerDepth));
  return 0;
}

afterEach(() => mock.restoreAll());

// ---------------------------------------------------------------- auth

describe("diagnostics: auth runs before the body is read", () => {
  it("503 on all three routes when INGEST_ADMIN_SECRET is unset", async () => {
    const { post, get, r2 } = setup({ secret: null });
    assert.equal((await post(validBody())).status, 503);
    assert.equal((await get()).status, 503);
    assert.equal((await get(`/${uuid()}`)).status, 503);
    assert.equal(r2.objects.size, 0);
  });

  it("401 on a wrong, empty or missing secret on all three routes", async () => {
    const { post, get, r2 } = setup();
    const wrong = { authorization: "Bearer nope", "content-type": "application/json" };
    assert.equal((await post(validBody(), wrong)).status, 401);
    assert.equal((await post(validBody(), { "content-type": "application/json" })).status, 401);
    assert.equal((await get("", { authorization: "Bearer nope" })).status, 401);
    assert.equal((await get("", {})).status, 401);
    assert.equal((await get(`/${uuid()}`, { authorization: "Bearer nope" })).status, 401);
    assert.equal(r2.objects.size, 0);
    assert.equal(r2.calls.put.length, 0);
  });

  it("accepts the secret in x-admin-secret too", async () => {
    const { post, r2 } = setup();
    const res = await post(validBody(), { "x-admin-secret": SECRET, "content-type": "application/json" });
    assert.equal(res.status, 200);
    assert.equal(r2.objects.size, 1);
  });

  it("never reads the body of an unauthorized POST (401 and 503)", async () => {
    for (const secret of [SECRET, null]) {
      const { env } = setup({ secret });
      let pulled = false;
      const stream = new ReadableStream(
        {
          pull(ctrl) {
            pulled = true;
            ctrl.enqueue(new TextEncoder().encode("{}"));
            ctrl.close();
          },
        },
        { highWaterMark: 0 },
      );
      const res = await api.request(
        BASE,
        { method: "POST", body: stream, headers: { authorization: "Bearer nope", "content-type": "application/json" }, duplex: "half" } as never,
        env as never,
      );
      assert.equal(res.status, secret ? 401 : 503);
      assert.equal(pulled, false, "body was read before auth");
    }
  });

  it("answers an oversized unauthorized POST with 401, not 413", async () => {
    const { post } = setup();
    const res = await post("x".repeat(300_000), { authorization: "Bearer nope", "content-type": "application/json" });
    assert.equal(res.status, 401);
  });

  it("sets Cache-Control private, no-store on every outcome", async () => {
    const { post, get } = setup();
    const id = uuid();
    const outcomes = [
      await post(validBody({ id })),
      await post("{nope"),
      await post(validBody(), { authorization: "Bearer nope" }),
      await post("x".repeat(300_000)),
      await get(),
      await get(`/${id}`),
      await get(`/${uuid()}`),
      await get("", {}),
    ];
    for (const r of outcomes) assert.equal(r.headers.get("cache-control"), "private, no-store", String(r.status));
  });
});

// ---------------------------------------------------------------- size and shape

describe("diagnostics: POST size and shape", () => {
  it("413 over 256 KB, with {error}, and stores nothing", async () => {
    const { post, r2 } = setup();
    const res = await post(validBody({ report: { message: "x".repeat(300_000) } }));
    assert.equal(res.status, 413);
    assert.equal(typeof ((await res.json()) as any).error, "string");
    assert.equal(r2.objects.size, 0);
  });

  it("accepts a body just under 256 KB", async () => {
    const { post, r2 } = setup();
    const frames = Array.from({ length: 5000 }, () => ({ sampleCount: 1 }));
    const body = validBody({ report: { callStackTree: { callStacks: [{ callStackRootFrames: frames }] } } });
    const size = JSON.stringify(body).length;
    assert.ok(size > 50_000 && size < 256 * 1024, `fixture is ${size} bytes`);
    assert.equal((await post(body)).status, 200);
    assert.equal(r2.objects.size, 1);
  });

  it("400 {error} for invalid JSON, a non-object body, and empty input", async () => {
    const { post, r2 } = setup();
    for (const raw of ["{not json", "[]", '"str"', "null", "42", ""]) {
      const res = await post(raw);
      assert.equal(res.status, 400, raw);
      assert.equal(typeof ((await res.json()) as any).error, "string", raw);
    }
    assert.equal(r2.objects.size, 0);
  });

  it("400 for each bad field", async () => {
    const { post, r2 } = setup();
    const bad: Array<[string, Record<string, unknown>]> = [
      ["missing id", { id: undefined }],
      ["id not a uuid", { id: "not-a-uuid" }],
      ["id with a path in it", { id: "../../etc/passwd" }],
      ["id a number", { id: 7 }],
      ["missing kind", { kind: undefined }],
      ["unknown kind", { kind: "explosion" }],
      ["kind wrong case", { kind: "Crash" }],
      ["missing at", { at: undefined }],
      ["at not a string", { at: 1764046800000 }],
      ["at unparseable", { at: "yesterday-ish" }],
      ["at empty", { at: "" }],
      ["at more than a day ahead", { at: iso(2 * DAY) }],
      ["app is not ios", { app: "android" }],
      ["missing build", { build: undefined }],
      ["build is a string", { build: "8" }],
      ["build is fractional", { build: 8.5 }],
      ["missing version", { version: undefined }],
      ["version not a string", { version: 1.1 }],
      ["missing os", { os: undefined }],
      ["os not a string", { os: ["iOS"] }],
      ["missing device", { device: undefined }],
      ["device not a string", { device: {} }],
      ["signature not a string", { signature: 12 }],
      ["missing report", { report: undefined }],
      ["report is a string", { report: "boom" }],
      ["report is an array", { report: [1, 2] }],
      ["report is null", { report: null }],
    ];
    for (const [name, over] of bad) {
      const res = await post(validBody(over));
      assert.equal(res.status, 400, name);
      assert.equal(typeof ((await res.json()) as any).error, "string", name);
    }
    assert.equal(r2.objects.size, 0);
    assert.equal(r2.calls.put.length, 0);
  });

  it("accepts every kind, and a body without signature or crumbs", async () => {
    const { post, r2 } = setup();
    for (const kind of ["crash", "hang", "cpu", "disk", "exit", "error", "test"]) {
      const res = await post(validBody({ kind, signature: undefined, crumbs: undefined }));
      assert.equal(res.status, 200, kind);
    }
    assert.equal(r2.objects.size, 7);
  });

  it("allows an at up to a day ahead (clock skew) and rejects past a day", async () => {
    const { post } = setup();
    assert.equal((await post(validBody({ at: iso(12 * 3_600_000) }))).status, 200);
    assert.equal((await post(validBody({ at: iso(DAY + 3_600_000) }))).status, 400);
  });
});

// ---------------------------------------------------------------- store

describe("diagnostics: POST stores in R2", () => {
  it("writes diagnostics/<day of at>/<id>.json and answers {ok, id}", async () => {
    const { post, r2 } = setup();
    const day = dayOf(-3);
    const body = validBody({ at: `${day}T23:30:00.000Z` });
    const res = await post(body);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true, id: body.id });
    assert.deepEqual([...r2.objects.keys()], [`diagnostics/${day}/${body.id}.json`]);
    const doc = await stored(r2, `diagnostics/${day}/${body.id}.json`);
    assert.equal(doc.id, body.id);
    assert.equal(doc.kind, "crash");
    assert.equal(doc.build, 8);
    assert.equal(doc.version, "1.1");
    assert.equal(doc.os, "iOS 26.1");
    assert.equal(doc.device, "iPhone17,1");
    assert.equal(doc.signature, body.signature);
    assert.equal(new Date(doc.at).getTime(), new Date(body.at as string).getTime());
    assert.deepEqual(doc.crumbs, body.crumbs);
    assert.deepEqual(doc.report, body.report);
  });

  it("sets customMetadata kind, build, os, device, signature, at as strings", async () => {
    const { post, r2 } = setup();
    const body = validBody({ kind: "hang", build: 8 });
    await post(body);
    const meta = r2.objects.get(keyFor(body))!.customMetadata;
    assert.equal(meta.kind, "hang");
    assert.equal(meta.build, "8");
    assert.equal(meta.os, "iOS 26.1");
    assert.equal(meta.device, "iPhone17,1");
    assert.equal(meta.signature, body.signature);
    assert.equal(new Date(meta.at).getTime(), new Date(body.at as string).getTime());
    for (const v of Object.values(meta)) assert.equal(typeof v, "string");
  });

  it("cuts the signature to 200 chars in the body and the metadata", async () => {
    const { post, r2 } = setup();
    const body = validBody({ signature: "s".repeat(500) });
    assert.equal((await post(body)).status, 200);
    assert.equal(r2.objects.get(keyFor(body))!.customMetadata.signature.length, 200);
    assert.equal((await stored(r2, keyFor(body))).signature.length, 200);
  });

  it("a missing signature never puts a non-string in the metadata", async () => {
    const { post, r2 } = setup();
    const body = validBody({ signature: undefined });
    assert.equal((await post(body)).status, 200);
    const sig = r2.objects.get(keyFor(body))!.customMetadata.signature;
    assert.ok(sig === undefined || sig === "");
  });

  it("the same id again overwrites and never duplicates", async () => {
    const { post, r2 } = setup();
    const body = validBody({ report: { message: "first" } });
    assert.equal((await post(body)).status, 200);
    assert.equal((await post({ ...body, report: { message: "second" } })).status, 200);
    assert.equal(r2.objects.size, 1);
    assert.equal((await stored(r2, keyFor(body))).report.message, "second");
    // a plain retry of the identical body is a no-op
    assert.equal((await post({ ...body, report: { message: "second" } })).status, 200);
    assert.equal(r2.objects.size, 1);
  });

  it("different ids make different objects", async () => {
    const { post, r2 } = setup();
    await post(validBody());
    await post(validBody());
    assert.equal(r2.objects.size, 2);
  });

  it("503 {error} when R2 put rejects or throws, and nothing is stored", async () => {
    for (const mode of ["put", "putSync"] as const) {
      const { post, r2 } = setup();
      r2.fail[mode] = true;
      const res = await post(validBody());
      assert.equal(res.status, 503, mode);
      assert.equal(typeof ((await res.json()) as any).error, "string", mode);
      assert.equal(r2.objects.size, 0);
      mock.restoreAll();
    }
  });

  it("503 when the RAW binding is missing", async () => {
    const { db } = sqliteD1();
    const env = { DB: db, TOKENS: fakeKv(), INGEST_ADMIN_SECRET: SECRET };
    const res = await api.request(BASE, { method: "POST", body: JSON.stringify(validBody()), headers: JSON_AUTH }, env as never);
    assert.equal(res.status, 503);
  });
});

// ---------------------------------------------------------------- logging

describe("diagnostics: logging", () => {
  const lines = (m: ReturnType<typeof mock.method>) =>
    m.mock.calls
      .map((c) => String(c.arguments[0]))
      .filter((s) => s.includes("app_diagnostic"))
      .map((s) => JSON.parse(s));

  it("logs one console.error line for a crash, with no report or crumbs", async () => {
    const err = mock.method(console, "error", () => {});
    const log = mock.method(console, "log", () => {});
    const { post, settle } = setup();
    await post(validBody({ kind: "crash", report: { message: "PERSONAL-MARKER" }, crumbs: ["CRUMB-MARKER"] }));
    await settle();
    const out = lines(err);
    assert.equal(out.length, 1);
    assert.deepEqual(Object.keys(out[0]).sort(), ["build", "event", "kind", "os", "signature"]);
    assert.equal(out[0].event, "app_diagnostic");
    assert.equal(out[0].kind, "crash");
    assert.equal(out[0].build, 8);
    assert.equal(out[0].os, "iOS 26.1");
    assert.equal(out[0].signature, "EXC_BAD_ACCESS < MeetspikeHR+4120 < UIKit+88");
    assert.equal(lines(log).length, 0);
    const all = [...err.mock.calls, ...log.mock.calls].map((c) => String(c.arguments[0])).join("\n");
    assert.ok(!all.includes("PERSONAL-MARKER") && !all.includes("CRUMB-MARKER"));
  });

  it("logs a test report with console.log, not console.error", async () => {
    const err = mock.method(console, "error", () => {});
    const log = mock.method(console, "log", () => {});
    const { post, settle } = setup();
    await post(validBody({ kind: "test" }));
    await settle();
    assert.equal(lines(err).length, 0);
    const out = lines(log);
    assert.equal(out.length, 1);
    assert.equal(out[0].kind, "test");
  });

  it("logs nothing for a rejected report", async () => {
    const err = mock.method(console, "error", () => {});
    const log = mock.method(console, "log", () => {});
    const { post } = setup();
    await post(validBody({ kind: "nope" }));
    assert.equal(lines(err).length + lines(log).length, 0);
  });
});

// ---------------------------------------------------------------- sanitizer (through HTTP)

describe("diagnostics: sanitizer through POST", () => {
  it("keeps only allowlisted top-level fields", async () => {
    const { post, r2 } = setup();
    const body = validBody({
      email: "dana@example.com",
      userName: "Dana",
      meetingTitle: "Roadmap with Dana",
      heartRate: 142,
      extra: { nested: true },
    });
    assert.equal((await post(body)).status, 200);
    const doc = await stored(r2, keyFor(body));
    for (const k of Object.keys(doc)) {
      assert.ok(
        ["id", "kind", "at", "app", "build", "version", "os", "device", "signature", "report", "crumbs"].includes(k),
        `unexpected top-level field ${k}`,
      );
    }
    assert.ok(!JSON.stringify(doc).includes("dana@example.com"));
    assert.ok(!JSON.stringify(doc).includes("Roadmap with Dana"));
  });

  it("trims strings and cuts version/os/device to 40", async () => {
    const { post, r2 } = setup();
    const body = validBody({ version: "  1.1  ", os: "o".repeat(100), device: ` ${"d".repeat(100)} `, signature: "  sig  " });
    assert.equal((await post(body)).status, 200);
    const doc = await stored(r2, keyFor(body));
    assert.equal(doc.version, "1.1");
    assert.equal(doc.os, "o".repeat(40));
    assert.equal(doc.device, "d".repeat(40));
    assert.equal(doc.signature, "sig");
    const meta = r2.objects.get(keyFor(body))!.customMetadata;
    assert.equal(meta.os, "o".repeat(40));
    assert.equal(meta.device, "d".repeat(40));
  });

  it("keeps at most 150 crumb lines, each cut to 200 chars", async () => {
    const { post, r2 } = setup();
    const crumbs = Array.from({ length: 400 }, (_, i) => `${"c".repeat(300)}${i}`);
    const body = validBody({ crumbs });
    assert.equal((await post(body)).status, 200);
    const doc = await stored(r2, keyFor(body));
    assert.equal(doc.crumbs.length, 150);
    for (const line of doc.crumbs) {
      assert.equal(typeof line, "string");
      assert.ok(line.length <= 200);
    }
  });

  it("keeps the allowlisted report tree and drops the rest, exactly", async () => {
    const { post, r2 } = setup();
    const report = {
      callStackTree: {
        callStacks: [
          {
            threadAttributed: true,
            callStackRootFrames: [
              {
                binaryUUID: "AAAA-1111",
                offsetIntoBinaryTextSegment: 4120,
                sampleCount: 2,
                binaryName: "MeetspikeHR",
                address: 4300000000,
                meetingTitle: "Roadmap with Dana",
                subFrames: [
                  { binaryUUID: "BBBB-2222", offsetIntoBinaryTextSegment: 88, sampleCount: 1, binaryName: "UIKit", address: 1, attendee: "Dana", subFrames: [] },
                ],
              },
            ],
          },
        ],
        callStackPerThread: false,
      },
      diagnosticMetaData: {
        appBuildVersion: "8",
        appVersion: "1.1",
        osVersion: "iPhone OS 26.1 (23B85)",
        deviceType: "iPhone17,1",
        platformArchitecture: "arm64e",
        regionFormat: "US",
        exceptionType: 1,
        exceptionCode: 1,
        signal: 11,
        terminationReason: "Namespace SIGNAL, Code 11",
        userEmail: "dana@example.com",
      },
      hangDuration: 3.5,
      totalCPUTime: 120,
      totalSampledTime: 30,
      writesCaused: 2048,
      message: "boom",
      code: 7,
      path: "/Library/x",
      secretNote: "Dana's heart rate was 160",
    };
    const body = validBody({ report });
    assert.equal((await post(body)).status, 200);
    const got = (await stored(r2, keyFor(body))).report;
    assert.deepEqual(got, {
      callStackTree: {
        callStacks: [
          {
            threadAttributed: true,
            callStackRootFrames: [
              {
                binaryUUID: "AAAA-1111",
                offsetIntoBinaryTextSegment: 4120,
                sampleCount: 2,
                binaryName: "MeetspikeHR",
                address: 4300000000,
                subFrames: [{ binaryUUID: "BBBB-2222", offsetIntoBinaryTextSegment: 88, sampleCount: 1, binaryName: "UIKit", address: 1, subFrames: [] }],
              },
            ],
          },
        ],
        callStackPerThread: false,
      },
      diagnosticMetaData: {
        appBuildVersion: "8",
        appVersion: "1.1",
        osVersion: "iPhone OS 26.1 (23B85)",
        deviceType: "iPhone17,1",
        platformArchitecture: "arm64e",
        exceptionType: 1,
        exceptionCode: 1,
        signal: 11,
        terminationReason: "Namespace SIGNAL, Code 11",
      },
      hangDuration: 3.5,
      totalCPUTime: 120,
      totalSampledTime: 30,
      writesCaused: 2048,
      message: "boom",
      code: 7,
      path: "/Library/x",
    });
  });

  it("drops regionFormat and every field that can hold personal text", async () => {
    const { post, r2 } = setup();
    const report = {
      diagnosticMetaData: {
        regionFormat: "REGION-MARKER",
        exceptionReason: { composedMessage: "COMPOSED-MARKER", arguments: ["ARG-MARKER"], exceptionType: "NSInvalidArgumentException" },
        virtualMemoryRegionInfo: "VM-MARKER",
        signal: 6,
      },
      exceptionReason: "TOP-REASON-MARKER",
      composedMessage: "TOP-COMPOSED-MARKER",
      arguments: ["TOP-ARG-MARKER"],
      virtualMemoryRegionInfo: "TOP-VM-MARKER",
    };
    const body = validBody({ report });
    assert.equal((await post(body)).status, 200);
    const text = JSON.stringify(await stored(r2, keyFor(body)));
    for (const m of ["REGION-MARKER", "COMPOSED-MARKER", "ARG-MARKER", "VM-MARKER", "TOP-REASON-MARKER", "TOP-COMPOSED-MARKER", "TOP-ARG-MARKER", "TOP-VM-MARKER", "regionFormat", "exceptionReason", "composedMessage", "virtualMemoryRegionInfo"]) {
      assert.ok(!text.includes(m), `${m} leaked into storage`);
    }
    assert.equal((await stored(r2, keyFor(body))).report.diagnosticMetaData.signal, 6);
  });

  it("keeps only numbers, booleans and strings: null, undefined-like and containers of the wrong kind are dropped", async () => {
    const { post, r2 } = setup();
    const report = { message: null, code: { nested: 1 }, path: ["a"], signal: 9, threadAttributed: false, hangDuration: "3 sec" };
    const body = validBody({ report });
    assert.equal((await post(body)).status, 200);
    const got = (await stored(r2, keyFor(body))).report;
    assert.equal(got.signal, 9);
    assert.equal(got.threadAttributed, false);
    assert.equal(got.hangDuration, "3 sec");
    assert.ok(!("message" in got) || got.message === undefined);
    assert.ok(typeof got.code !== "object" || got.code === undefined || Object.keys(got.code).length === 0);
  });

  it("cuts report strings to 500 chars", async () => {
    const { post, r2 } = setup();
    const body = validBody({ report: { message: "m".repeat(2000), path: "p".repeat(501), terminationReason: "t".repeat(500) } });
    assert.equal((await post(body)).status, 200);
    const got = (await stored(r2, keyFor(body))).report;
    assert.equal(got.message.length, 500);
    assert.equal(got.path.length, 500);
    assert.equal(got.terminationReason.length, 500);
  });

  it("keeps the exits map entries that are numbers and drops the others", async () => {
    const { post, r2 } = setup();
    const body = validBody({ kind: "exit", report: { exits: { memoryLimit: 2, watchdog: 1, label: "text", flag: true, nested: { a: 1 } } } });
    assert.equal((await post(body)).status, 200);
    const exits = (await stored(r2, keyFor(body))).report.exits;
    assert.equal(exits.memoryLimit, 2);
    assert.equal(exits.watchdog, 1);
    assert.ok(!("label" in exits) && !("nested" in exits));
  });

  it("an all-unknown report is stored as an empty object, not rejected", async () => {
    const { post, r2 } = setup();
    const body = validBody({ report: { whatever: "x", other: 5 } });
    assert.equal((await post(body)).status, 200);
    assert.deepEqual((await stored(r2, keyFor(body))).report, {});
  });

  const stackBody = (frames: number) => {
    // A real MetricKit stack nests one frame object plus one subFrames array per frame.
    let frame: Record<string, unknown> = { binaryName: "leaf", sampleCount: 1 };
    for (let i = 0; i < frames - 1; i++) frame = { binaryName: `d${i}`, sampleCount: 1, subFrames: [frame] };
    return validBody({ report: { callStackTree: { callStacks: [{ callStackRootFrames: [frame] }] } } });
  };

  it("keeps a 100-frame-deep call stack (about 200 levels) whole", async () => {
    const { post, r2 } = setup();
    const body = stackBody(100);
    assert.ok(JSON.stringify(body).length < 256 * 1024);
    assert.equal((await post(body)).status, 200);
    const got = (await stored(r2, keyFor(body))).report;
    const depth = containerDepth(got);
    assert.ok(depth > 200 && depth <= 300, `depth ${depth}`);
    assert.ok(JSON.stringify(got).includes('"leaf"'), "the deepest frame was dropped");
    assert.deepEqual(got, (body.report as Record<string, unknown>), "nothing allowlisted should be lost");
  });

  it("cuts a stack over the limit at 300 levels (objects and arrays both count) and still answers 200", async () => {
    const { post, r2 } = setup();
    const body = stackBody(400);
    assert.ok(JSON.stringify(body).length < 256 * 1024);
    assert.equal((await post(body)).status, 200);
    const got = (await stored(r2, keyFor(body))).report;
    const depth = containerDepth(got);
    assert.ok(depth <= 300, `depth ${depth} exceeds 300`);
    assert.ok(depth >= 290, `depth ${depth}: cut far too early`);
    assert.ok(!JSON.stringify(got).includes('"leaf"'));
    // stackBody wraps the leaf in d0 first, so d0 is the innermost frame and d398 the outermost.
    const text = JSON.stringify(got);
    assert.ok(text.includes('"d398"'), "the outermost frames must survive");
    assert.ok(!text.includes('"d0"'), "the innermost frames are cut");
  });

  it("keeps at most 20000 nodes and drops the rest in order", async () => {
    const { post, r2 } = setup();
    const frames: Array<Record<string, unknown>> = Array.from({ length: 23_000 }, () => ({ code: 1 }));
    frames[0] = { code: 7 };
    const body = validBody({ report: { callStackTree: { callStacks: [{ callStackRootFrames: frames }] } } });
    const size = JSON.stringify(body).length;
    assert.ok(size < 256 * 1024, `fixture is ${size} bytes`);
    assert.equal((await post(body)).status, 200);
    const kept = (await stored(r2, keyFor(body))).report.callStackTree.callStacks[0].callStackRootFrames;
    assert.ok(kept.length <= 20_000, `kept ${kept.length} frames`);
    assert.ok(kept.length >= 1000, `kept only ${kept.length} frames`);
    assert.equal(kept[0].code, 7);
  });
});

describe("sanitizeDiagnostic (pure)", () => {
  it("is exported and never throws on a hostile report", async () => {
    const mod = await import("../src/lib/diagnostics.ts");
    assert.equal(typeof mod.sanitizeDiagnostic, "function");
    let deep: Record<string, unknown> = { binaryName: "leaf" };
    for (let i = 0; i < 100_000; i++) deep = { subFrames: [deep] };
    const wide = { callStackRootFrames: Array.from({ length: 100_000 }, () => ({ code: 1 })) };
    const weird = { message: "x".repeat(1_000_000), code: Number.NaN, path: Number.POSITIVE_INFINITY, signal: -0 };
    for (const report of [deep, wide, weird, {}, { callStackTree: deep }]) {
      assert.doesNotThrow(() => {
        const out = mod.sanitizeDiagnostic(validBody({ report }));
        JSON.stringify(out);
      });
    }
  });

  it("does not return the personal text it was given", async () => {
    const mod = await import("../src/lib/diagnostics.ts");
    const out = mod.sanitizeDiagnostic(
      validBody({ report: { diagnosticMetaData: { exceptionReason: { composedMessage: "PERSONAL-MARKER" }, signal: 4 } }, userEmail: "PERSONAL-MARKER" }),
    );
    const text = JSON.stringify(out);
    assert.ok(!text.includes("PERSONAL-MARKER"));
    assert.ok(text.includes("MeetspikeHR") || text.includes("iPhone17,1"), "sanitized body should still carry the allowed fields");
  });
});

// ---------------------------------------------------------------- retention

describe("diagnostics: retention", () => {
  const oldKey = (days: number, n: number | string) => `diagnostics/${dayOf(-days)}/old-${n}.json`;

  it("after a store, deletes objects older than 90 days and keeps newer ones", async () => {
    const { post, r2, settle } = setup();
    r2.seed(oldKey(100, "a"), { id: "a" });
    r2.seed(oldKey(400, "b"), { id: "b" });
    r2.seed(oldKey(80, "keep80"), { id: "c" });
    r2.seed(oldKey(10, "keep10"), { id: "d" });
    r2.seed(`hr/${dayOf(-500)}/not-diagnostics.json`, { id: "e" });
    r2.seed(`diagnostic-notes/${dayOf(-500)}/x.json`, { id: "f" });
    const body = validBody();
    assert.equal((await post(body)).status, 200);
    await settle();
    assert.ok(!r2.objects.has(oldKey(100, "a")));
    assert.ok(!r2.objects.has(oldKey(400, "b")));
    assert.ok(r2.objects.has(oldKey(80, "keep80")));
    assert.ok(r2.objects.has(oldKey(10, "keep10")));
    assert.ok(r2.objects.has(`hr/${dayOf(-500)}/not-diagnostics.json`));
    assert.ok(r2.objects.has(`diagnostic-notes/${dayOf(-500)}/x.json`));
    assert.ok(r2.objects.has(keyFor(body)), "the new report is kept");
  });

  it("deletes at most 200 per call", async () => {
    const { post, r2, settle } = setup();
    for (let i = 0; i < 250; i++) r2.seed(oldKey(120, String(i).padStart(3, "0")), { i });
    assert.equal((await post(validBody())).status, 200);
    await settle();
    const left = [...r2.objects.keys()].filter((k) => k.includes("/old-")).length;
    const deleted = 250 - left;
    assert.ok(deleted >= 1, "nothing was deleted");
    assert.ok(deleted <= 200, `deleted ${deleted}`);
    assert.ok(r2.calls.delete.length <= 200);
  });

  it("works through a backlog over successive stores", async () => {
    const { post, r2, settle } = setup();
    for (let i = 0; i < 250; i++) r2.seed(oldKey(120, String(i).padStart(3, "0")), { i });
    await post(validBody());
    await settle();
    await post(validBody());
    await settle();
    assert.equal([...r2.objects.keys()].filter((k) => k.includes("/old-")).length, 0);
  });

  it("follows the list cursor when finding old objects", async () => {
    const { post, r2, settle } = setup();
    for (let i = 0; i < 30; i++) r2.seed(oldKey(100, String(i).padStart(2, "0")), { i });
    assert.equal((await post(validBody())).status, 200);
    await settle();
    assert.equal([...r2.objects.keys()].filter((k) => k.includes("/old-")).length, 0);
  });

  it("a delete or list failure is ignored and the store still answers 200", async () => {
    for (const mode of ["delete", "list"] as const) {
      const { post, r2, settle } = setup();
      r2.seed(oldKey(100, "a"), { id: "a" });
      r2.fail[mode] = true;
      const body = validBody();
      const res = await post(body);
      assert.equal(res.status, 200, mode);
      assert.deepEqual(await res.json(), { ok: true, id: body.id });
      await settle();
      assert.ok(r2.objects.has(keyFor(body)), mode);
    }
  });

  it("does not run retention for a rejected report", async () => {
    const { post, r2, settle } = setup();
    r2.seed(oldKey(100, "a"), { id: "a" });
    assert.equal((await post(validBody({ kind: "nope" }))).status, 400);
    await settle();
    assert.ok(r2.objects.has(oldKey(100, "a")));
    r2.fail.put = true;
    assert.equal((await post(validBody())).status, 503);
    await settle();
    assert.ok(r2.objects.has(oldKey(100, "a")));
  });
});

// ---------------------------------------------------------------- list

describe("diagnostics: GET list", () => {
  async function seedViaPost(s: ReturnType<typeof setup>, n: number, daysBack: (i: number) => number, msBack: (i: number) => number = () => 0) {
    const made: Array<Record<string, unknown>> = [];
    for (let i = 0; i < n; i++) {
      const b = validBody({
        at: iso(-daysBack(i) * DAY - msBack(i) - 60_000),
        kind: i % 2 ? "hang" : "crash",
        build: 5 + (i % 4),
        signature: `sig-${i}`,
      });
      assert.equal((await s.post(b)).status, 200);
      made.push(b);
    }
    await s.settle();
    return made;
  }

  it("starts empty", async () => {
    const { get } = setup();
    const res = await get();
    assert.equal(res.status, 200);
    assert.deepEqual(rowsOf(await res.json()), []);
  });

  it("returns summaries with id, key, kind, build, os, device, signature, at, size", async () => {
    const s = setup();
    const [b] = await seedViaPost(s, 1, () => 0);
    const rows = rowsOf(await (await s.get()).json());
    assert.equal(rows.length, 1);
    const r = rows[0];
    assert.equal(r.id, b.id);
    assert.equal(r.key, keyFor(b));
    assert.equal(r.kind, "crash");
    assert.equal(Number(r.build), 5);
    assert.equal(r.os, "iOS 26.1");
    assert.equal(r.device, "iPhone17,1");
    assert.equal(r.signature, "sig-0");
    assert.equal(new Date(r.at).getTime(), new Date(b.at as string).getTime());
    assert.equal(r.size, r2size(s, keyFor(b)));
    // the summary never carries the report itself
    assert.ok(!("report" in r) && !("crumbs" in r));
  });

  it("asks R2 for customMetadata when listing, and does not read the objects", async () => {
    const s = setup();
    await seedViaPost(s, 3, (i) => i);
    s.r2.calls.get.length = 0;
    s.r2.calls.list.length = 0;
    await s.get();
    assert.ok(s.r2.calls.list.length >= 1);
    for (const c of s.r2.calls.list) assert.ok((c.include as string[] | undefined)?.includes("customMetadata"));
    assert.equal(s.r2.calls.get.length, 0, "summaries come from list metadata, not per-object reads");
  });

  it("lists newest first across days", async () => {
    const s = setup();
    const made = await seedViaPost(s, 8, (i) => [5, 1, 40, 3, 0, 22, 9, 2][i]);
    const rows = rowsOf(await (await s.get()).json());
    const expected = [...made].sort((a, b) => Date.parse(b.at as string) - Date.parse(a.at as string)).map((b) => b.id);
    assert.deepEqual(rows.map((r) => r.id), expected);
  });

  it("orders by time of day within one day, not by the object key", async () => {
    const s = setup();
    const day = "2026-06-10";
    const ids = ["ffffffff-0000-4000-8000-000000000001", "aaaaaaaa-0000-4000-8000-000000000002", "55555555-0000-4000-8000-000000000003"];
    const times = ["06:00:00.000Z", "18:00:00.000Z", "12:00:00.000Z"];
    ids.forEach((id, i) => s.r2.seed(`diagnostics/${day}/${id}.json`, { id }, { kind: "crash", build: "8", os: "x", device: "y", signature: "", at: `${day}T${times[i]}` }));
    const rows = rowsOf(await (await s.get()).json());
    assert.deepEqual(rows.map((r) => r.id), [ids[1], ids[2], ids[0]]);
  });

  it("pages through the R2 cursor: newest first even when the bucket returns tiny pages", async () => {
    const s = setup({ maxPage: 3 });
    const made = await seedViaPost(s, 10, (i) => i * 2);
    const rows = rowsOf(await (await s.get()).json());
    assert.equal(rows.length, 10);
    assert.deepEqual(rows.map((r) => r.id), made.map((b) => b.id), "made[0] is the newest");
    assert.ok(s.r2.calls.list.length >= 4, `only ${s.r2.calls.list.length} list calls`);
  });

  it("limit returns the newest N, not the first N keys", async () => {
    const s = setup({ maxPage: 3 });
    const made = await seedViaPost(s, 10, (i) => i);
    const rows = rowsOf(await (await s.get("?limit=4")).json());
    assert.deepEqual(rows.map((r) => r.id), made.slice(0, 4).map((b) => b.id));
  });

  it("defaults to 50 and caps at 200", async () => {
    const s = setup();
    for (let i = 0; i < 230; i++) {
      const day = dayOf(-(i % 60));
      const id = uuid();
      const at = `${day}T${String(i % 24).padStart(2, "0")}:00:00.000Z`;
      s.r2.seed(`diagnostics/${day}/${id}.json`, { id }, { kind: "crash", build: "8", os: "x", device: "y", signature: "", at });
    }
    assert.equal(rowsOf(await (await s.get()).json()).length, 50);
    assert.equal(rowsOf(await (await s.get("?limit=500")).json()).length, 200);
    assert.equal(rowsOf(await (await s.get("?limit=7")).json()).length, 7);
    assert.equal(rowsOf(await (await s.get("?limit=200")).json()).length, 200);
  });

  it("ignores objects outside diagnostics/", async () => {
    const s = setup();
    s.r2.seed("hr/2026-06-10/abc.json", { x: 1 }, { kind: "crash" });
    s.r2.seed("diagnostic-notes/x.json", { x: 1 }, { kind: "crash" });
    assert.deepEqual(rowsOf(await (await s.get()).json()), []);
  });
});

function r2size(s: ReturnType<typeof setup>, key: string): number {
  return s.r2.objects.get(key)!.bytes.byteLength;
}

// ---------------------------------------------------------------- get by id

describe("diagnostics: GET by id", () => {
  it("returns the stored JSON", async () => {
    const s = setup();
    const body = validBody({ report: { diagnosticMetaData: { signal: 11, regionFormat: "US" } } });
    await s.post(body);
    const res = await s.get(`/${body.id}`);
    assert.equal(res.status, 200);
    assert.match(res.headers.get("content-type") ?? "", /json/);
    const doc = (await res.json()) as any;
    assert.deepEqual(doc, await stored(s.r2, keyFor(body)));
    assert.equal(doc.id, body.id);
    assert.deepEqual(doc.report, { diagnosticMetaData: { signal: 11 } });
  });

  it("finds a report from any day", async () => {
    const s = setup();
    const ids: string[] = [];
    for (const back of [0, 5, 30, 85]) {
      const b = validBody({ at: iso(-back * DAY - 60_000) });
      await s.post(b);
      ids.push(b.id as string);
    }
    for (const id of ids) {
      const res = await s.get(`/${id}`);
      assert.equal(res.status, 200, id);
      assert.equal(((await res.json()) as any).id, id);
    }
  });

  it("finds a report that sits beyond the first R2 list page", async () => {
    const s = setup({ maxPage: 3 });
    const ids: string[] = [];
    for (let i = 0; i < 9; i++) {
      const b = validBody({ at: iso(-i * DAY - 60_000) });
      await s.post(b);
      ids.push(b.id as string);
    }
    for (const id of ids) assert.equal((await s.get(`/${id}`)).status, 200, id);
  });

  it("400 for a bad uuid, without touching R2", async () => {
    const s = setup();
    for (const bad of ["abc", "12345", "not-a-uuid-at-all", "..%2F..%2Fsecret", "00000000-0000-0000-0000-00000000000z", `${uuid()}.json`, `${uuid()}%2F..`]) {
      const res = await s.get(`/${bad}`);
      assert.equal(res.status, 400, bad);
      assert.equal(typeof ((await res.json()) as any).error, "string", bad);
    }
    assert.equal(s.r2.calls.get.length, 0);
  });

  it("404 {error} for an id that is not stored", async () => {
    const s = setup();
    await s.post(validBody());
    const res = await s.get(`/${uuid()}`);
    assert.equal(res.status, 404);
    assert.equal(typeof ((await res.json()) as any).error, "string");
  });

  it("does not return another id's report for a prefix-like id", async () => {
    const s = setup();
    const b = validBody({ id: "11111111-1111-4111-8111-111111111111" });
    await s.post(b);
    assert.equal((await s.get(`/${b.id}`)).status, 200);
    assert.equal((await s.get("/11111111-1111-4111-8111-111111111112")).status, 404);
  });
});

// ---------------------------------------------------------------- onError

describe("app.onError in src/index.ts", () => {
  // src/index.ts imports the Workflows runtime module, which only exists in workerd.
  // Stub that one specifier so the real app can be exercised under node.
  let worker: { fetch: (req: Request, env: unknown, ctx: unknown) => Promise<Response> } | null = null;
  async function loadWorker() {
    if (worker) return worker;
    register(
      "data:text/javascript," +
        encodeURIComponent(
          `export async function resolve(s, c, n) { if (s === "cloudflare:workers") return { url: "data:text/javascript,export class WorkflowEntrypoint {}", shortCircuit: true }; return n(s, c); }`,
        ),
      import.meta.url,
    );
    worker = (await import("../src/index.ts")).default as never;
    return worker!;
  }

  const MSG = "SECRET-ERROR-MESSAGE-" + "m".repeat(600);
  const boom = () => {
    throw new Error(MSG);
  };
  const exploding = {
    DB: { prepare: boom, batch: boom },
    TOKENS: { get: boom, put: boom, delete: boom, list: boom },
    RAW: { get: boom, put: boom, list: boom, delete: boom },
    INGEST_ADMIN_SECRET: SECRET,
  };
  const ctx = makeCtx().ctx;
  const logged = (m: ReturnType<typeof mock.method>) =>
    m.mock.calls.map((c) => String(c.arguments[0])).filter((s) => s.includes("worker_error"));

  it("answers 500 {error: 'internal error'} and leaks neither the message nor the query string", async () => {
    const err = mock.method(console, "error", () => {});
    const w = await loadWorker();
    const res = await w.fetch(new Request("https://app.example/api/whoop-web/status?token=QUERY-SECRET-123&email=a@b.c", { headers: AUTH }), exploding, ctx);
    assert.equal(res.status, 500);
    assert.match(res.headers.get("content-type") ?? "", /json/);
    const text = await res.text();
    assert.deepEqual(JSON.parse(text), { error: "internal error" });
    assert.ok(!text.includes("SECRET-ERROR-MESSAGE") && !text.includes("QUERY-SECRET-123"));
    const lines = logged(err);
    assert.equal(lines.length, 1, "exactly one worker_error line");
    const line = JSON.parse(lines[0]);
    assert.equal(line.event, "worker_error");
    assert.equal(line.method, "GET");
    assert.equal(line.route, "/api/whoop-web/status");
    assert.equal(line.name, "Error");
    assert.ok(typeof line.message === "string" && line.message.length <= 200);
    assert.ok(line.message.startsWith("SECRET-ERROR-MESSAGE"), "message is logged (cut), for the operator");
    assert.ok(!lines[0].includes("QUERY-SECRET-123"), "query string must not be logged");
    assert.ok(!lines[0].includes("a@b.c"));
  });

  it("logs the route without a query for other methods and paths too", async () => {
    const err = mock.method(console, "error", () => {});
    const w = await loadWorker();
    const res = await w.fetch(
      new Request("https://app.example/api/whoop-web/app/ios?x=SECRET-Q", { method: "POST", headers: JSON_AUTH, body: JSON.stringify({ build: 9 }) }),
      exploding,
      ctx,
    );
    assert.equal(res.status, 500);
    assert.deepEqual(await res.json(), { error: "internal error" });
    const lines = logged(err);
    assert.equal(lines.length, 1);
    const line = JSON.parse(lines[0]);
    assert.equal(line.method, "POST");
    assert.equal(line.route, "/api/whoop-web/app/ios");
    assert.ok(!lines[0].includes("SECRET-Q"));
  });

  it("an HTTPException keeps its own response and is not turned into a 500", async () => {
    const err = mock.method(console, "error", () => {});
    const w = await loadWorker();
    const res = await w.fetch(
      new Request("https://app.example/api/settings/source-display", {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ oura: true, pad: "x".repeat(400) }),
      }),
      { ...exploding, TOKENS: fakeKv() },
      ctx,
    );
    assert.equal(res.status, 413);
    const text = await res.text();
    assert.ok(!text.includes("internal error"), text);
    assert.equal(logged(err).length, 0);
  });

  it("does not touch normal responses", async () => {
    const w = await loadWorker();
    const res = await w.fetch(new Request("https://app.example/api/ping"), exploding, ctx);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true });
  });

  it("the diagnostics route is mounted in the real app", async () => {
    const w = await loadWorker();
    const r2 = fakeR2();
    const { db } = sqliteD1();
    const env = { DB: db, TOKENS: fakeKv(), RAW: r2.bucket, INGEST_ADMIN_SECRET: SECRET };
    const body = validBody();
    const res = await w.fetch(
      new Request("https://app.example/api/whoop-web/app/diagnostics", { method: "POST", headers: JSON_AUTH, body: JSON.stringify(body) }),
      env,
      ctx,
    );
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true, id: body.id });
  });
});
