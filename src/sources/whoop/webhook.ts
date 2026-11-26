import type { Env } from "../../env.ts";
import { syncRecentWhoop } from "./recent.ts";

const RECEIPT_TTL_S = 86_400;
// SQLite's clock here is rounded to seconds. Add one to keep a full 20s gap.
const COOLDOWN_S = 21;
const LEASE_S = 45;

export type WhoopWebhookQueueMessage = { source: "whoop"; receiptId: number };

export async function receiveWhoopWebhook(env: Env, traceId: string, type: string) {
  const key = `whoop:webhook:${traceId}`;
  if (await env.TOKENS.get(key).catch(() => null)) return null;

  // KV is a fast path for redeliveries. Concurrent cache misses get the same
  // receipt ID from D1, and the pull coordinator only covers it once.
  const [, , receipt] = await env.DB.batch<{ id: number }>([
    env.DB.prepare(`DELETE FROM whoop_webhook_receipt WHERE expires_at <= unixepoch()`),
    env.DB.prepare(`INSERT INTO whoop_webhook_receipt (trace_id, event_type, expires_at)
                    VALUES (?, ?, unixepoch() + ?) ON CONFLICT (trace_id) DO NOTHING`)
      .bind(traceId, type, RECEIPT_TTL_S),
    env.DB.prepare(`SELECT id FROM whoop_webhook_receipt WHERE trace_id = ?`).bind(traceId),
  ]);
  const receiptId = receipt.results[0].id;
  // Persist a backup before acknowledging. It also handles trailing deliveries
  // and retries a failed or interrupted inline pull.
  await env.INGEST_Q.send({ source: "whoop", receiptId } satisfies WhoopWebhookQueueMessage, { delaySeconds: 5 });
  return { receiptId, cacheWrite: env.TOKENS.put(key, "1", { expirationTtl: RECEIPT_TTL_S }).catch(() => {}) };
}

/** Returns a delay in seconds if this receipt still needs a pull. */
export async function syncWhoopWebhook(env: Env, receiptId: number): Promise<number | null> {
  const deadline = AbortSignal.timeout(24_000);
  const owner = crypto.randomUUID();
  // Capture every receipt registered before the API reads begin. A receipt
  // arriving during the pull must be covered by a later successful pull.
  const claim = await env.DB.prepare(`UPDATE whoop_webhook_sync
      SET owner = ?, available_at = unixepoch() + ?
      WHERE id = 1 AND available_at <= unixepoch() AND covered_through < ?
      RETURNING max(?, coalesce((SELECT max(id) FROM whoop_webhook_receipt), 0)) AS through_id`)
    .bind(owner, LEASE_S, receiptId, receiptId).first<{ through_id: number }>();

  if (!claim) {
    const state = await env.DB.prepare(`SELECT covered_through, owner, available_at - unixepoch() AS wait_s
      FROM whoop_webhook_sync WHERE id = 1`).first<{ covered_through: number; owner: string | null; wait_s: number }>();
    if (!state) throw new Error("WHOOP webhook sync state missing");
    if (state.covered_through >= receiptId) return null;
    // The active pull usually releases its lease well before it expires.
    return Math.max(1, state.owner ? Math.min(10, state.wait_s) : state.wait_s);
  }

  const result = await syncRecentWhoop(env, {
    trigger: "webhook",
    minIntervalMs: 0,
    // Keep WHOOP calls inside the HTTP waitUntil budget and the D1 lease.
    requestOptions: { signal: deadline, spacing: { minMs: 2_000 } },
  });
  const retryAfterS = result.ok ? 0 : result.retryAfterS ?? 0;
  const delay = Math.min(86_400, Math.max(COOLDOWN_S, retryAfterS + 1));
  const finished = await env.DB.prepare(`UPDATE whoop_webhook_sync
      SET owner = NULL, available_at = unixepoch() + ?, covered_through = max(covered_through, ?)
      WHERE id = 1 AND owner = ?`)
    .bind(delay, result.ok ? claim.through_id : 0, owner).run();
  return result.ok && finished.meta.changes === 1 ? null : delay;
}
