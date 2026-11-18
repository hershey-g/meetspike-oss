/**
 * WHOOP developer API v2 — official endpoints only.
 * Reference: https://developer.whoop.com/api and https://developer.whoop.com/docs
 */
export const WHOOP_AUTHORIZE = "https://api.prod.whoop.com/oauth/oauth2/auth";
export const WHOOP_TOKEN = "https://api.prod.whoop.com/oauth/oauth2/token";
export const WHOOP_API = "https://api.prod.whoop.com/developer";

/** `offline` is what makes WHOOP return a refresh token. */
export const WHOOP_SCOPES = [
  "read:recovery",
  "read:cycles",
  "read:sleep",
  "read:workout",
  "read:profile",
  "read:body_measurement",
  "offline",
] as const;

export const WHOOP_TOKEN_KEY = "whoop:tokens";
export const WHOOP_STATE_PREFIX = "oauth:whoop:state:";
export const WHOOP_CALLBACK_PATH = "/api/whoop/callback";
export const WHOOP_START_PATH = "/auth/whoop/start";

/** Collection endpoints page with `limit` (max 25) and `nextToken`. */
export const WHOOP_PAGE_LIMIT = 25;

export type WhoopCollectionKey = "cycle" | "recovery" | "sleep" | "workout";

export const WHOOP_COLLECTIONS: Record<WhoopCollectionKey, { path: string; scope: string }> = {
  cycle: { path: "/v2/cycle", scope: "read:cycles" },
  recovery: { path: "/v2/recovery", scope: "read:recovery" },
  sleep: { path: "/v2/activity/sleep", scope: "read:sleep" },
  workout: { path: "/v2/activity/workout", scope: "read:workout" },
};

/** Sleep goes first: recovery and cycles take their calendar day from it. */
export const WHOOP_COLLECTION_ORDER: readonly WhoopCollectionKey[] = ["sleep", "recovery", "cycle", "workout"];

/** Days per backfill step. About two pages per collection. */
export const WHOOP_WINDOW_DAYS = 30;
