import type { Env } from "../../env.ts";
import { SOURCE_WHOOP } from "../../types.ts";
import { canonicalJson, r2Key, sha256Hex } from "../../lib/hash.ts";
import { addCalendarDays, nowIso } from "../../lib/time.ts";
import { applyProjected, findRaw, insertRaw, loadTimeZone } from "../../lib/db.ts";
import { putRawJson } from "../../lib/r2.ts";
import { writeSyncLog } from "../../lib/synclog.ts";
import { WHOOP_COLLECTION_ORDER, type WhoopCollectionKey } from "./endpoints.ts";
import { assertWhoopDailyBudget, chargeWhoopRequests, listWhoopCollection } from "./client.ts";
import { makeWhoopFixtures, type WhoopBundle } from "./fixtures.ts";
import {
  buildWhoopContext,
  projectWhoopDocument,
  whoopDocumentId,
  whoopSleepDay,
  type SleepVitals,
  type WhoopContext,
} from "./project.ts";

export type IngestTally = { written: number; skipped: number };

/** HRV and resting heart rate belong to the recovery but are read from the sleep row. */
async function applySleepVitals(db: D1Database, v: SleepVitals): Promise<void> {
  await db
    .prepare(
      `INSERT INTO daily_sleep (day, source, source_day, avg_hrv, lowest_hr, raw_id, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (day, source) DO UPDATE SET
         avg_hrv = excluded.avg_hrv,
         lowest_hr = excluded.lowest_hr,
         updated_at = excluded.updated_at`,
    )
    .bind(v.day, SOURCE_WHOOP, v.day, v.avg_hrv, v.lowest_hr, v.raw_id, v.updated_at)
    .run();
}

/** A recovery whose sleep was not in this batch: find the sleep we stored earlier. */
async function fillMissingSleepDays(db: D1Database, recoveries: unknown[], ctx: Required<WhoopContext>): Promise<void> {
  for (const doc of recoveries) {
    const sleepId = (doc as { sleep_id?: unknown } | null)?.sleep_id;
    if (typeof sleepId !== "string" || ctx.sleepDayById.has(sleepId)) continue;
    const row = await db
      .prepare(`SELECT day FROM sleep_periods WHERE id = ? AND source = ? LIMIT 1`)
      .bind(sleepId, SOURCE_WHOOP)
      .first<{ day: string }>();
    if (row?.day) ctx.sleepDayById.set(sleepId, row.day);
  }
}

async function ingestOne(
  env: Env,
  collection: WhoopCollectionKey,
  doc: unknown,
  ctx: WhoopContext,
  fetchedAt: string,
): Promise<"written" | "skipped"> {
  const body = canonicalJson(doc);
  const hash = await sha256Hex(body);
  const documentId = whoopDocumentId(collection, doc) ?? `${collection}:${hash.slice(0, 12)}`;
  const existing = await findRaw(env.DB, collection, documentId, hash, SOURCE_WHOOP);
  if (existing) return "skipped";

  const key = r2Key(SOURCE_WHOOP, collection, documentId, hash);
  await putRawJson(env, key, body);
  const day = collection === "sleep" ? whoopSleepDay(doc, ctx.timeZone) : null;
  const rawId = await insertRaw(
    env.DB,
    { endpoint: collection, documentId, day, r2Key: key, hash, fetchedAt },
    SOURCE_WHOOP,
  );
  for (const item of projectWhoopDocument(collection, doc, rawId, fetchedAt, ctx)) {
    if (item.kind === "sleep_vitals") await applySleepVitals(env.DB, item);
    else if (item.kind !== "skipped" && item.kind !== "archive_only") await applyProjected(env.DB, item);
  }
  return "written";
}

/** Archive and project a batch of WHOOP records. Unchanged records are skipped. */
export async function ingestWhoopBundle(env: Env, bundle: WhoopBundle, fetchedAt = nowIso()): Promise<IngestTally> {
  const timeZone = await loadTimeZone(env.DB).catch(() => undefined);
  const ctx = buildWhoopContext(bundle.sleep, timeZone);
  await fillMissingSleepDays(env.DB, bundle.recovery, ctx);
  const tally: IngestTally = { written: 0, skipped: 0 };
  for (const collection of WHOOP_COLLECTION_ORDER) {
    for (const doc of bundle[collection]) {
      const r = await ingestOne(env, collection, doc, ctx, fetchedAt);
      if (r === "written") tally.written += 1;
      else tally.skipped += 1;
    }
  }
  return tally;
}

/**
 * WHOOP filters by when a record started. A night that ends on the first day
 * began the evening before, so reach one day back; one day forward covers
 * time zones ahead of UTC. Overlap is harmless — rows are upserts.
 */
export function whoopQueryRange(window: { start: string; end: string }): { startIso: string; endIso: string } {
  return {
    startIso: `${addCalendarDays(window.start, -1)}T00:00:00.000Z`,
    endIso: `${addCalendarDays(window.end, 2)}T00:00:00.000Z`,
  };
}

/** Pull recovery, cycles, sleep and workouts for an inclusive day window. */
export async function ingestWhoopWindow(
  env: Env,
  window: { start: string; end: string },
  trigger: string,
): Promise<IngestTally> {
  await assertWhoopDailyBudget(env);
  const calls = { requests: 0 };
  const range = whoopQueryRange(window);
  const bundle: WhoopBundle = { sleep: [], recovery: [], cycle: [], workout: [] };
  try {
    for (const collection of WHOOP_COLLECTION_ORDER) {
      bundle[collection] = await listWhoopCollection(env, collection, range, { tally: calls });
    }
  } finally {
    await chargeWhoopRequests(env, calls.requests);
  }
  const tally = await ingestWhoopBundle(env, bundle);
  await writeSyncLog(env, {
    trigger,
    source: SOURCE_WHOOP,
    endpoint: "recovery,cycle,sleep,workout",
    windowStart: window.start,
    windowEnd: window.end,
    status: "ok",
    rowsWritten: tally.written,
    rowsSkipped: tally.skipped,
  });
  return tally;
}

export async function ingestWhoopFixtures(env: Env, days = 21): Promise<IngestTally> {
  const tally = await ingestWhoopBundle(env, makeWhoopFixtures(days));
  await writeSyncLog(env, {
    trigger: "backfill",
    source: SOURCE_WHOOP,
    endpoint: "fixtures:*",
    status: "ok",
    rowsWritten: tally.written,
    rowsSkipped: tally.skipped,
  });
  return tally;
}
