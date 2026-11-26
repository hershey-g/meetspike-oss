import assert from "node:assert/strict";
import { register } from "node:module";
import { afterEach, describe, it, mock } from "node:test";

/**
 * Build 8 fix pass, F9 (server): a handler that throws something that is not an Error.
 *
 * Hono's own compose only calls app.onError for `instanceof Error`; anything else is rethrown and escapes
 * app.fetch as a rejected promise. The fix must log it ("NonError", message cut to 200) and answer the same JSON
 * 500 as an Error. The logged route must stay the handler's own pattern (":id", ":email"), never the wildcard "*"
 * and never the raw path, even when a wildcard wrapper is added.
 *
 * The seam: there is no route that throws a non-Error on purpose, so these tests go through the REAL app
 * (src/index.ts, default export `fetch`) and make the env bindings (D1, KV, R2) throw a plain string or object.
 * That is also the only realistic way one gets out of a handler: a binding that rejects with a non-Error.
 * The routes chosen read a binding before anything else: GET /api/meetings/:id/hr and GET /api/whoop-web/status.
 */

const SECRET = "admin-secret-xyz";
const AUTH = { authorization: `Bearer ${SECRET}` };

type Worker = { fetch: (req: Request, env: unknown, ctx: unknown) => Promise<Response> };
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

function envThrowing(thrown: () => never) {
  return {
    DB: { prepare: thrown, batch: thrown },
    TOKENS: { get: thrown, put: thrown, delete: thrown, list: thrown },
    RAW: { get: thrown, put: thrown, list: thrown, delete: thrown },
    INGEST_ADMIN_SECRET: SECRET,
  };
}

const ctx = { waitUntil() {}, passThroughOnException() {} };
const logged = (m: ReturnType<typeof mock.method>) =>
  m.mock.calls.map((c) => String(c.arguments[0])).filter((s) => s.includes("worker_error"));

afterEach(() => mock.restoreAll());

async function call(path: string, thrown: () => never, init: RequestInit = { headers: AUTH }) {
  const err = mock.method(console, "error", () => {});
  const w = await loadWorker();
  const res = await w.fetch(new Request(`https://app.example${path}`, init), envThrowing(thrown), ctx);
  return { res, lines: logged(err) };
}

describe("a thrown non-Error in a handler (F9)", () => {
  it("is answered with the same JSON 500 as an Error, and is not a rejected fetch", async () => {
    const { res } = await call("/api/whoop-web/status", () => {
      throw "plain string " + "s".repeat(50);
    });
    assert.equal(res.status, 500);
    assert.match(res.headers.get("content-type") ?? "", /json/);
    assert.deepEqual(await res.json(), { error: "internal error" });
  });

  it("is logged once as worker_error with name NonError and the message cut to 200", async () => {
    const long = "NONERR-MSG-" + "m".repeat(600);
    const { res, lines } = await call("/api/whoop-web/status", () => {
      throw long;
    });
    assert.equal(res.status, 500);
    assert.equal(lines.length, 1, "exactly one worker_error line");
    const line = JSON.parse(lines[0]);
    assert.equal(line.event, "worker_error");
    assert.equal(line.method, "GET");
    assert.equal(line.name, "NonError");
    assert.equal(line.message.length, 200);
    assert.ok(line.message.startsWith("NONERR-MSG-"));
    assert.ok(long.startsWith(line.message));
  });

  it("does not leak the thrown text into the response", async () => {
    const { res } = await call("/api/whoop-web/status", () => {
      throw "LEAKY-THROWN-TEXT";
    });
    assert.ok(!(await res.text()).includes("LEAKY-THROWN-TEXT"));
  });

  for (const [label, value] of [
    ["an object", { code: 7 }],
    ["a number", 42],
    ["null", null],
    ["undefined", undefined],
  ] as const) {
    it(`handles ${label} thrown`, async () => {
      const { res, lines } = await call("/api/whoop-web/status", () => {
        throw value;
      });
      assert.equal(res.status, 500);
      assert.deepEqual(await res.json(), { error: "internal error" });
      assert.equal(lines.length, 1);
      const line = JSON.parse(lines[0]);
      assert.equal(line.name, "NonError");
      assert.equal(typeof line.message, "string");
      assert.ok(line.message.length <= 200);
    });
  }

  it("logs the handler's own pattern with :id, not * and not the raw path", async () => {
    const { res, lines } = await call("/api/meetings/ID-RAW-SEGMENT-1/hr?token=QUERY-SECRET", () => {
      throw "boom";
    });
    assert.equal(res.status, 500);
    assert.equal(lines.length, 1);
    const line = JSON.parse(lines[0]);
    assert.equal(line.route, "/api/meetings/:id/hr");
    assert.ok(!lines[0].includes("ID-RAW-SEGMENT-1"), "raw path segment must not be logged");
    assert.ok(!lines[0].includes("QUERY-SECRET"), "query string must not be logged");
  });

  it("logs the pattern with a name parameter too, so an address in the path is never logged", async () => {
    const { res, lines } = await call("/api/people/someone%40secret-company.example/meetings", () => {
      throw "boom";
    });
    assert.equal(res.status, 500);
    assert.equal(lines.length, 1);
    const line = JSON.parse(lines[0]);
    assert.equal(line.route, "/api/people/:email/meetings");
    assert.ok(!lines[0].includes("secret-company"));
  });

  it("a route with no wildcard still logs its plain path", async () => {
    const { lines } = await call("/api/whoop-web/status?x=1", () => {
      throw "boom";
    });
    assert.equal(JSON.parse(lines[0]).route, "/api/whoop-web/status");
  });
});

