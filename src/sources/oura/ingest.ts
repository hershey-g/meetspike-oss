import type { Env } from "../../env.ts";
import { SOURCE_OURA, type Projected } from "../../types.ts";
import { nowIso } from "../../lib/time.ts";
import { applyProjected, tombstone } from "../../lib/db.ts";
import { archiveWearableDocument } from "../../lib/wearable-archive.ts";
import { projectDocument, enrichDailySleepFromPeriod } from "./project.ts";
import { documentsForEndpoint, makeSandboxFixtures } from "./fixtures.ts";
import { ACTIVE_ENDPOINTS } from "./endpoints.ts";
import { listDocuments, fetchDocument, type OuraPacing } from "./client.ts";
import { writeSyncLog } from "../../lib/synclog.ts";
import { dayFromHeartrateDoc } from "../../lib/heartrate.ts";

export type IngestTally = { written: number; skipped: number };

export async function ingestOneDocument(
  env: Env,
  endpointKey: string,
  doc: unknown,
  fetchedAt = nowIso(),
): Promise<"written" | "skipped"> {
  const rec = (doc ?? {}) as Record<string, unknown>;
  const documentId = typeof rec.id === "string" ? rec.id : null;
  const day = typeof rec.day === "string" ? rec.day : endpointKey === "heartrate" ? dayFromHeartrateDoc(doc) : null;
  return archiveWearableDocument(env, { source: SOURCE_OURA, endpoint: endpointKey, documentId, day, fetchedAt }, doc, async (rawId, revisionAt) => {
    for (const item of projectDocument(endpointKey, doc, rawId, revisionAt)) {
      if (item.kind === "archive_only" || item.kind === "skipped") continue;
      await applyProjected(env.DB, item);
      if (item.kind === "sleep_period" && !item.row.is_nap) {
        await enrichDailyFromPeriod(env.DB, item, revisionAt);
      }
    }
  });
}

async function enrichDailyFromPeriod(
  db: D1Database,
  item: Extract<Projected, { kind: "sleep_period" }>,
  fetchedAt: string,
): Promise<void> {
  const existing = await db
    .prepare(`SELECT * FROM daily_sleep WHERE day = ? AND source = ? LIMIT 1`)
    .bind(item.row.day, SOURCE_OURA)
    .first<Record<string, unknown>>();
  if (existing?.deleted_at) return;
  const merged = enrichDailySleepFromPeriod(
    {
      day: item.row.day,
      source: SOURCE_OURA,
      source_day: (existing?.source_day as string) ?? item.row.source_day,
      score: (existing?.score as number) ?? null,
      total_sleep_s: (existing?.total_sleep_s as number) ?? null,
      time_in_bed_s: (existing?.time_in_bed_s as number) ?? null,
      efficiency: (existing?.efficiency as number) ?? null,
      latency_s: (existing?.latency_s as number) ?? null,
      deep_s: (existing?.deep_s as number) ?? null,
      rem_s: (existing?.rem_s as number) ?? null,
      light_s: (existing?.light_s as number) ?? null,
      awake_s: (existing?.awake_s as number) ?? null,
      avg_hrv: (existing?.avg_hrv as number) ?? null,
      avg_hr: (existing?.avg_hr as number) ?? null,
      lowest_hr: (existing?.lowest_hr as number) ?? null,
      respiratory_rate: (existing?.respiratory_rate as number) ?? null,
      contributors_json: (existing?.contributors_json as string) ?? null,
      raw_id: (existing?.raw_id as number) ?? item.row.raw_id,
      deleted_at: (existing?.deleted_at as string) ?? null,
      updated_at: fetchedAt,
    },
    item.row,
  );
  await applyProjected(db, { kind: "daily_sleep", row: { ...merged, updated_at: fetchedAt } });
}

export async function ingestEndpointWindow(
  env: Env,
  endpointKey: string,
  window: { start: string; end: string },
  trigger: string,
  pacing?: OuraPacing,
): Promise<IngestTally> {
  const docs = await listDocuments(env, endpointKey, window, pacing);
  const tally: IngestTally = { written: 0, skipped: 0 };
  for (const doc of docs) {
    const r = await ingestOneDocument(env, endpointKey, doc);
    if (r === "written") tally.written += 1;
    else tally.skipped += 1;
  }
  await writeSyncLog(env, {
    trigger,
    endpoint: endpointKey,
    windowStart: window.start,
    windowEnd: window.end,
    status: "ok",
    rowsWritten: tally.written,
    rowsSkipped: tally.skipped,
  });
  return tally;
}

export async function ingestFixtures(env: Env, days = 21): Promise<IngestTally> {
  const bundle = makeSandboxFixtures(days);
  const tally: IngestTally = { written: 0, skipped: 0 };
  for (const spec of ACTIVE_ENDPOINTS) {
    for (const doc of documentsForEndpoint(bundle, spec.key)) {
      const r = await ingestOneDocument(env, spec.key, doc);
      if (r === "written") tally.written += 1;
      else tally.skipped += 1;
    }
  }
  await writeSyncLog(env, {
    trigger: "backfill",
    endpoint: "sandbox-fixtures:*",
    status: "ok",
    rowsWritten: tally.written,
    rowsSkipped: tally.skipped,
  });
  return tally;
}

export async function ingestWebhookEvent(
  env: Env,
  msg: { event_id?: string; data_type: string; object_id: string; event_type: string },
): Promise<void> {
  const spec = ACTIVE_ENDPOINTS.find((e) => e.key === msg.data_type);
  const table =
    msg.data_type === "sleep"
      ? "sleep_periods"
      : msg.data_type === "workout"
        ? "workouts"
        : msg.data_type === "session"
          ? "sessions"
          : msg.data_type === "tag"
            ? "tags"
            : null;
  if (msg.event_type === "delete" && table) {
    await tombstone(env.DB, table, msg.object_id, nowIso());
    await writeSyncLog(env, {
      trigger: "webhook",
      endpoint: msg.data_type,
      status: "ok",
      eventId: msg.event_id,
      rowsWritten: 0,
    });
    return;
  }
  const doc = await fetchDocument(env, msg.data_type, msg.object_id);
  const r = await ingestOneDocument(env, spec?.key ?? msg.data_type, doc);
  await writeSyncLog(env, {
    trigger: "webhook",
    endpoint: msg.data_type,
    status: "ok",
    eventId: msg.event_id,
    rowsWritten: r === "written" ? 1 : 0,
    rowsSkipped: r === "skipped" ? 1 : 0,
  });
}
