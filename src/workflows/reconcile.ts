import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers";
import type { Env } from "../env.ts";
import { ACTIVE_ENDPOINTS, addUtcDays, formatUtcDay } from "../sources/oura/endpoints.ts";
import { ingestEndpointWindow } from "../sources/oura/ingest.ts";
import { writeSyncLog } from "../lib/synclog.ts";
import { getGoogleTokens, getWhoopTokens } from "../lib/tokens.ts";
import { syncPrimaryCalendar } from "../sources/calendar/ingest.ts";
import { activeWearable } from "../lib/wearable.ts";
import { SOURCE_WHOOP } from "../types.ts";
import { ingestWhoopWindow } from "../sources/whoop/ingest.ts";

export type ReconcileParams = { trigger?: string };

const STEP = { retries: { limit: 5, delay: "30 seconds", backoff: "exponential" as const } };

export class NightlyReconcileWorkflow extends WorkflowEntrypoint<Env, ReconcileParams> {
  async run(event: WorkflowEvent<ReconcileParams>, step: WorkflowStep) {
    const trigger = event.payload?.trigger ?? "reconcile";
    const endDay = formatUtcDay(new Date());
    const startDay = addUtcDays(endDay, -6);
    const totals = { written: 0, skipped: 0 };

    const whoop = activeWearable(this.env) === SOURCE_WHOOP;
    // Not connected yet (a fresh install) is not an error worth retrying all night.
    const whoopConnected = whoop
      ? await step.do("whoop:has-tokens", STEP, async () => Boolean(await getWhoopTokens(this.env)))
      : false;
    if (whoopConnected) {
      // WHOOP rescores sleep and recovery after the fact, so re-pull the week.
      try {
        const tally = await step.do(`reconcile:whoop:${startDay}:${endDay}`, STEP, async () =>
          ingestWhoopWindow(this.env, { start: startDay, end: endDay }, trigger),
        );
        totals.written += tally.written;
        totals.skipped += tally.skipped;
      } catch (err) {
        await writeSyncLog(this.env, {
          trigger,
          source: SOURCE_WHOOP,
          endpoint: "recovery,cycle,sleep,workout",
          windowStart: startDay,
          windowEnd: endDay,
          status: "error",
          errorText: err instanceof Error ? err.message : String(err),
        });
        throw err;
      }
    }

    for (const spec of whoop ? [] : ACTIVE_ENDPOINTS) {
      const name = `reconcile:${spec.key}:${startDay}:${endDay}`;
      try {
        const tally = await step.do(name, STEP, async () =>
          ingestEndpointWindow(this.env, spec.key, { start: startDay, end: endDay }, trigger),
        );
        totals.written += tally.written;
        totals.skipped += tally.skipped;
      } catch (err) {
        await writeSyncLog(this.env, {
          trigger,
          endpoint: spec.key,
          windowStart: startDay,
          windowEnd: endDay,
          status: "error",
          errorText: err instanceof Error ? err.message : String(err),
        });
        throw err;
      }
    }

    const googlePresent = await step.do("calendar:has-tokens", STEP, async () =>
      Boolean(await getGoogleTokens(this.env)),
    );
    if (googlePresent) {
      const calStart = addUtcDays(endDay, -6);
      const calEnd = addUtcDays(endDay, 14);
      try {
        const cal = await step.do("calendar:primary", STEP, async () =>
          syncPrimaryCalendar(this.env, { start: calStart, end: calEnd }, trigger),
        );
        totals.written += cal.written;
        totals.skipped += cal.skipped;
      } catch (err) {
        await writeSyncLog(this.env, {
          trigger,
          source: "google",
          endpoint: "events",
          windowStart: calStart,
          windowEnd: calEnd,
          status: "error",
          errorText: err instanceof Error ? err.message : String(err),
        });
        // Calendar is source two — a Google blip must not fail the wearable reconcile.
      }
    }

    // P1.5: renew webhook subscriptions here once they are registered.
    return { startDay, endDay, ...totals };
  }
}