describe("Error and HTTPException keep today's behaviour (F9 regression)", () => {
  it("an Error is logged with its own name, message cut, the :id pattern, and answered with the JSON 500", async () => {
    class BindingError extends Error {
      override name = "BindingError";
    }
    const { res, lines } = await call("/api/meetings/ID-RAW-SEGMENT-2/hr?a=QSECRET", () => {
      throw new BindingError("E-MSG-" + "e".repeat(600));
    });
    assert.equal(res.status, 500);
    assert.deepEqual(await res.json(), { error: "internal error" });
    assert.equal(lines.length, 1, "no double logging from a wrapper plus onError");
    const line = JSON.parse(lines[0]);
    assert.equal(line.name, "BindingError");
    assert.equal(line.route, "/api/meetings/:id/hr");
    assert.equal(line.message.length, 200);
    assert.ok(line.message.startsWith("E-MSG-"));
    assert.ok(!lines[0].includes("ID-RAW-SEGMENT-2") && !lines[0].includes("QSECRET"));
  });

  it("an Error on the people route logs :email", async () => {
    const { lines } = await call("/api/people/x%40y.example/meetings", () => {
      throw new Error("db down");
    });
    assert.equal(lines.length, 1);
    assert.equal(JSON.parse(lines[0]).route, "/api/people/:email/meetings");
  });

  it("an Error that carries a UUID in the path still has it masked as :id", async () => {
    const id = "11111111-1111-4111-8111-111111111111";
    const { lines } = await call(`/api/whoop-web/app/diagnostics/${id}`, () => {
      throw new Error("x");
    });
    // The diagnostics reader answers its own 503 for a failing bucket, so this may log nothing; if it logs, the id is masked.
    for (const text of lines) assert.ok(!text.includes(id));
  });

  it("an HTTPException keeps its own response and is not logged", async () => {
    const err = mock.method(console, "error", () => {});
    const w = await loadWorker();
    const kv = new Map<string, string>();
    const env = {
      ...envThrowing(() => {
        throw "unused";
      }),
      TOKENS: { get: async (k: string) => kv.get(k) ?? null, put: async (k: string, v: string) => void kv.set(k, v), delete: async () => {}, list: async () => ({ keys: [] }) },
    };
    const res = await w.fetch(
      new Request("https://app.example/api/settings/source-display", {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ oura: true, pad: "x".repeat(400) }),
      }),
      env,
      ctx,
    );
    assert.equal(res.status, 413);
    assert.ok(!(await res.text()).includes("internal error"));
    assert.equal(logged(err).length, 0);
  });

  it("a normal response is untouched", async () => {
    const w = await loadWorker();
    const res = await w.fetch(
      new Request("https://app.example/api/ping"),
      envThrowing(() => {
        throw "unused";
      }),
      ctx,
    );
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true });
  });
});
