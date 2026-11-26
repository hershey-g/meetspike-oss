import { Hono, type Context } from "hono";
import { bodyLimit } from "hono/body-limit";
import type { Env } from "../env.ts";
import {
  diagnosticKey,
  diagnosticMetadata,
  isDiagnosticId,
  keyDay,
  RETENTION_MAX_DELETES,
  retentionCutoffDay,
  sanitizeDiagnostic,
  sortNewestFirst,
  summarize,
  type DiagnosticSummary,
} from "../lib/diagnostics.ts";
import { readAdminSecret, timingSafeEqual } from "../lib/secret.ts";

/**
 * iPhone crash and diagnostic reports, mounted at /api/whoop-web/app/diagnostics.
 * Admin secret on every route, checked before the body is read. Reports live in
 * R2 `RAW` under diagnostics/<day>/<id>.json. Nothing here logs report contents
 * or crumbs.
 */
export const diagnostics = new Hono<{ Bindings: Env }>();

const MAX_BODY = 256 * 1024;
const LIST_PAGE = 1000;
const MAX_PAGES = 200;
const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 200;

type Ctx = Context<{ Bindings: Env }>;

function adminDenied(c: Ctx): Response | null {
  const expected = c.env.INGEST_ADMIN_SECRET?.trim() ?? "";
  if (!expected) return c.json({ error: "INGEST_ADMIN_SECRET is not set" }, 503);
  const got = readAdminSecret(c.req.header("x-admin-secret"), c.req.header("authorization"));
  if (!got || !timingSafeEqual(got, expected)) return c.json({ error: "unauthorized" }, 401);
  return null;
}

function logFailure(event: string, err: unknown, id?: string): void {
  console.error(JSON.stringify({ event, id: id ?? null, name: err instanceof Error ? err.name : "Error" }));
}

function waitUntil(c: Ctx, p: Promise<unknown>): boolean {
  try {
    c.executionCtx.waitUntil(p.catch(() => {}));
    return true;
  } catch {
    return false;
  }
}

/**
 * Delete reports whose day folder is past retention, at most 200 per call.
 * Keys sort by day, so the old ones come first and the scan stops at the first
 * folder that is still in range. Never throws.
 */
async function pruneOld(bucket: R2Bucket, now: number): Promise<void> {
  try {
    const cutoff = retentionCutoffDay(now);
    const doomed: string[] = [];
    let cursor: string | undefined;
    let done = false;
    for (let page = 0; page < 10 && !done && doomed.length < RETENTION_MAX_DELETES; page += 1) {
      const res = await bucket.list({ prefix: "diagnostics/", limit: LIST_PAGE, cursor });
      for (const obj of res.objects) {
        const day = keyDay(obj.key);
        if (day === null) continue;
        if (day >= cutoff) {
          done = true;
          break;
        }
        doomed.push(obj.key);
        if (doomed.length >= RETENTION_MAX_DELETES) break;
      }
      if (!res.truncated || !res.cursor) break;
      cursor = res.cursor;
    }
    if (doomed.length > 0) await bucket.delete(doomed);
  } catch (err) {
    logFailure("diagnostic_retention_failed", err);
  }
}

/** Every report object, oldest key first, following the list cursor. */
async function listAll(bucket: R2Bucket, withMetadata: boolean): Promise<R2Object[]> {
  const out: R2Object[] = [];
  let cursor: string | undefined;
  for (let page = 0; page < MAX_PAGES; page += 1) {
    const res = await bucket.list({
      prefix: "diagnostics/",
      limit: LIST_PAGE,
      cursor,
      ...(withMetadata ? { include: ["customMetadata" as const] } : {}),
    });
    out.push(...res.objects);
    if (!res.truncated || !res.cursor || res.cursor === cursor) break;
    cursor = res.cursor;
  }
  return out;
}

diagnostics.post(
  "/",
  async (c, next) => {
    c.header("Cache-Control", "private, no-store");
    const denied = adminDenied(c);
    if (denied) return denied;
    await next();
  },
  bodyLimit({ maxSize: MAX_BODY, onError: (c) => c.json({ error: "body too large" }, 413) }),
  async (c) => {
    const raw = await c.req.json().catch(() => null);
    const result = sanitizeDiagnostic(raw);
    if (!result.ok) return c.json({ error: result.error }, 400);
    const { doc } = result;
    const bucket = c.env.RAW;
    if (!bucket) return c.json({ error: "report storage is unavailable" }, 503);
    try {
      await bucket.put(diagnosticKey(doc.at, doc.id), JSON.stringify(doc), {
        httpMetadata: { contentType: "application/json" },
        customMetadata: diagnosticMetadata(doc),
      });
    } catch (err) {
      logFailure("diagnostic_store_failed", err, doc.id);
      return c.json({ error: "could not store the report" }, 503);
    }
    const line = JSON.stringify({
      event: "app_diagnostic",
      kind: doc.kind,
      build: doc.build,
      os: doc.os,
      signature: doc.signature ?? null,
    });
    if (doc.kind === "test") console.log(line);
    else console.error(line);
    waitUntil(c, pruneOld(bucket, Date.now()));
    return c.json({ ok: true, id: doc.id });
  },
);

diagnostics.get("/", async (c) => {
  c.header("Cache-Control", "private, no-store");
  const denied = adminDenied(c);
  if (denied) return denied;
  const bucket = c.env.RAW;
  if (!bucket) return c.json({ error: "report storage is unavailable" }, 503);
  const asked = Number.parseInt(c.req.query("limit") ?? "", 10);
  const limit = Number.isFinite(asked) && asked >= 1 ? Math.min(asked, MAX_LIMIT) : DEFAULT_LIMIT;
  try {
    const rows: DiagnosticSummary[] = [];
    for (const obj of await listAll(bucket, true)) {
      const row = summarize(obj);
      if (row) rows.push(row);
    }
    return c.json({ ok: true, reports: sortNewestFirst(rows).slice(0, limit) });
  } catch (err) {
    logFailure("diagnostic_list_failed", err);
    return c.json({ error: "could not list reports" }, 503);
  }
});

diagnostics.get("/:id", async (c) => {
  c.header("Cache-Control", "private, no-store");
  const denied = adminDenied(c);
  if (denied) return denied;
  const id = c.req.param("id");
  if (!isDiagnosticId(id)) return c.json({ error: "id must be a uuid" }, 400);
  const bucket = c.env.RAW;
  if (!bucket) return c.json({ error: "report storage is unavailable" }, 503);
  const suffix = `/${id.toLowerCase()}.json`;
  try {
    const hit = (await listAll(bucket, false)).find((o) => o.key.endsWith(suffix) && keyDay(o.key) !== null);
    const object = hit ? await bucket.get(hit.key) : null;
    if (!object) return c.json({ error: "report not found" }, 404);
    return c.body(await object.text(), 200, { "Content-Type": "application/json" });
  } catch (err) {
    logFailure("diagnostic_read_failed", err, id.toLowerCase());
    return c.json({ error: "could not read the report" }, 503);
  }
});
