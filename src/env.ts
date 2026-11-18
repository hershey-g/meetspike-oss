export interface Env {
  DB: D1Database;
  RAW: R2Bucket;
  TOKENS: KVNamespace;
  INGEST_Q: Queue;
  BACKFILL: Workflow;
  RECONCILE: Workflow;
  ASSETS: Fetcher;
  OURA_CLIENT_ID: string;
  OURA_CLIENT_SECRET: string;
  /** Optional. Defaults to <this Worker's address>/auth/oura/callback. */
  OURA_REDIRECT_URI?: string;
  OURA_SANDBOX?: string;
  /**
   * Which wearable feeds the dashboard: "whoop" or "oura".
   * Unset keeps an Oura-only install on Oura; see src/lib/wearable.ts.
   */
  WEARABLE?: string;
  WHOOP_CLIENT_ID?: string;
  WHOOP_CLIENT_SECRET?: string;
  /** Optional. Defaults to <this Worker's address>/api/whoop/callback. */
  WHOOP_REDIRECT_URI?: string;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  GOOGLE_REDIRECT_URI?: string;
  /** Optional personal title. Default UI brand is Meetspike. */
  DISPLAY_TITLE?: string;
  /** Shared secret for POST /api/plaud/ingest. Not a Plaud token. */
  INGEST_ADMIN_SECRET?: string;
  /**
   * Optional. 32+ random characters used to encrypt the user's own Claude
   * API key at rest in KV. Without it, "Ask your data" stays off.
   */
  AI_KEY_SECRET?: string;
}

export function displayTitle(env: Env): string {
  const custom = env.DISPLAY_TITLE?.trim();
  return custom && custom.length ? custom : "Meetspike";
}

export function sandboxMode(env: Env): boolean {
  return (env.OURA_SANDBOX ?? "true").toLowerCase() !== "false";
}

/**
 * The address an OAuth provider sends the browser back to. An explicit
 * *_REDIRECT_URI wins; otherwise it is this Worker's own origin plus `path`,
 * so a fresh install has one less value to copy around.
 */
export function redirectUri(configured: string | undefined, requestUrl: string, path: string): string {
  const explicit = configured?.trim();
  if (explicit) return explicit;
  return new URL(path, requestUrl).toString();
}
