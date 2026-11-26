import { Hono } from "hono";
import type { Env } from "../env.ts";
import {
  OURA_SIGNATURE_HEADER,
  OURA_TIMESTAMP_HEADER,
  WHOOP_SIGNATURE_HEADER,
  WHOOP_TIMESTAMP_HEADER,
  verifyOuraSignature,
  verifyWhoopSignature,
} from "../lib/hmac.ts";
import { receiveWhoopWebhook, syncWhoopWebhook } from "../sources/whoop/webhook.ts";
import type { IngestQueueMessage } from "../types.ts";

export const hooks = new Hono<{ Bindings: Env }>();

/** Oura subscription verification: echo the challenge. */
hooks.get("/oura", (c) => {
  const challenge =
    c.req.query("challenge") ?? c.req.query("verification_token") ?? c.req.query("verificationToken");
  if (challenge) return c.text(challenge, 200);
  return c.text("ok", 200);
});

/**
 * HMAC first. Enqueue. 200. No fetch, no D1, nothing else in this path.
 * Oura requires 2xx within 10 seconds.
 */
hooks.post("/oura", async (c) => {
  const rawBody = await c.req.text();
  const signature = c.req.header(OURA_SIGNATURE_HEADER) ?? null;
  const timestamp = c.req.header(OURA_TIMESTAMP_HEADER) ?? null;
  const verified = await verifyOuraSignature({
    secret: c.env.OURA_CLIENT_SECRET,
    signature,
    timestamp,
    rawBody,
  });
  if (!verified.ok) return c.json({ error: verified.reason }, verified.status);

  let payload: IngestQueueMessage;
  try {
    payload = JSON.parse(rawBody) as IngestQueueMessage;
  } catch {
    return c.json({ error: "invalid json" }, 400);
  }
  if (!payload.data_type || !payload.object_id || !payload.event_type) {
    return c.json({ error: "missing fields" }, 400);
  }

  await c.env.INGEST_Q.send({
    event_id: payload.event_id,
    data_type: payload.data_type,
    object_id: payload.object_id,
    event_type: payload.event_type,
    event_time: payload.event_time,
  });
  return c.json({ ok: true }, 200);
});

const whoopEventTypes = new Set([
  "sleep.updated", "recovery.updated", "workout.updated",
  "sleep.deleted", "recovery.deleted", "workout.deleted",
]);

hooks.post("/whoop", async (c) => {
  let rawBody: string;
  try {
    rawBody = new TextDecoder("utf-8", { ignoreBOM: true, fatal: true }).decode(await c.req.arrayBuffer());
  } catch {
    return c.json({ error: "invalid body encoding" }, 401);
  }
  const verified = await verifyWhoopSignature({
    secret: c.env.WHOOP_WEBHOOK_SECRET || c.env.WHOOP_CLIENT_SECRET || "",
    signature: c.req.header(WHOOP_SIGNATURE_HEADER) ?? null,
    timestamp: c.req.header(WHOOP_TIMESTAMP_HEADER) ?? null,
    rawBody,
  });
  if (!verified.ok) return c.json({ error: verified.reason }, verified.status);

  let payload: { user_id?: unknown; id?: unknown; type?: unknown; trace_id?: unknown } | null;
  try {
    payload = JSON.parse(rawBody.replace(/^\uFEFF/, ""));
  } catch {
    return c.json({ error: "invalid json" }, 400);
  }
  if (typeof payload?.type !== "string") return c.json({ error: "missing event type" }, 400);
  if (!whoopEventTypes.has(payload.type)) return c.body(null, 204);
  const { trace_id, id, user_id } = payload;
  if (typeof trace_id !== "string" || !trace_id || trace_id.length > 128 ||
      typeof id !== "string" || !id || typeof user_id !== "number" || !Number.isInteger(user_id)) {
    return c.json({ error: "invalid event fields" }, 400);
  }

  let receipt: Awaited<ReturnType<typeof receiveWhoopWebhook>>;
  try {
    receipt = await receiveWhoopWebhook(c.env, trace_id, payload.type);
  } catch {
    return c.json({ error: "webhook intake unavailable" }, 503);
  }
  if (receipt) c.executionCtx.waitUntil(Promise.all([receipt.cacheWrite, syncWhoopWebhook(c.env, receipt.receiptId)]));
  return c.body(null, 204);
});
