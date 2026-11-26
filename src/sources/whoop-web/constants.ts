/**
 * Settings shared by everything that handles WHOOP heart rate from the
 * Worker's side: KV keys, the sync_log source, the fill budget. Nothing in
 * here is specific to how WHOOP's web app is reached, so it stays in both
 * builds (see docs/OSS.md).
 */
/** KV keys in the existing tokens namespace. Values never leave the Worker. */
export const WHOOP_WEB_TOKEN_KEY = "whoop-web:tokens";
export const WHOOP_WEB_LOGIN_KEY = "whoop-web:login";
export const WHOOP_WEB_BACKFILL_KEY = "whoop-web:backfill";

/** sync_log.source for everything this module logs. */
export const SOURCE_WHOOP_WEB = "whoop_web";

/** Password logins can lock the account: at most one per this many ms. */
export const LOGIN_MIN_INTERVAL_MS = 6 * 3600 * 1000;

/** Minutes of heart rate fetched either side of a meeting. */
export const WINDOW_PAD_MIN = 10;

/** Cron: meetings that ended in the last this-many days are filled. */
export const CRON_LOOKBACK_DAYS = 2;
/** Most WHOOP requests one cron run (or one backfill batch) may make. */
export const RUN_REQUEST_BUDGET = 20;
/** Pause between WHOOP requests in a run. */
export const REQUEST_PACING_MS = 1500;
/** Longest backfill we allow from the admin endpoint. */
export const BACKFILL_MAX_DAYS = 30;
