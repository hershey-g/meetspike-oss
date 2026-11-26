import { Hono } from "hono";
import type { Env } from "../env.ts";
import { sandboxMode } from "../env.ts";
import { getOuraTokens, getWhoopTokens } from "../lib/tokens.ts";
import { readAdminSecret, timingSafeEqual } from "../lib/secret.ts";
import { isValidDay } from "../lib/date-range.ts";
import { formatUtcDay } from "../sources/oura/endpoints.ts";
import { SOURCE_OURA, SOURCE_WHOOP } from "../types.ts";
import { HISTORY_START_DAY, historyWindows } from "../lib/wearable-history.ts";

const ID = /^history-(oura|whoop)-[a-f0-9-]{36}$/;
export const history = new Hono<{ Bindings: Env }>();

history.use("*", async (c, next) => {
  const expected = c.env.INGEST_ADMIN_SECRET?.trim();
  if (!expected) return c.json({ error: "INGEST_ADMIN_SECRET is not set" }, 503);
  const got = readAdminSecret(c.req.header("x-admin-secret"), c.req.header("authorization"));
  if (!got || !timingSafeEqual(got, expected)) return c.json({ error: "unauthorized" }, 401);
  c.header("Cache-Control", "no-store");
  await next();
});

history.post("/backfill", async (c) => {
  const body = await c.req.json().catch(() => null);
  const source = body?.source;
  if (source !== SOURCE_OURA && source !== SOURCE_WHOOP) return c.json({ error: "source must be oura or whoop" }, 400);
  const today = formatUtcDay(new Date());
  const startDay = body.startDay ?? HISTORY_START_DAY;
  const endDay = body.endDay ?? today;
  if (
    typeof startDay !== "string" || typeof endDay !== "string" ||
    !isValidDay(startDay) || !isValidDay(endDay) || startDay < HISTORY_START_DAY || endDay > today || startDay > endDay
  ) {
    return c.json({ error: `Use inclusive YYYY-MM-DD dates between ${HISTORY_START_DAY} and today` }, 400);
  }
  if (source === SOURCE_OURA && sandboxMode(c.env)) {
    return c.json({ error: "Oura history requires OURA_SANDBOX=false" }, 409);
  }
  const connected = source === SOURCE_OURA ? await getOuraTokens(c.env) : await getWhoopTokens(c.env);
  if (!connected) return c.json({ error: `${source} is not connected` }, 409);
  const id = `history-${source}-${crypto.randomUUID()}`;
  const plan = { source, startDay, endDay, trigger: id, fullHistory: true };
  const instance = await c.env.BACKFILL.create({ id, params: { ...plan, mode: "production" } });
  return c.json({ workflowId: instance.id, source, startDay, endDay, totalWindows: historyWindows(plan).length }, 202);
});

history.get("/backfill/:id", async (c) => {
  const id = c.req.param("id");
  const source = ID.exec(id)?.[1];
  if (!source) return c.json({ error: "invalid history workflow ID" }, 400);
  const instance = await c.env.BACKFILL.get(id);
  const [state, progress, recent] = await Promise.all([
    instance.status().catch(() => null),
    c.env.DB.prepare(
      `SELECT COUNT(*) AS completedWindows, COALESCE(SUM(written), 0) AS written, COALESCE(SUM(skipped), 0) AS skipped
       FROM (
         SELECT MAX(rows_written) AS written, MAX(rows_skipped) AS skipped FROM sync_log
         WHERE trigger = ? AND source = ? AND status = 'ok'
         GROUP BY endpoint, window_start, window_end
       )`,
    ).bind(id, source).first(),
    c.env.DB.prepare(
      `SELECT endpoint, window_start, window_end, status, created_at FROM sync_log
       WHERE trigger = ? AND source = ? ORDER BY id DESC LIMIT 1`,
    ).bind(id, source).first(),
  ]);
  if (!state && !recent) return c.json({ error: "history workflow not found" }, 404);
  return c.json({ workflowId: id, source, status: state?.status ?? "unknown", progress, recent });
});

history.post("/backfill/:id/resume", async (c) => {
  const id = c.req.param("id");
  if (!ID.test(id)) return c.json({ error: "invalid history workflow ID" }, 400);
  const instance = await c.env.BACKFILL.get(id);
  const state = await instance.status().catch(() => null);
  if (!state) return c.json({ error: "history workflow not found" }, 404);
  if (state.status === "paused") await instance.resume();
  else if (state.status === "errored" || state.status === "terminated") await instance.restart();
  else return c.json({ workflowId: id, status: state.status });
  return c.json({ workflowId: id, status: "queued" }, 202);
});
