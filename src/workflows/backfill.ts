import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers";
import type { Env } from "../env.ts";
import { ACTIVE_ENDPOINTS, chunkWindows } from "../sources/oura/endpoints.ts";
import { ingestEndpointWindow, ingestFixtures } from "../sources/oura/ingest.ts";
import { RateLimitError } from "../sources/oura/client.ts";
import { writeSyncLog } from "../lib/synclog.ts";
import { activeWearable } from "../lib/wearable.ts";
import { SOURCE_WHOOP } from "../types.ts";
import { WHOOP_WINDOW_DAYS } from "../sources/whoop/endpoints.ts";
import { ingestWhoopFixtures, ingestWhoopWindow } from "../sources/whoop/ingest.ts";

export type BackfillParams = {
  mode: "fixtures" | "sandbox" | "production";
  startDay: string;
  endDay: string;
  trigger: string;
};

const STEP = { retries: { limit: 5, delay: "30 seconds", backoff: "exponential" as const } };

export class OuraBackfillWorkflow extends WorkflowEntrypoint<Env, BackfillParams> {
  async run(event: WorkflowEvent<BackfillParams>, step: WorkflowStep) {
    const { mode, startDay, endDay, trigger } = event.payload;

    // The class keeps its historical name (it is a wrangler binding); the
    // active wearable decides what it pulls.
    if (activeWearable(this.env) === SOURCE_WHOOP) {
      if (mode === "fixtures") {
        return step.do("whoop:fixtures", STEP, async () => ingestWhoopFixtures(this.env, 21));
      }
      const totals = { written: 0, skipped: 0 };
      for (const win of chunkWindows(startDay, endDay, WHOOP_WINDOW_DAYS)) {
        try {
          // A rate-limit error fails the step; the step's backoff is the wait.
          const tally = await step.do(`whoop:${win.start}:${win.end}`, STEP, async () =>
            ingestWhoopWindow(this.env, win, trigger),
          );
          totals.written += tally.written;
          totals.skipped += tally.skipped;
        } catch (err) {
          await writeSyncLog(this.env, {
            trigger,
            source: SOURCE_WHOOP,
            endpoint: "recovery,cycle,sleep,workout",
            windowStart: win.start,
            windowEnd: win.end,
            status: "error",
            errorText: err instanceof Error ? err.message : String(err),
          });
          throw err;
        }
      }
      return totals;
    }

    if (mode === "fixtures") {
      return step.do("fixtures", STEP, async () => ingestFixtures(this.env, 21));
    }

    const totals = { written: 0, skipped: 0 };
    for (const spec of ACTIVE_ENDPOINTS) {
      const windows =
        spec.dateStyle === "none"
          ? [{ start: startDay, end: endDay }]
          : chunkWindows(startDay, endDay, spec.maxDays || 30);
      for (const win of windows) {
        const name = `${spec.key}:${win.start}:${win.end}`;
        try {
          const tally = await step.do(name, STEP, async () => {
            try {
              return await ingestEndpointWindow(this.env, spec.key, win, trigger);
            } catch (err) {
              if (err instanceof RateLimitError) throw err;
              throw err;
            }
          });
          totals.written += tally.written;
          totals.skipped += tally.skipped;
        } catch (err) {
          await writeSyncLog(this.env, {
            trigger,
            endpoint: spec.key,
            windowStart: win.start,
            windowEnd: win.end,
            status: "error",
            errorText: err instanceof Error ? err.message : String(err),
          });
          throw err;
        }
      }
    }
    return totals;
  }
}
