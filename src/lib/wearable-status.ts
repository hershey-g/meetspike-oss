import type { Env } from "../env.ts";
import { getOuraTokens, getWhoopTokens } from "./tokens.ts";
import { SOURCE_OURA, SOURCE_WHOOP } from "../types.ts";
import type { SourceDisplay } from "./source-display.ts";
import { NOT_FETCHED_SLACK_MS } from "../sources/whoop-web/meeting-hr.ts";

type Span = { first_day: string | null; last_day: string | null; last_received: string | null };
const empty: Span = { first_day: null, last_day: null, last_received: null };

export async function loadWearableStatuses(env: Env, display: SourceDisplay) {
  const [oura, whoop, ranges, whoopHr] = await Promise.all([
    getOuraTokens(env),
    getWhoopTokens(env),
    env.DB.prepare(
      `SELECT source, MIN(first_day) AS first_day, MAX(last_day) AS last_day, MAX(last_received) AS last_received
       FROM (
         SELECT source, MIN(day) AS first_day, MAX(day) AS last_day, MAX(updated_at) AS last_received
           FROM daily_sleep WHERE deleted_at IS NULL GROUP BY source
         UNION ALL
         SELECT source, MIN(day), MAX(day), MAX(updated_at)
           FROM daily_readiness WHERE deleted_at IS NULL GROUP BY source
         UNION ALL
         SELECT source, MIN(day), MAX(day), MAX(updated_at)
           FROM sleep_periods WHERE deleted_at IS NULL GROUP BY source
         UNION ALL
         SELECT source, MIN(day), MAX(day), MAX(fetched_at)
           FROM raw_object WHERE source = 'oura' AND endpoint = 'heartrate' AND day IS NOT NULL GROUP BY source
       ) WHERE source IN ('oura', 'whoop') GROUP BY source`,
    ).all<Span & { source: string }>(),
    env.DB.prepare(
      `SELECT MIN(substr(window_start_utc, 1, 10)) AS first_day,
              MAX(substr(window_end_utc, 1, 10)) AS last_day,
              -- A row marked "not fetched for this window" holds a window start in fetched_at, not a time
              -- data arrived: its days still count, its fetched_at is not "last received".
              MAX(CASE WHEN fetched_at >= strftime('%Y-%m-%dT%H:%M:%fZ', window_start_utc, printf('+%.3f seconds', ${NOT_FETCHED_SLACK_MS} / 1000.0))
                       THEN fetched_at END) AS last_received
       FROM whoop_web_hr WHERE status = 'ok' AND sample_count > 0`,
    ).first<Span>().catch((err) => {
      if (!String(err).includes("no such table: whoop_web_hr")) throw err;
      return null;
    }),
  ]);
  const map = new Map((ranges.results ?? []).map((r) => [r.source, r]));
  return [SOURCE_WHOOP, SOURCE_OURA].map((source) => {
    const label = source === SOURCE_WHOOP ? "WHOOP" : "Oura";
    const tokens = source === SOURCE_WHOOP ? whoop : oura;
    const daily = map.get(source) ?? empty;
    const hr = source === SOURCE_WHOOP ? whoopHr ?? empty : empty;
    const min = [daily.first_day, hr.first_day].filter(Boolean).sort()[0] ?? null;
    const max = [daily.last_day, hr.last_day].filter(Boolean).sort().at(-1) ?? null;
    return {
      source, label, displayEnabled: display[source], connected: Boolean(tokens), expiresAt: tokens?.expires_at ?? null,
      lastDataDay: max,
      lastReceivedAt: [daily.last_received, hr.last_received].filter(Boolean).sort().at(-1) ?? null,
      history: { min, max },
    };
  });
}
