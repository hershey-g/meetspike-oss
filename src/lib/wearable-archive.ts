import type { Env } from "../env.ts";
import type { WearableSource } from "../types.ts";
import { canonicalJson, r2Key, sha256Hex } from "./hash.ts";
import { putRawJson } from "./r2.ts";

type RawPointer = { id: number; projection_pending: number; fetched_at: string };

/** Keep a retryable pointer until all projections for this revision have landed. */
export async function archiveWearableDocument(
  env: Env,
  row: { source: WearableSource; endpoint: string; documentId: string | null; day: string | null; fetchedAt: string },
  doc: unknown,
  project: (rawId: number, fetchedAt: string) => Promise<void>,
): Promise<"written" | "skipped"> {
  const { source, endpoint, day, fetchedAt } = row;
  const body = canonicalJson(doc);
  const hash = await sha256Hex(body);
  const documentId = row.documentId ?? `${endpoint}:${hash.slice(0, 12)}`;
  let pointer = await env.DB.prepare(
    `SELECT id, projection_pending, fetched_at FROM raw_object
     WHERE source = ? AND endpoint = ? AND document_id = ? AND content_hash = ?`,
  ).bind(source, endpoint, documentId, hash).first<RawPointer>();
  if (!pointer) {
    const key = r2Key(source, endpoint, documentId, hash);
    await putRawJson(env, key, body);
    const pending = endpoint === "heartrate" ? 0 : 1;
    pointer = await env.DB.prepare(
      `INSERT INTO raw_object (source, endpoint, document_id, day, r2_key, content_hash, fetched_at, projection_pending)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (source, endpoint, document_id, content_hash) DO UPDATE SET id = raw_object.id
       RETURNING id, projection_pending, fetched_at`,
    ).bind(source, endpoint, documentId, day, key, hash, fetchedAt, pending).first<RawPointer>();
    if (!pointer) throw new Error("could not store wearable archive pointer");
    if (endpoint === "heartrate") return "written";
  }
  if (!pointer.projection_pending) return "skipped";
  await project(pointer.id, pointer.fetched_at);
  await env.DB.prepare("UPDATE raw_object SET projection_pending = 0 WHERE id = ?").bind(pointer.id).run();
  return "written";
}
