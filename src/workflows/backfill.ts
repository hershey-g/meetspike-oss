import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers";
import type { Env } from "../env.ts";
import { activeWearable } from "../lib/wearable.ts";
import { runWearableHistory } from "../lib/wearable-history.ts";
import { SOURCE_WHOOP, type WearableSource } from "../types.ts";
import { ingestFixtures } from "../sources/oura/ingest.ts";
import { ingestWhoopFixtures } from "../sources/whoop/ingest.ts";

export type BackfillParams = {
  mode: "fixtures" | "sandbox" | "production";
  startDay: string;
  endDay: string;
  trigger: string;
  source?: WearableSource;
  fullHistory?: boolean;
};

// The class name is part of the existing Wrangler binding.
export class OuraBackfillWorkflow extends WorkflowEntrypoint<Env, BackfillParams> {
  async run(event: WorkflowEvent<BackfillParams>, step: WorkflowStep) {
    const { mode, startDay, endDay, trigger, fullHistory = false } = event.payload;
    const source = event.payload.source ?? activeWearable(this.env);
    if (mode === "fixtures") {
      return step.do(`${source}:fixtures`, async () =>
        source === SOURCE_WHOOP ? ingestWhoopFixtures(this.env, 21) : ingestFixtures(this.env, 21),
      );
    }
    return runWearableHistory(this.env, step, { source, startDay, endDay, trigger, fullHistory });
  }
}
