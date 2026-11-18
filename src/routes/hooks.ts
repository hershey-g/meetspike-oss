import { Hono } from "hono";
import type { Env } from "../env.ts";
import {
  OURA_SIGNATURE_HEADER,
  OURA_TIMESTAMP_HEADER,
  verifyOuraSignature,
} from "../lib/hmac.ts";
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
