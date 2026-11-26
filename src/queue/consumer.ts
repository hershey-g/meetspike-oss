import type { Env } from "../env.ts";
import type { IngestQueueMessage } from "../types.ts";
import { ingestWebhookEvent } from "../sources/oura/ingest.ts";
import { writeSyncLog } from "../lib/synclog.ts";
import { syncWhoopWebhook, type WhoopWebhookQueueMessage } from "../sources/whoop/webhook.ts";

export type QueueMessage = IngestQueueMessage | WhoopWebhookQueueMessage;

export async function handleQueue(batch: MessageBatch<QueueMessage>, env: Env): Promise<void> {
  const whoop: Message<WhoopWebhookQueueMessage>[] = [];
  const oura: Message<IngestQueueMessage>[] = [];
  for (const msg of batch.messages) {
    if ("source" in msg.body) whoop.push(msg as Message<WhoopWebhookQueueMessage>);
    else oura.push(msg as Message<IngestQueueMessage>);
  }
  await Promise.all([handleWhoopMessages(whoop, env), handleOuraMessages(oura, env)]);
}

async function handleWhoopMessages(messages: Message<WhoopWebhookQueueMessage>[], env: Env): Promise<void> {
  if (!messages.length) return;
  let delay: number | null;
  try {
    delay = await syncWhoopWebhook(env, Math.max(...messages.map((msg) => msg.body.receiptId)));
  } catch {
    delay = 5;
  }
  for (const msg of messages) {
    if (delay === null) msg.ack();
    else msg.retry({ delaySeconds: delay });
  }
}

async function handleOuraMessages(messages: Message<IngestQueueMessage>[], env: Env): Promise<void> {
  for (const msg of messages) {
    try {
      await ingestWebhookEvent(env, msg.body);
      msg.ack();
    } catch (err) {
      await writeSyncLog(env, {
        trigger: "webhook",
        endpoint: msg.body.data_type,
        status: "error",
        eventId: msg.body.event_id,
        errorText: err instanceof Error ? err.message : String(err),
      });
      msg.retry();
    }
  }
}
