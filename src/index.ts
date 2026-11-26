import { Hono, type Context } from "hono";
import { HTTPException } from "hono/http-exception";
import type { Env } from "./env.ts";
import { auth } from "./routes/auth.ts";
import { api } from "./routes/api.ts";
import { hooks } from "./routes/hooks.ts";
import { pairExchange, pairStart } from "./routes/pair.ts";
import { handleQueue, type QueueMessage } from "./queue/consumer.ts";
import { runScheduledCalendarSync } from "./sources/calendar/scheduled.ts";
import { PUSH_CRON, runPushTick } from "./sources/whoop-web/push.ts";
import { runScheduledWhoopWebFill } from "./sources/whoop-web/scheduled.ts";
import { syncRecentOura } from "./sources/oura/recent.ts";
import { CRON_MIN_INTERVAL_MS, syncRecentWhoop } from "./sources/whoop/recent.ts";

export { OuraBackfillWorkflow } from "./workflows/backfill.ts";
export { NightlyReconcileWorkflow } from "./workflows/reconcile.ts";
export { LiveHeartRate } from "./sources/whoop-web/live.ts";

const app = new Hono<{ Bindings: Env }>();

// Hono's own error path only handles `instanceof Error`; a handler doing
// `throw "x"` would escape onError and fail the whole request. Catch those here
// (this must stay registered before the routes) and route them through the same
// log line and JSON 500. The routeIndex is still the throwing handler's, so the
// logged pattern keeps its :id form.
app.use("*", async (c, next) => {
  try {
    await next();
  } catch (err) {
    if (err instanceof Error) throw err;
    return respondWithError(err, c);
  }
});

app.route("/auth", auth);
// iPhone pairing: /api/pair/start sits behind Access; /hooks/pair is the code exchange (bypassed, code-authorized).
app.route("/api/pair", pairStart);
app.route("/api", api);
app.route("/hooks/pair", pairExchange);
app.route("/hooks", hooks);

app.get("/api/ping", (c) => c.json({ ok: true }));

const UUID_SEGMENT = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;

// Anything that escapes a handler: log one line (never the query string) and
// answer a plain 500. HTTPException keeps its own response.
app.onError((err, c) => {
  if (err instanceof HTTPException) return err.getResponse();
  return respondWithError(err, c);
});

function safeString(value: unknown): string {
  try {
    return String(value);
  } catch {
    return "unprintable";
  }
}

function respondWithError(err: unknown, c: Context) {
  let route: string;
  try {
    const pattern = c.req.routePath;
    route = pattern && !pattern.includes("*") ? pattern : new URL(c.req.url).pathname;
  } catch {
    route = "unknown";
  }
  const error = err instanceof Error ? err : null;
  console.error(
    JSON.stringify({
      event: "worker_error",
      method: c.req.method,
      route: route.replace(UUID_SEGMENT, ":id"),
      name: error?.name ?? "NonError",
      message: safeString(error ? error.message : err).slice(0, 200),
    }),
  );
  return c.json({ error: "internal error" }, 500);
}

export default {
  fetch: (request: Request, env: Env, ctx: ExecutionContext) => app.fetch(request, env, ctx),
  queue: (batch: MessageBatch<QueueMessage>, env: Env) => handleQueue(batch, env),
  // Every 15 minutes (triggers.crons): incremental Google Calendar sync, so
  // meetings added or moved during the day show up without a manual refresh.
  // Same tick, when WHOOP_WEB_HR is on: fill heart rate for meetings that
  // ended in the last two days (about 20 WHOOP requests at most, paced).
  // It never password-logs-in unless WHOOP_WEB_WORKER_LOGIN is on; the
  // codebox2 job normally does the pulling (POST /api/whoop-web/ingest).
  // Same tick: re-read yesterday and today from the WHOOP developer API, so
  // this morning's sleep and recovery show up once WHOOP has scored them
  // instead of waiting for tomorrow's 06:00 reconcile (about 4 requests).
  // Every minute (the second trigger, PUSH_CRON): only the reminder push tick.
  // The 15-minute jobs below must not run on it.
  scheduled: (controller: ScheduledController, env: Env, ctx: ExecutionContext) => {
    if (controller.cron === PUSH_CRON) {
      ctx.waitUntil(runPushTick(env, controller.scheduledTime));
      return;
    }
    ctx.waitUntil(runScheduledCalendarSync(env));
    ctx.waitUntil(syncRecentWhoop(env, { trigger: "cron", minIntervalMs: CRON_MIN_INTERVAL_MS }));
    ctx.waitUntil(runScheduledWhoopWebFill(env));
    ctx.waitUntil(syncRecentOura(env, "cron"));
  },
};
