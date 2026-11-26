import type { HrPoint } from "./parse.ts";

/**
 * Wire shape of POST /api/whoop-web/ingest for the Worker, the Codebox job,
 * and BLE clients. No runtime imports from Worker-only code.
 */
export const INGEST_VERSION = 1;

/** A window the client reports as covered: [startMs, endMs]. */
export type HrSpan = { startMs: number; endMs: number };

export type WhoopWebIngestSource = "codebox" | "ble";

export type WhoopWebIngestPayload = {
  version: typeof INGEST_VERSION;
  /** The ingest trigger recorded in sync_log. Defaults to "codebox". */
  source?: WhoopWebIngestSource;
  /** Time of the fetch or BLE snapshot (ISO). */
  fetchedAt: string;
  hr: { spans: HrSpan[]; points: HrPoint[] };
  /** Stress Monitor days: WHOOP's stress-bff JSON as is (the Worker parses it in the user's zone), or why it failed. */
  stress?: Array<{ day: string; body: unknown } | { day: string; error: string }>;
  /** Non-auth fetch trouble, one short line each. */
  errors?: string[];
  /** The job could not sign in. Nothing else is fetched. */
  authError?: { code: string; message: string };
};
