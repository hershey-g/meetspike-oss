import type { Env } from "../env.ts";
import type { IngestQueueMessage } from "../types.ts";
import { ingestWebhookEvent } from "../sources/oura/ingest.ts";
import { writeSyncLog } from "../lib/synclog.ts";

export async function handleQueue(batch: MessageBatch<IngestQueueMessage>, env: Env): Promise<void> {
  for (const msg of batch.messages) {
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
