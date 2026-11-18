import { Hono } from "hono";
import type { Env } from "./env.ts";
import { auth } from "./routes/auth.ts";
import { api } from "./routes/api.ts";
import { hooks } from "./routes/hooks.ts";
import { handleQueue } from "./queue/consumer.ts";
import type { IngestQueueMessage } from "./types.ts";

export { OuraBackfillWorkflow } from "./workflows/backfill.ts";
export { NightlyReconcileWorkflow } from "./workflows/reconcile.ts";

const app = new Hono<{ Bindings: Env }>();

app.route("/auth", auth);
app.route("/api", api);
app.route("/hooks", hooks);

app.get("/api/ping", (c) => c.json({ ok: true }));

export default {
  fetch: (request: Request, env: Env, ctx: ExecutionContext) => app.fetch(request, env, ctx),
  queue: (batch: MessageBatch<IngestQueueMessage>, env: Env) => handleQueue(batch, env),
};
